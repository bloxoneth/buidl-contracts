// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {LicenseRegistryV2} from "src/LicenseRegistryV2.sol";
import {WorldRegistry} from "src/WorldRegistry.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface ISetBuildNFT {
    function setBuildNFT(address) external;
}

interface ISetRegistry {
    function setRegistry(address) external;
}

interface ISetLicenseContracts {
    function setLicenseContracts(address, address) external;
}

interface ISetProtocolTreasury {
    function setProtocolTreasury(address) external;
}

interface ISetRenderer {
    function setRenderer(address) external;
    function setGeometryRegistry(address) external;
    function setBaseTokenURI(string calldata) external;
    function setKindEnabled(uint16, bool) external;
    function setBaseImageURI(string calldata) external;
    function setDistributor(address) external;
}

/// @title MigrateV3_1 — redeploy BuildNFT + LicenseRegistryV2 + WorldRegistry
/// @notice Keeps existing: LicenseNFT, GeometryRegistry, BUIDLRenderer, Distributor
///         Redeploys: BuildNFT (adds setLicenseRegistry), LicenseRegistryV2 (continuous pricing),
///                    WorldRegistry (immutable buildNFT reference)
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/MigrateV3_1.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract MigrateV3_1 is Script {
    // ── Existing contracts (keep) ──
    address constant BUIDL_TOKEN    = 0x6D280a9D90d16F84cea93D541fAAa23aB60b145f;
    address constant LICENSE_NFT    = 0xd35B2866Bb83eb019E3BBA7DDfde8aBb260e8462;
    address constant GEOMETRY_REG   = 0x2D818A74a920D84AB1663AfBF6b8CaF821c35135;
    address constant RENDERER       = 0xa240113cB2F6dCEEd337ccd28A197D64521d7B7D;
    address constant DISTRIBUTOR    = 0x3209146B4763241cC91e063FA3Ff177E48b01681;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
        address liquidityReceiver = vm.envOr("LIQUIDITY_RECEIVER", deployer);
        uint256 maxMass = vm.envOr("MAX_MASS", uint256(1_000_000));

        console.log("=== MigrateV3_1 ===");
        console.log("Deployer:", deployer);
        console.log("Treasury:", protocolTreasury);

        vm.startBroadcast(pk);

        // ── 1. Deploy LicenseRegistryV2 (needs predicted BuildNFT address) ──
        uint256 nonce = vm.getNonce(deployer);
        // LicenseRegistryV2 is nonce, BuildNFT is nonce+1, WorldRegistry is nonce+2
        address predictedBuildNFT = vm.computeCreateAddress(deployer, nonce + 1);

        LicenseRegistryV2 licenseRegistry = new LicenseRegistryV2(
            predictedBuildNFT,
            LICENSE_NFT,
            protocolTreasury,
            liquidityReceiver
        );
        console.log("LicenseRegistryV2:", address(licenseRegistry));

        // ── 2. Deploy BuildNFT (with setLicenseRegistry) ──
        BuildNFT buildNFT = new BuildNFT(
            BUIDL_TOKEN,
            DISTRIBUTOR,
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            LICENSE_NFT,
            maxMass
        );
        console.log("BuildNFT:", address(buildNFT));
        require(address(buildNFT) == predictedBuildNFT, "BuildNFT address mismatch");

        // ── 3. Deploy WorldRegistry (immutable buildNFT) ──
        WorldRegistry worldRegistry = new WorldRegistry(address(buildNFT), BUIDL_TOKEN, deployer);
        console.log("WorldRegistry:", address(worldRegistry));

        // ── 4. Re-wire existing contracts to new BuildNFT ──

        // LicenseNFT → new LicenseRegistryV2
        ISetRegistry(LICENSE_NFT).setRegistry(address(licenseRegistry));
        console.log("LicenseNFT.registry -> LicenseRegistryV2");

        // GeometryRegistry → new BuildNFT
        ISetBuildNFT(GEOMETRY_REG).setBuildNFT(address(buildNFT));
        console.log("GeometryRegistry.buildNFT -> new BuildNFT");

        // Distributor → new BuildNFT + new LicenseRegistryV2
        ISetBuildNFT(DISTRIBUTOR).setBuildNFT(address(buildNFT));
        ISetLicenseContracts(DISTRIBUTOR).setLicenseContracts(address(licenseRegistry), LICENSE_NFT);
        console.log("Distributor.buildNFT -> new BuildNFT");

        // ── 5. Configure new BuildNFT ──
        buildNFT.setGeometryRegistry(GEOMETRY_REG);
        buildNFT.setRenderer(RENDERER);
        buildNFT.setBaseTokenURI("https://buidl-one.vercel.app/api/builds/metadata");
        buildNFT.setBaseImageURI("https://buidl-one.vercel.app/api/builds/svg");
        buildNFT.setKindEnabled(1, true); // BUILD
        buildNFT.setKindEnabled(2, true); // COLLECTOR

        // ── 6. Mint genesis 1x1 brick ──
        bytes memory genesisGeo = hex"01010101" hex"01";
        bytes32 genesisHash = keccak256(genesisGeo);
        IERC20(BUIDL_TOKEN).approve(address(buildNFT), 1e18);

        buildNFT.mint{value: 0.001 ether}(
            genesisHash,
            1,
            genesisGeo,
            new uint256[](0),
            new uint256[](0),
            new BuildNFT.PlacedComponent[](0),
            0,  // kind: BRICK
            1,  // width
            1,  // depth
            0   // density
        );
        console.log("Genesis 1x1 brick minted as token #1");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Migration complete ===");
        console.log("Update .env.local with:");
        console.log("  NEXT_PUBLIC_BUILD_NFT_ADDRESS=", address(buildNFT));
        console.log("  NEXT_PUBLIC_LICENSE_REGISTRY_ADDRESS=", address(licenseRegistry));
        console.log("  NEXT_PUBLIC_WORLD_REGISTRY_ADDRESS=", address(worldRegistry));
        console.log("");
        console.log("Kept (no address change):");
        console.log("  LicenseNFT:", LICENSE_NFT);
        console.log("  GeometryRegistry:", GEOMETRY_REG);
        console.log("  BUIDLRenderer:", RENDERER);
        console.log("  Distributor:", DISTRIBUTOR);
    }
}
