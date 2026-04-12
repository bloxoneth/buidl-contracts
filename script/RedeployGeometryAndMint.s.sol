// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {GeometryRegistry} from "src/GeometryRegistry.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Redeploy GeometryRegistry (fresh state) and mint genesis brick.
contract RedeployGeometryAndMint is Script {
    address constant BLOX = 0x6D280a9D90d16F84cea93D541fAAa23aB60b145f;
    address constant BUILD_NFT = 0xd92F0f448CDc90F45Ff2F53e705FD27031eC90B1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Deploy fresh GeometryRegistry
        GeometryRegistry geo = new GeometryRegistry(deployer);
        geo.setBuildNFT(BUILD_NFT);
        console.log("New GeometryRegistry:", address(geo));

        // Point BuildNFT to new GeometryRegistry
        BuildNFT(BUILD_NFT).setGeometryRegistry(address(geo));
        console.log("BuildNFT.setGeometryRegistry done");

        vm.stopBroadcast();

        console.log("");
        console.log("NEXT_PUBLIC_GEOMETRY_REGISTRY_ADDRESS=", address(geo));
    }
}
