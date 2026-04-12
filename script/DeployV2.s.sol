// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {Distributor} from "src/Distributor.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {GeometryRegistry} from "src/GeometryRegistry.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";
import {WorldRegistry} from "src/WorldRegistry.sol";
import {BLOX} from "src/BLOX.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice BUIDL full deployment script for Base Mainnet.
/// Deploys BUIDL token + all 7 protocol contracts, wires dependencies, mints genesis brick.
/// Usage:
///   PRIVATE_KEY=0x... forge script script/DeployV2.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract DeployV2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Deployer is treasury and liquidity receiver for initial deployment
        address liquidityReceiver = deployer;
        address protocolTreasury = deployer;
        uint256 maxMass = vm.envOr("MAX_MASS", uint256(1_000_000));
        uint256 licenseHolderBps = vm.envOr("LICENSE_HOLDER_BPS", uint256(0));
        string memory licenseBaseURI = vm.envOr(
            "LICENSE_BASE_URI",
            string("https://buidl-app.vercel.app/api/licenses/metadata/{id}")
        );

        vm.startBroadcast(pk);

        // Step 1: Deploy BUIDL token (1B supply minted to deployer)
        BLOX buidlToken = new BLOX(deployer);
        address blox = address(buidlToken);
        console.log("BUIDL Token:", blox);

        // Step 2: Deploy LicenseNFT
        LicenseNFT licenseNFT = new LicenseNFT(licenseBaseURI);
        console.log("LicenseNFT:", address(licenseNFT));

        // Step 3: Deploy GeometryRegistry
        GeometryRegistry geometryRegistry = new GeometryRegistry(deployer);
        console.log("GeometryRegistry:", address(geometryRegistry));

        // Step 4: Deploy BUIDLRenderer
        BUIDLRenderer renderer = new BUIDLRenderer(deployer);
        console.log("BUIDLRenderer:", address(renderer));

        // Step 5: Deploy EmissionsController (already deployed or skip for v2)

        // Step 6: Deploy Distributor
        Distributor distributor = new Distributor(blox, deployer);
        console.log("Distributor:", address(distributor));

        // Step 7: Deploy LicenseRegistry (with placeholder buildNFT)
        // Predict BuildNFT address: current nonce + 1 (LicenseRegistry) + 1 (BuildNFT)
        uint256 nonce = vm.getNonce(deployer);
        address predictedBuildNFT = vm.computeCreateAddress(deployer, nonce + 1);

        LicenseRegistry licenseRegistry =
            new LicenseRegistry(predictedBuildNFT, address(licenseNFT), protocolTreasury);
        console.log("LicenseRegistry:", address(licenseRegistry));

        // Step 8: Deploy BuildNFT
        BuildNFT buildNFT = new BuildNFT(
            blox,
            address(distributor),
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            address(licenseNFT),
            maxMass
        );
        console.log("BuildNFT:", address(buildNFT));
        require(address(buildNFT) == predictedBuildNFT, "BuildNFT address mismatch");

        // Step 9: Deploy WorldRegistry
        WorldRegistry worldRegistry = new WorldRegistry(address(buildNFT), blox, deployer);
        console.log("WorldRegistry:", address(worldRegistry));

        // === Post-deploy wiring ===

        // Wire LicenseNFT
        licenseNFT.setRegistry(address(licenseRegistry));
        licenseNFT.setDistributor(address(distributor));

        // Wire GeometryRegistry
        geometryRegistry.setBuildNFT(address(buildNFT));

        // Wire Distributor
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);
        distributor.setLicenseContracts(address(licenseRegistry), address(licenseNFT));
        distributor.setLicenseHolderBps(uint16(licenseHolderBps));

        // Wire BuildNFT
        buildNFT.setGeometryRegistry(address(geometryRegistry));
        buildNFT.setRenderer(address(renderer));

        // Set baseTokenURI for marketplace compatibility (HTTP metadata endpoint)
        string memory baseTokenURI = vm.envOr(
            "BASE_TOKEN_URI",
            string("https://buidl-app.vercel.app/api/builds/metadata")
        );
        buildNFT.setBaseTokenURI(baseTokenURI);

        // Enable build kinds
        buildNFT.setKindEnabled(1, true);
        buildNFT.setKindEnabled(2, true);

        // === Store renderer HTML (placeholder — replace with actual HTML before mainnet) ===
        // For now, store a minimal placeholder
        renderer.storeRenderer(
            bytes(
                "<!DOCTYPE html><html><head><meta charset='utf-8'></head>"
                "<body><canvas id='c'></canvas>"
                "<script>"
                "const P=['#000000','#F0F0F0','#B85C38','#8B5E3C','#5A8C3F','#5B9BD5','#D4B483','#2D2D2D'];"
                "document.body.style.background='#111';"
                "const c=document.getElementById('c');"
                "c.width=c.height=600;"
                "const ctx=c.getContext('2d');"
                "if(typeof BUIDL_GEO!=='undefined'){"
                "const b=atob(BUIDL_GEO).split('').map(c=>c.charCodeAt(0));"
                "const bx=b[1],by=b[2],bz=b[3];"
                "const s=Math.min(500/Math.max(bx,bz),500/by)|0;"
                "for(let z=bz-1;z>=0;z--)for(let y=0;y<by;y++)for(let x=0;x<bx;x++){"
                "const i=x+y*bx+z*bx*by,bi=Math.floor(i*3/8),bo=(i*3)%8;"
                "let ci=(b[4+bi]>>bo)&7;if(bo>5&&4+bi+1<b.length)ci|=(b[4+bi+1]<<(8-bo))&7;"
                "if(ci){ctx.fillStyle=P[ci];const sx=(x-z)*s/2+300,sy=(x+z)*s/4-y*s/2+300;"
                "ctx.fillRect(sx,sy,s/2,s/2);}}"
                "}"
                "</script></body></html>"
            )
        );

        // === Mint genesis 1x1x1 brick ===
        // Genesis geometry: single voxel at (0,0,0), colour index 1 (Off White)
        // Header: [version=1, bboxX=1, bboxY=1, bboxZ=1]
        // Voxel data: colour index 1 = 0b001 packed into 1 byte = 0x01
        bytes memory genesisGeo = hex"01010101" hex"01";
        bytes32 genesisHash = keccak256(genesisGeo);

        // Approve BLOX for genesis mint (mass=1 → 1e18 BLOX)
        IERC20(blox).approve(address(buildNFT), 1e18);

        buildNFT.mint{value: 0.001 ether}(
            genesisHash,
            1, // mass: 1 BLOX
            genesisGeo,
            new uint256[](0), // no components
            new uint256[](0), // no counts
            new BuildNFT.PlacedComponent[](0), // empty manifest
            0, // kind: BRICK
            1, // width
            1, // depth
            0 // density (unused in v2)
        );
        console.log("Genesis brick minted as token #1");

        vm.stopBroadcast();

        // === Output addresses for .env ===
        console.log("=== Add to .env.local ===");
        console.log("NEXT_PUBLIC_BLOX_ADDRESS=", blox);
        console.log("NEXT_PUBLIC_BUILDNFT_ADDRESS=", address(buildNFT));
        console.log("NEXT_PUBLIC_GEOMETRY_REGISTRY_ADDRESS=", address(geometryRegistry));
        console.log("NEXT_PUBLIC_RENDERER_ADDRESS=", address(renderer));
        console.log("NEXT_PUBLIC_WORLD_REGISTRY_ADDRESS=", address(worldRegistry));
        console.log("NEXT_PUBLIC_LICENSE_NFT_ADDRESS=", address(licenseNFT));
        console.log("NEXT_PUBLIC_LICENSE_REGISTRY_ADDRESS=", address(licenseRegistry));
        console.log("NEXT_PUBLIC_DISTRIBUTOR_ADDRESS=", address(distributor));
    }
}
