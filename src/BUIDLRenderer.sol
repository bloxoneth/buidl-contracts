// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SSTORE2} from "sstore2/SSTORE2.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @notice On-chain 3D renderer and isometric SVG generator for BUIDL.
/// Stores the self-contained Three.js renderer HTML via SSTORE2.
/// Called by BuildNFT.tokenURI for every token render.
contract BUIDLRenderer is Ownable {
    using Strings for uint256;
    using Strings for int256;

    // SSTORE2 pointer to the 3D HTML renderer
    address public rendererPointer;

    // Protocol colour palette (7 colours, index 1-7)
    // index 0 = empty voxel
    bytes3[8] public palette;

    // Isometric projection matching Three.js camera at [8,8,8]
    // Top face height = 2*TH, visible side height = 2*TD - TH
    // TD = 2*TH gives side:top ≈ 1.5:1 matching the WebGL
    int256 private constant TILE_W = 20;
    int256 private constant TILE_H = 10;
    int256 private constant TILE_D = 20;

    event RendererStored(uint256 size);
    event PaletteSet();

    constructor(address owner_) Ownable(owner_) {
        // Matches BUIDL_PALETTE from app (lib/palette.ts)
        palette[0] = bytes3(0x000000); // empty (unused)
        palette[1] = bytes3(0xF0F0F0); // Off White
        palette[2] = bytes3(0xB85C38); // Brick Red
        palette[3] = bytes3(0x8B5E3C); // Wood Brown
        palette[4] = bytes3(0x5A8C3F); // Grass Green
        palette[5] = bytes3(0x5B9BD5); // Sky Blue
        palette[6] = bytes3(0xD4B483); // Sand Yellow
        palette[7] = bytes3(0x2D2D2D); // Charcoal
        emit PaletteSet();
    }

    /// @notice Update the palette. Owner-only.
    function setPalette(bytes3[8] calldata newPalette) external onlyOwner {
        for (uint256 i = 0; i < 8; i++) palette[i] = newPalette[i];
        emit PaletteSet();
    }

    /// @notice Store the 3D renderer HTML. Owner-only. Called once at deploy.
    function storeRenderer(bytes calldata rendererHTML) external onlyOwner {
        require(rendererHTML.length > 0, "empty");
        rendererPointer = SSTORE2.write(rendererHTML);
        emit RendererStored(rendererHTML.length);
    }

    /// @notice Fetch the renderer HTML bytes.
    function getRendererHTML() external view returns (bytes memory) {
        require(rendererPointer != address(0), "not stored");
        return SSTORE2.read(rendererPointer);
    }

    /// @notice Inject geometry into renderer HTML and return complete page.
    /// The BUIDL_GEO variable must be defined BEFORE the renderer script
    /// so it is available when the renderer checks `typeof BUIDL_GEO`.
    function render3DHTML(
        uint256 tokenId,
        bytes calldata geometryData
    ) external view returns (string memory) {
        require(rendererPointer != address(0), "no renderer");

        bytes memory html = SSTORE2.read(rendererPointer);
        string memory htmlStr = string(html);

        // Inject geometry as a <script> block BEFORE the renderer's <script>.
        // The stored HTML has format: ....<body><canvas ...></canvas><script>...renderer...</script></body></html>
        // We replace the first <script> with <script>BUIDL_GEO=...;</script><script>
        string memory geoScript = string.concat(
            "<script>const BUIDL_TOKEN_ID=",
            tokenId.toString(),
            ";const BUIDL_GEO='",
            Base64.encode(geometryData),
            "';</script><script>"
        );

        // Find first <script> in the HTML and replace it
        bytes memory target = bytes("<script>");
        bytes memory src = bytes(htmlStr);
        bytes memory rep = bytes(geoScript);

        // Simple single-replace: scan for first occurrence of "<script>"
        uint256 tLen = target.length;
        for (uint256 i = 0; i <= src.length - tLen; i++) {
            bool found = true;
            for (uint256 j = 0; j < tLen; j++) {
                if (src[i + j] != target[j]) { found = false; break; }
            }
            if (found) {
                // Build result: src[0..i) + rep + src[i+tLen..)
                return string.concat(
                    _slice(src, 0, i),
                    string(rep),
                    _slice(src, i + tLen, src.length)
                );
            }
        }

        // Fallback: append (shouldn't happen if renderer HTML is well-formed)
        return string.concat(htmlStr, string(rep));
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = data[i];
        }
        return string(result);
    }

    /// @notice Generate isometric SVG from geometry bytes.
    /// 3-bit voxel encoding: bits 000=empty, 001-111=colour index 1-7.
    /// Returns a complete SVG string for marketplace thumbnail use.
    function renderSVG(bytes calldata geometryData)
        external
        view
        returns (string memory)
    {
        return _buildIsometricSVG(geometryData);
    }

    // --- internals ---

    function _buildIsometricSVG(bytes calldata geo)
        internal
        view
        returns (string memory)
    {
        require(geo.length >= 4, "too short");

        // Parse header: [version, bboxX, bboxY, bboxZ]
        uint8 bx = uint8(geo[1]);
        uint8 by = uint8(geo[2]);
        uint8 bz = uint8(geo[3]);
        require(bx > 0 && by > 0 && bz > 0, "invalid bbox");

        // Track bounds for viewBox
        int256 minSX = type(int256).max;
        int256 minSY = type(int256).max;
        int256 maxSX = type(int256).min;
        int256 maxSY = type(int256).min;

        // First pass: count surface voxels and compute bounds
        uint256 surfaceCount = 0;

        for (uint256 z = 0; z < bz; z++) {
            for (uint256 y = 0; y < by; y++) {
                for (uint256 x = 0; x < bx; x++) {
                    uint8 ci = _getColourIndex(geo, x, y, z, bx, by);
                    if (ci == 0) continue;
                    if (!_isSurface(geo, x, y, z, bx, by, bz)) continue;

                    surfaceCount++;

                    // Isometric projection
                    int256 sx = (int256(x) - int256(z)) * TILE_W;
                    int256 sy = (int256(x) + int256(z)) * TILE_H - int256(y) * TILE_D * 2;

                    if (sx - TILE_W < minSX) minSX = sx - TILE_W;
                    if (sy - TILE_D * 2 < minSY) minSY = sy - TILE_D * 2;
                    if (sx + TILE_W > maxSX) maxSX = sx + TILE_W;
                    if (sy + TILE_H > maxSY) maxSY = sy + TILE_H;
                }
            }
        }

        if (surfaceCount == 0) {
            return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#0f0e17"/></svg>';
        }

        // Build SVG polygons — render back-to-front (z descending, y ascending, x ascending)
        string memory polygons = "";

        for (uint256 z = bz; z > 0; z--) {
            for (uint256 y = 0; y < by; y++) {
                for (uint256 x = 0; x < bx; x++) {
                    uint8 ci = _getColourIndex(geo, x, y, z - 1, bx, by);
                    if (ci == 0) continue;
                    if (!_isSurface(geo, x, y, z - 1, bx, by, bz)) continue;

                    int256 sx = (int256(x) - int256(z - 1)) * TILE_W;
                    int256 sy = (int256(x) + int256(z - 1)) * TILE_H - int256(y) * TILE_D * 2;

                    polygons = string.concat(
                        polygons,
                        _renderVoxelFaces(sx, sy, ci)
                    );
                }
            }
        }

        // Tight padding so cube fills the frame
        int256 spanX = maxSX - minSX;
        int256 spanY = maxSY - minSY;
        int256 padX = spanX / 5;
        int256 padY = spanY / 5;
        if (padX < 12) padX = 12;
        if (padY < 12) padY = 12;

        return _assembleSVG(minSX, minSY, maxSX, maxSY, padX, padY, polygons);
    }

    function _assembleSVG(
        int256 minSX, int256 minSY, int256 maxSX, int256 maxSY,
        int256 padX, int256 padY,
        string memory polygons
    ) internal pure returns (string memory) {
        int256 vbX = minSX - padX;
        int256 vbY = minSY - padY;
        int256 vbW = maxSX - minSX + padX * 2;
        int256 vbH = maxSY - minSY + padY * 2;

        // Ground glow — soft ellipse beneath the model
        int256 glowCX = (minSX + maxSX) / 2;
        int256 glowCY = maxSY + 4;
        int256 glowRX = (maxSX - minSX) / 2 + 15;
        int256 glowRY = 10;

        string memory svgOpen = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="',
            _intToStr(vbX), " ", _intToStr(vbY), " ",
            _intToStr(vbW), " ", _intToStr(vbH), '">'
        );

        // Background matches Three.js scene bg (#36465c) with subtle radial gradient
        string memory defs = '<defs>'
            '<radialGradient id="bg"><stop offset="0%" stop-color="#3d5068"/><stop offset="100%" stop-color="#29364a"/></radialGradient>'
            '<radialGradient id="gl"><stop offset="0%" stop-color="#5a7090" stop-opacity="0.3"/><stop offset="100%" stop-color="#5a7090" stop-opacity="0"/></radialGradient>'
            '</defs>';

        string memory bg = string.concat(
            '<rect x="', _intToStr(vbX), '" y="', _intToStr(vbY),
            '" width="', _intToStr(vbW), '" height="', _intToStr(vbH),
            '" fill="url(#bg)"/>'
        );

        string memory glow = string.concat(
            '<ellipse cx="', _intToStr(glowCX), '" cy="', _intToStr(glowCY),
            '" rx="', _intToStr(glowRX), '" ry="', _intToStr(glowRY),
            '" fill="url(#gl)"/>'
        );

        return string.concat(
            svgOpen, defs, bg, glow,
            '<g stroke-linejoin="round" stroke-width="0.3">',
            polygons,
            '</g></svg>'
        );
    }

    function _getColourIndex(
        bytes calldata geo,
        uint256 x,
        uint256 y,
        uint256 z,
        uint8 bx,
        uint8 by
    ) internal pure returns (uint8) {
        uint256 voxelIndex = x + y * uint256(bx) + z * uint256(bx) * uint256(by);
        uint256 byteIndex = (voxelIndex * 3) / 8;
        uint256 bitOffset = (voxelIndex * 3) % 8;

        if (4 + byteIndex >= geo.length) return 0;

        uint8 colourIndex = uint8(geo[4 + byteIndex] >> bitOffset) & 0x07;

        // Handle bit straddle across byte boundary
        if (bitOffset > 5 && 4 + byteIndex + 1 < geo.length) {
            colourIndex |= uint8((uint16(uint8(geo[4 + byteIndex + 1])) << (8 - bitOffset)) & 0x07);
        }

        return colourIndex;
    }

    function _isSurface(
        bytes calldata geo,
        uint256 x,
        uint256 y,
        uint256 z,
        uint8 bx,
        uint8 by,
        uint8 bz
    ) internal pure returns (bool) {
        // A voxel is surface-visible if any neighbour is empty or out of bounds
        if (x == 0 || _getColourIndex(geo, x - 1, y, z, bx, by) == 0) return true;
        if (x + 1 >= bx || _getColourIndex(geo, x + 1, y, z, bx, by) == 0) return true;
        if (y == 0 || _getColourIndex(geo, x, y - 1, z, bx, by) == 0) return true;
        if (y + 1 >= by || _getColourIndex(geo, x, y + 1, z, bx, by) == 0) return true;
        if (z == 0 || _getColourIndex(geo, x, y, z - 1, bx, by) == 0) return true;
        if (z + 1 >= bz || _getColourIndex(geo, x, y, z + 1, bx, by) == 0) return true;
        return false;
    }

    function _renderVoxelFaces(int256 sx, int256 sy, uint8 ci)
        internal
        view
        returns (string memory)
    {
        bytes3 bc = palette[ci];
        // Subtle edge colour — just slightly darker than darkest face
        string memory eh = _darkenPct(bc, 40);

        int256 TD2 = TILE_D * 2;

        // 7 visible vertices of isometric cube projected from 3D corners:
        //   V_back    = (sx,            sy - TD2)          — topmost vertex
        //   V_topR    = (sx + TILE_W,   sy + TILE_H - TD2) — top-right
        //   V_topL    = (sx - TILE_W,   sy + TILE_H - TD2) — top-left
        //   V_topF    = (sx,            sy + 2*TILE_H - TD2) — front of top face
        //   V_front   = (sx,            sy)                 — front-bottom vertex
        //   V_right   = (sx + TILE_W,   sy + TILE_H)       — bottom-right
        //   V_left    = (sx - TILE_W,   sy + TILE_H)       — bottom-left

        // Three.js directional light at [9,12,8], normals dot products:
        //   top  (0,1,0) · light = 0.71 → brighten 30%
        //   left (0,0,-1) · light = 0.47 → darken 20%
        //   right(1,0,0)  · light = 0.53 → darken 12%

        // Left face (z-min, faces viewer-left) — darkest visible
        string memory left = _face(
            sx, sy,                              // V_front
            sx, sy - TD2,                        // V_back
            sx - TILE_W, sy + TILE_H - TD2,     // V_topL
            sx - TILE_W, sy + TILE_H,           // V_left
            _darkenPct(bc, 20), eh
        );

        // Right face (x-max, faces viewer-right) — medium
        string memory right = _face(
            sx, sy,                              // V_front
            sx + TILE_W, sy + TILE_H,           // V_right
            sx + TILE_W, sy + TILE_H - TD2,     // V_topR
            sx, sy - TD2,                        // V_back
            _darkenPct(bc, 12), eh
        );

        // Top face — brightest, drawn last so it paints over side overlap
        string memory top = _face(
            sx, sy - TD2,                        // V_back
            sx + TILE_W, sy + TILE_H - TD2,     // V_topR
            sx, sy + TILE_H * 2 - TD2,          // V_topF
            sx - TILE_W, sy + TILE_H - TD2,     // V_topL
            _brightenPct(bc, 30), eh
        );

        return string.concat(left, right, top);
    }

    function _face(
        int256 x1, int256 y1, int256 x2, int256 y2,
        int256 x3, int256 y3, int256 x4, int256 y4,
        string memory fillHex, string memory strokeHex
    ) internal pure returns (string memory) {
        string memory pts = string.concat(
            _intToStr(x1), ",", _intToStr(y1), " ",
            _intToStr(x2), ",", _intToStr(y2), " ",
            _intToStr(x3), ",", _intToStr(y3), " ",
            _intToStr(x4), ",", _intToStr(y4)
        );
        return string.concat(
            '<polygon points="', pts,
            '" fill="#', fillHex,
            '" stroke="#', strokeHex, '"/>'
        );
    }

    function _specHighlight(int256 cx, int256 cy)
        internal
        pure
        returns (string memory)
    {
        // Larger glossy diamond on top face
        string memory pts = string.concat(
            _intToStr(cx), ",", _intToStr(cy + 3), " ",
            _intToStr(cx + 6), ",", _intToStr(cy), " ",
            _intToStr(cx), ",", _intToStr(cy - 3), " ",
            _intToStr(cx - 6), ",", _intToStr(cy)
        );
        return string.concat(
            '<polygon points="', pts,
            '" fill="#fff" opacity="0.25"/>'
        );
    }

    function _rimHighlight(
        int256 x1, int256 y1,
        int256 x2, int256 y2
    ) internal pure returns (string memory) {
        // Thin bright line along top-left edge of top face
        string memory pts = string.concat(
            _intToStr(x1), ",", _intToStr(y1), " ",
            _intToStr(x2), ",", _intToStr(y2), " ",
            _intToStr(x2 - 1), ",", _intToStr(y2 + 1), " ",
            _intToStr(x1 - 1), ",", _intToStr(y1 + 1)
        );
        return string.concat(
            '<polygon points="', pts,
            '" fill="#fff" opacity="0.12"/>'
        );
    }

    function _colourToHex(bytes3 c) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(6);
        for (uint256 i = 0; i < 3; i++) {
            str[i * 2] = hexChars[uint8(c[i]) >> 4];
            str[i * 2 + 1] = hexChars[uint8(c[i]) & 0x0f];
        }
        return string(str);
    }

    /// @dev Brighten by percentage: lerp towards 255.
    function _brightenPct(bytes3 c, uint8 pct) internal pure returns (string memory) {
        bytes3 bright = bytes3(
            abi.encodePacked(
                _lerpUp(uint8(c[0]), pct),
                _lerpUp(uint8(c[1]), pct),
                _lerpUp(uint8(c[2]), pct)
            )
        );
        return _colourToHex(bright);
    }

    /// @dev Darken by percentage: lerp towards 0.
    function _darkenPct(bytes3 c, uint8 pct) internal pure returns (string memory) {
        bytes3 dark = bytes3(
            abi.encodePacked(
                _lerpDown(uint8(c[0]), pct),
                _lerpDown(uint8(c[1]), pct),
                _lerpDown(uint8(c[2]), pct)
            )
        );
        return _colourToHex(dark);
    }

    /// @dev v + (255 - v) * pct / 100
    function _lerpUp(uint8 v, uint8 pct) internal pure returns (uint8) {
        uint16 result = uint16(v) + (uint16(255 - v) * uint16(pct)) / 100;
        return result > 255 ? 255 : uint8(result);
    }

    /// @dev v * (100 - pct) / 100
    function _lerpDown(uint8 v, uint8 pct) internal pure returns (uint8) {
        return uint8((uint16(v) * uint16(100 - pct)) / 100);
    }

    function _intToStr(int256 value) internal pure returns (string memory) {
        if (value >= 0) return uint256(value).toString();
        return string.concat("-", uint256(-value).toString());
    }
}
