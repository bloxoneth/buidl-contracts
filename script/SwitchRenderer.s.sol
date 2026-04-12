// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";

/// @notice Point BuildNFT to the improved BUIDLRenderer (from previous deployment).
/// That renderer has better SVG styling (darker bg, blue-tinted shadows, thicker strokes)
/// AND the proper WebGL HTML already stored.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/SwitchRenderer.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract SwitchRenderer is Script {
    address constant BUILD_NFT = 0x1213328B55003d0d85D1300f5F79928D6632D4A0;
    // The improved renderer from previous deployment — has good SVG + WebGL HTML stored
    address constant GOOD_RENDERER = 0x00c63510F55b1F06Dcc8cC9d91E862fA8E5fA9E6;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        console.log("Deployer:", vm.addr(pk));
        console.log("Switching BuildNFT renderer to:", GOOD_RENDERER);

        vm.startBroadcast(pk);
        BuildNFT(BUILD_NFT).setRenderer(GOOD_RENDERER);
        vm.stopBroadcast();

        console.log("Done. BuildNFT now uses the improved renderer.");
    }
}
