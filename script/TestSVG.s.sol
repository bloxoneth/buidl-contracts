// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";

/// @notice Local-only script to preview the SVG output without deploying.
contract TestSVG is Script {
    function run() external {
        // Deploy renderer locally (not broadcast)
        BUIDLRenderer renderer = new BUIDLRenderer(msg.sender);

        // Simple 1x1x1 cube, colour index 1
        // header: [version=1, bboxX=1, bboxY=1, bboxZ=1]
        // 1 voxel, 3 bits = colour 1 (001) => byte 0x01
        bytes memory geo = hex"010101010101";

        string memory svg = renderer.renderSVG(geo);
        console.log(svg);
    }
}
