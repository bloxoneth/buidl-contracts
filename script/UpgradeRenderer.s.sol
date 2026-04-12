// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";

/// @notice Deploy new BUIDLRenderer with improved SVG, store WebGL HTML, point BuildNFT to it.
contract UpgradeRenderer is Script {
    address constant BUILD_NFT = 0xd92F0f448CDc90F45Ff2F53e705FD27031eC90B1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Deploy new renderer
        BUIDLRenderer renderer = new BUIDLRenderer(deployer);
        console.log("New BUIDLRenderer:", address(renderer));

        // Point BuildNFT to new renderer
        BuildNFT(BUILD_NFT).setRenderer(address(renderer));
        console.log("BuildNFT.setRenderer done");

        vm.stopBroadcast();

        console.log("");
        console.log("NEXT_PUBLIC_RENDERER_ADDRESS=", address(renderer));
        console.log("");
        console.log("Now run StoreRenderer.s.sol with RENDERER= set to the new address");
    }
}
