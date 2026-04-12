// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";

/// @notice Preview SVG output locally (no broadcast needed).
contract PreviewSVGLocal is Script {
    function run() external {
        BUIDLRenderer renderer = new BUIDLRenderer(msg.sender);

        // 1x1x1 brick, color 1
        bytes memory geo1 = hex"0101010101";
        string memory svg1 = renderer.renderSVG(geo1);
        console.log("=== 1x1x1 SVG ===");
        console.log(svg1);

        // 2x2x2 multicolor
        bytes memory geo2 = hex"01020202" hex"49" hex"92" hex"04";
        string memory svg2 = renderer.renderSVG(geo2);
        console.log("=== 2x2x2 SVG ===");
        console.log(svg2);
    }
}
