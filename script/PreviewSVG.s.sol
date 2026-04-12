// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BUIDLRenderer} from "../src/BUIDLRenderer.sol";

contract PreviewSVG is Script {
    /// @dev Pack N voxels of the same colour index into 3-bit geometry bytes.
    function _packUniform(uint8 count, uint8 ci) internal pure returns (bytes memory) {
        uint256 totalBits = uint256(count) * 3;
        uint256 totalBytes = (totalBits + 7) / 8;
        bytes memory packed = new bytes(totalBytes);
        for (uint256 i = 0; i < count; i++) {
            uint256 bitPos = i * 3;
            uint256 byteIdx = bitPos / 8;
            uint256 bitOff = bitPos % 8;
            packed[byteIdx] = bytes1(uint8(packed[byteIdx]) | uint8(ci << bitOff));
            if (bitOff > 5 && byteIdx + 1 < totalBytes) {
                packed[byteIdx + 1] = bytes1(uint8(packed[byteIdx + 1]) | uint8(ci >> (8 - bitOff)));
            }
        }
        return packed;
    }

    function run() external {
        BUIDLRenderer renderer = new BUIDLRenderer(msg.sender);

        // 1x1x1 single voxel, colour 5 (Cyan Blue)
        bytes memory geo1x1 = abi.encodePacked(uint8(1), uint8(1), uint8(1), uint8(1), _packUniform(1, 5));
        string memory svg1 = renderer.renderSVG(geo1x1);
        vm.writeFile("preview-1x1.svg", svg1);
        console.log("Wrote preview-1x1.svg");

        // 2x1x3 brick, all colour 2 (Vivid Red)
        bytes memory geo2x3 = abi.encodePacked(uint8(1), uint8(2), uint8(1), uint8(3), _packUniform(6, 2));
        string memory svg2 = renderer.renderSVG(geo2x3);
        vm.writeFile("preview-2x3.svg", svg2);
        console.log("Wrote preview-2x3.svg (Vivid Red 2x1x3)");

        // 2x2x2 cube, all colour 5 (Cyan Blue)
        bytes memory geo2x2 = abi.encodePacked(uint8(1), uint8(2), uint8(2), uint8(2), _packUniform(8, 5));
        string memory svg3 = renderer.renderSVG(geo2x2);
        vm.writeFile("preview-2x2.svg", svg3);
        console.log("Wrote preview-2x2.svg (Cyan Blue 2x2x2)");

        // 2x2x2 cube, all colour 6 (Golden Yellow)
        bytes memory geoGold = abi.encodePacked(uint8(1), uint8(2), uint8(2), uint8(2), _packUniform(8, 6));
        string memory svg4 = renderer.renderSVG(geoGold);
        vm.writeFile("preview-gold.svg", svg4);
        console.log("Wrote preview-gold.svg (Golden Yellow 2x2x2)");
    }
}
