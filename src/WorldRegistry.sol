// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IBuildNFTWorld {
    function ownerOf(uint256 tokenId) external view returns (address);
    function massOf(uint256 tokenId) external view returns (uint256);
    function kindOf(uint256 tokenId) external view returns (uint8);
}

interface IBLOX {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Spatial registry for buidl.world.
/// Land is BLOX balance. Builds are placed within land.
/// 4-unit gap between builds. 10-unit moat between owner land boundaries.
contract WorldRegistry is Ownable {
    uint256 public constant BUILD_GAP = 4; // units between any two builds
    uint256 public constant LAND_MOAT = 10; // units moat around land boundary
    uint256 public constant LAND_SCALAR = 1; // 1 BLOX (in WAD) = 1 land unit^2

    address public immutable buildNFT;
    address public immutable blox;

    // World coordinate => tokenId (0 = empty)
    // Using int256 to allow negative coordinates
    mapping(int256 => mapping(int256 => uint256)) public worldGrid;

    // tokenId => placement coordinates (0,0 = not placed)
    mapping(uint256 => int256) public placedX;
    mapping(uint256 => int256) public placedZ;
    mapping(uint256 => bool) public isPlaced;

    // owner => land claim centre
    mapping(address => int256) public landCentreX;
    mapping(address => int256) public landCentreZ;
    mapping(address => bool) public hasLandClaim;

    event BuildPlaced(
        address indexed owner,
        uint256 indexed tokenId,
        int256 wx,
        int256 wz
    );

    event BuildRemoved(
        address indexed owner,
        uint256 indexed tokenId
    );

    event LandClaimed(
        address indexed owner,
        int256 cx,
        int256 cz
    );

    constructor(
        address buildNFT_,
        address blox_,
        address owner_
    ) Ownable(owner_) {
        require(buildNFT_ != address(0), "buildNFT=0");
        require(blox_ != address(0), "blox=0");
        buildNFT = buildNFT_;
        blox = blox_;
    }

    // --- Land footprint ---

    /// @notice Total land area available to an owner.
    /// Equals BLOX balance (in whole tokens) * LAND_SCALAR.
    function landFootprint(address owner)
        public
        view
        returns (uint256)
    {
        uint256 bloxBal = IBLOX(blox).balanceOf(owner);
        return (bloxBal / 1e18) * LAND_SCALAR;
    }

    // --- Placement ---

    /// @notice Place a BuildNFT at world coordinates (wx, wz).
    /// Caller must own the BuildNFT.
    /// Placement must be within caller's land and respect gap/moat rules.
    function place(
        uint256 tokenId,
        int256 wx,
        int256 wz
    ) external {
        require(
            IBuildNFTWorld(buildNFT).ownerOf(tokenId) == msg.sender,
            "not owner"
        );
        require(!isPlaced[tokenId], "already placed");
        require(worldGrid[wx][wz] == 0, "occupied");

        // Verify land coverage
        require(_hasLandAt(msg.sender, wx, wz), "no land");

        // Verify no build within BUILD_GAP units
        require(_noNeighbourWithin(wx, wz, BUILD_GAP), "too close");

        worldGrid[wx][wz] = tokenId;
        placedX[tokenId] = wx;
        placedZ[tokenId] = wz;
        isPlaced[tokenId] = true;

        emit BuildPlaced(msg.sender, tokenId, wx, wz);
    }

    /// @notice Remove a placed BuildNFT from the world.
    function remove(uint256 tokenId) external {
        require(
            IBuildNFTWorld(buildNFT).ownerOf(tokenId) == msg.sender,
            "not owner"
        );
        require(isPlaced[tokenId], "not placed");

        int256 wx = placedX[tokenId];
        int256 wz = placedZ[tokenId];

        worldGrid[wx][wz] = 0;
        isPlaced[tokenId] = false;

        emit BuildRemoved(msg.sender, tokenId);
    }

    // --- Land claim ---

    /// @notice Claim a land centre point.
    /// Each owner has one land region centred on their claimed point.
    /// Land radius = sqrt(landFootprint / pi) approximately.
    function claimLand(int256 cx, int256 cz) external {
        require(!hasLandClaim[msg.sender], "already claimed");
        require(landFootprint(msg.sender) > 0, "no BLOX");

        // Verify moat: no other owner's land centre within
        // LAND_MOAT + both owners' land radii
        require(_moatClear(msg.sender, cx, cz), "moat violation");

        landCentreX[msg.sender] = cx;
        landCentreZ[msg.sender] = cz;
        hasLandClaim[msg.sender] = true;

        emit LandClaimed(msg.sender, cx, cz);
    }

    // --- Internal helpers ---

    function _hasLandAt(
        address owner,
        int256 wx,
        int256 wz
    ) internal view returns (bool) {
        if (!hasLandClaim[owner]) return false;
        int256 cx = landCentreX[owner];
        int256 cz = landCentreZ[owner];
        uint256 fp = landFootprint(owner);

        // Land is a square of side sqrt(fp) centred on claim
        int256 halfSide = int256(_sqrt(fp)) / 2;
        return (
            wx >= cx - halfSide && wx <= cx + halfSide
                && wz >= cz - halfSide && wz <= cz + halfSide
        );
    }

    function _noNeighbourWithin(
        int256 wx,
        int256 wz,
        uint256 gap
    ) internal view returns (bool) {
        int256 g = int256(gap);
        for (int256 dx = -g; dx <= g; dx++) {
            for (int256 dz = -g; dz <= g; dz++) {
                if (dx == 0 && dz == 0) continue;
                if (worldGrid[wx + dx][wz + dz] != 0) return false;
            }
        }
        return true;
    }

    function _moatClear(
        address, /* newOwner */
        int256, /* cx */
        int256 /* cz */
    ) internal pure returns (bool) {
        // Simplified: check no other land claim within LAND_MOAT units
        // Full implementation requires iterating registered land owners
        // For MVP: trust caller, emit event, enforce off-chain
        // TODO: maintain owner registry for on-chain moat enforcement
        return true;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
