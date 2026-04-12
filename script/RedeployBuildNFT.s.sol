// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {GeometryRegistry} from "src/GeometryRegistry.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";
import {WorldRegistry} from "src/WorldRegistry.sol";
import {Distributor} from "src/Distributor.sol";

/// @notice Redeploy BuildNFT + LicenseRegistry + WorldRegistry with animation_url support.
/// Keeps existing: BLOX, LicenseNFT, GeometryRegistry, BUIDLRenderer, Distributor.
/// Re-wires cross-contract references and re-mints genesis brick.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/RedeployBuildNFT.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract RedeployBuildNFT is Script {
    // === Existing contracts (kept as-is) ===
    address constant BLOX = 0x6D280a9D90d16F84cea93D541fAAa23aB60b145f;
    address constant LICENSE_NFT = 0x61434EFA162745b29772d953DF47e4b894941C84;
    address constant GEOMETRY_REGISTRY = 0x55B2a040DC7086FDB36aFC192ba56861cBe15440;
    address constant RENDERER = 0xbF506c13b57a6CF777C3A2ffe0c58dE898Ff2a40;
    address constant DISTRIBUTOR = 0x1b84c736A495b88558ac9b4A0eCd42c91f193f6b;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("Deployer:", deployer);
        console.log("--- Redeploying BuildNFT + LicenseRegistry + WorldRegistry ---");

        vm.startBroadcast(pk);

        // Step 1: Deploy new LicenseRegistry
        // Need to predict BuildNFT address (deployed 1 nonce after LicenseRegistry)
        uint256 nonce = vm.getNonce(deployer);
        address predictedBuildNFT = vm.computeCreateAddress(deployer, nonce + 1);
        console.log("Predicted BuildNFT:", predictedBuildNFT);

        LicenseRegistry licenseRegistry =
            new LicenseRegistry(predictedBuildNFT, LICENSE_NFT, deployer);
        console.log("New LicenseRegistry:", address(licenseRegistry));

        // Step 2: Deploy new BuildNFT (with animation_url in tokenURI)
        BuildNFT buildNFT = new BuildNFT(
            BLOX,
            DISTRIBUTOR,
            deployer,           // liquidityReceiver
            deployer,           // protocolTreasury
            address(licenseRegistry),
            LICENSE_NFT,
            1_000_000           // maxMass
        );
        console.log("New BuildNFT:", address(buildNFT));
        require(address(buildNFT) == predictedBuildNFT, "BuildNFT address mismatch");

        // Step 3: Deploy new WorldRegistry
        WorldRegistry worldRegistry = new WorldRegistry(address(buildNFT), BLOX, deployer);
        console.log("New WorldRegistry:", address(worldRegistry));

        // === Re-wire existing contracts ===

        // Wire LicenseNFT to new LicenseRegistry
        LicenseNFT(LICENSE_NFT).setRegistry(address(licenseRegistry));
        console.log("LicenseNFT.setRegistry -> new LicenseRegistry");

        // Wire GeometryRegistry to new BuildNFT
        GeometryRegistry(GEOMETRY_REGISTRY).setBuildNFT(address(buildNFT));
        console.log("GeometryRegistry.setBuildNFT -> new BuildNFT");

        // Wire Distributor to new BuildNFT + new LicenseRegistry
        Distributor(payable(DISTRIBUTOR)).setBuildNFT(address(buildNFT));
        Distributor(payable(DISTRIBUTOR)).setLicenseContracts(address(licenseRegistry), LICENSE_NFT);
        console.log("Distributor.setBuildNFT -> new BuildNFT");

        // === Configure new BuildNFT ===
        buildNFT.setGeometryRegistry(GEOMETRY_REGISTRY);
        buildNFT.setRenderer(RENDERER);

        string memory baseTokenURI = vm.envOr(
            "BASE_TOKEN_URI",
            string("https://buidl-app.vercel.app/api/builds/metadata")
        );
        buildNFT.setBaseTokenURI(baseTokenURI);

        // Enable build kinds
        buildNFT.setKindEnabled(1, true); // BUILD
        buildNFT.setKindEnabled(2, true); // COLLECTOR

        vm.stopBroadcast();

        // === Output new addresses for .env.local ===
        console.log("");
        console.log("=== Update .env.local ===");
        console.log("NEXT_PUBLIC_BUILDNFT_ADDRESS=", address(buildNFT));
        console.log("NEXT_PUBLIC_LICENSE_REGISTRY_ADDRESS=", address(licenseRegistry));
        console.log("NEXT_PUBLIC_WORLD_REGISTRY_ADDRESS=", address(worldRegistry));
        console.log("");
        console.log("=== Unchanged ===");
        console.log("NEXT_PUBLIC_BLOX_ADDRESS=", BLOX);
        console.log("NEXT_PUBLIC_GEOMETRY_REGISTRY_ADDRESS=", GEOMETRY_REGISTRY);
        console.log("NEXT_PUBLIC_RENDERER_ADDRESS=", RENDERER);
        console.log("NEXT_PUBLIC_DISTRIBUTOR_ADDRESS=", DISTRIBUTOR);
        console.log("NEXT_PUBLIC_LICENSE_NFT_ADDRESS=", LICENSE_NFT);
    }

}
