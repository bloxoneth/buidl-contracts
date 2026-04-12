// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {Distributor} from "src/Distributor.sol";

/// @notice Fix missing config calls after partial deploy.
contract FixWiring is Script {
    address constant BUILD_NFT = 0xd92F0f448CDc90F45Ff2F53e705FD27031eC90B1;
    address constant GEOMETRY_REGISTRY = 0x55B2a040DC7086FDB36aFC192ba56861cBe15440;
    address constant RENDERER = 0xbF506c13b57a6CF777C3A2ffe0c58dE898Ff2a40;
    address constant DISTRIBUTOR = 0x1b84c736A495b88558ac9b4A0eCd42c91f193f6b;
    address constant LICENSE_REGISTRY = 0x3D7F6282e83FB97CF6A32F79b900C7A61eBC9A7c;
    address constant LICENSE_NFT = 0x61434EFA162745b29772d953DF47e4b894941C84;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        BuildNFT buildNFT = BuildNFT(BUILD_NFT);

        // Check and fix Distributor.setLicenseContracts if needed
        // (may have landed, but calling again is idempotent)
        Distributor(payable(DISTRIBUTOR)).setLicenseContracts(LICENSE_REGISTRY, LICENSE_NFT);
        console.log("Distributor.setLicenseContracts done");

        // Missing BuildNFT config
        buildNFT.setGeometryRegistry(GEOMETRY_REGISTRY);
        console.log("setGeometryRegistry done");

        buildNFT.setRenderer(RENDERER);
        console.log("setRenderer done");

        buildNFT.setBaseTokenURI("https://buidl-app.vercel.app/api/builds/metadata");
        console.log("setBaseTokenURI done");

        buildNFT.setKindEnabled(1, true);
        buildNFT.setKindEnabled(2, true);
        console.log("setKindEnabled done");

        vm.stopBroadcast();
    }
}
