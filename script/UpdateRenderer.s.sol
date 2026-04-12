// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";

interface IOldRenderer {
    function getRendererHTML() external view returns (bytes memory);
}

/// @notice Copy the WebGL renderer HTML from the old BUIDLRenderer to the new one.
/// The old renderer has a proper WebGL viewer with PBR lighting, ACES tonemapping,
/// auto-rotation, and mouse/touch orbit. The new one was deployed with a basic 2D canvas.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/UpdateRenderer.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract UpdateRenderer is Script {
    // Old renderer (previous deployment — has the proper WebGL HTML)
    address constant OLD_RENDERER = 0x00c63510F55b1F06Dcc8cC9d91E862fA8E5fA9E6;
    // New renderer (V3 deployment)
    address constant NEW_RENDERER = 0xa240113cB2F6dCEEd337ccd28A197D64521d7B7D;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);

        // Read the WebGL renderer HTML from the old contract
        bytes memory webglHTML = IOldRenderer(OLD_RENDERER).getRendererHTML();
        console.log("Read WebGL HTML from old renderer:", webglHTML.length, "bytes");
        require(webglHTML.length > 1000, "HTML too short");

        vm.startBroadcast(pk);

        // Store the proper WebGL renderer HTML on the new renderer
        BUIDLRenderer(NEW_RENDERER).storeRenderer(webglHTML);
        console.log("Renderer HTML updated successfully");

        vm.stopBroadcast();
    }
}
