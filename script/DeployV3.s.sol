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
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice BUIDL V3 deployment — reuses existing BUIDL token, deploys fresh protocol contracts.
/// License fees are now paid in ETH (not BLOX). BLOX is only locked for mass.
///
/// Usage:
///   PRIVATE_KEY=0x... BLOX_ADDRESS=0x6D28... forge script script/DeployV3.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract DeployV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Existing BUIDL token — do NOT redeploy
        address blox = vm.envAddress("BLOX_ADDRESS");
        require(blox != address(0), "BLOX_ADDRESS required");
        console.log("Using existing BUIDL token:", blox);

        // Deployer is treasury and liquidity receiver for initial deployment
        address liquidityReceiver = vm.envOr("LIQUIDITY_RECEIVER", deployer);
        address protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
        uint256 maxMass = vm.envOr("MAX_MASS", uint256(1_000_000));
        uint256 licenseHolderBps = vm.envOr("LICENSE_HOLDER_BPS", uint256(0));
        string memory licenseBaseURI = vm.envOr(
            "LICENSE_BASE_URI",
            string("https://buidl-app.vercel.app/api/licenses/metadata/{id}")
        );
        string memory baseTokenURI = vm.envOr(
            "BASE_TOKEN_URI",
            string("https://buidl-app.vercel.app/api/builds/metadata")
        );

        console.log("Deployer:", deployer);
        console.log("Treasury:", protocolTreasury);
        console.log("Liquidity receiver:", liquidityReceiver);

        vm.startBroadcast(pk);

        // ─── Deploy protocol contracts ───

        // 1. LicenseNFT
        LicenseNFT licenseNFT = new LicenseNFT(licenseBaseURI);
        console.log("LicenseNFT:", address(licenseNFT));

        // 2. GeometryRegistry
        GeometryRegistry geometryRegistry = new GeometryRegistry(deployer);
        console.log("GeometryRegistry:", address(geometryRegistry));

        // 3. BUIDLRenderer
        BUIDLRenderer renderer = new BUIDLRenderer(deployer);
        console.log("BUIDLRenderer:", address(renderer));

        // 4. Distributor
        Distributor distributor = new Distributor(blox, deployer);
        console.log("Distributor:", address(distributor));

        // 5. LicenseRegistry (predict BuildNFT address for constructor)
        uint256 nonce = vm.getNonce(deployer);
        address predictedBuildNFT = vm.computeCreateAddress(deployer, nonce + 1);

        LicenseRegistry licenseRegistry =
            new LicenseRegistry(predictedBuildNFT, address(licenseNFT), protocolTreasury);
        console.log("LicenseRegistry:", address(licenseRegistry));

        // 6. BuildNFT
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

        // 7. WorldRegistry
        WorldRegistry worldRegistry = new WorldRegistry(address(buildNFT), blox, deployer);
        console.log("WorldRegistry:", address(worldRegistry));

        // ─── Post-deploy wiring ───

        licenseNFT.setRegistry(address(licenseRegistry));
        licenseNFT.setDistributor(address(distributor));

        geometryRegistry.setBuildNFT(address(buildNFT));

        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);
        distributor.setLicenseContracts(address(licenseRegistry), address(licenseNFT));
        distributor.setLicenseHolderBps(uint16(licenseHolderBps));

        buildNFT.setGeometryRegistry(address(geometryRegistry));
        buildNFT.setRenderer(address(renderer));
        buildNFT.setBaseTokenURI(baseTokenURI);

        // Enable build kinds (0=brick is always on)
        buildNFT.setKindEnabled(1, true); // BUILD
        buildNFT.setKindEnabled(2, true); // COLLECTOR

        // ─── Store on-chain renderer HTML ───
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

        // ─── Mint genesis 1x1x1 brick ───
        bytes memory genesisGeo = hex"01010101" hex"01";
        bytes32 genesisHash = keccak256(genesisGeo);

        // Approve BLOX for genesis mint (mass=1 → 1e18 BLOX)
        IERC20(blox).approve(address(buildNFT), 1e18);

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
            0   // density (unused, FIXED_DENSITY=1)
        );
        console.log("Genesis brick minted as token #1");

        vm.stopBroadcast();

        // ─── Output for .env.local ───
        console.log("");
        console.log("=== Add to .env.local ===");
        console.log(string.concat("NEXT_PUBLIC_BLOX_ADDRESS=", vm.toString(blox)));
        console.log(string.concat("NEXT_PUBLIC_BUILDNFT_ADDRESS=", vm.toString(address(buildNFT))));
        console.log(string.concat("NEXT_PUBLIC_GEOMETRY_REGISTRY_ADDRESS=", vm.toString(address(geometryRegistry))));
        console.log(string.concat("NEXT_PUBLIC_RENDERER_ADDRESS=", vm.toString(address(renderer))));
        console.log(string.concat("NEXT_PUBLIC_WORLD_REGISTRY_ADDRESS=", vm.toString(address(worldRegistry))));
        console.log(string.concat("NEXT_PUBLIC_LICENSE_NFT_ADDRESS=", vm.toString(address(licenseNFT))));
        console.log(string.concat("NEXT_PUBLIC_LICENSE_REGISTRY_ADDRESS=", vm.toString(address(licenseRegistry))));
        console.log(string.concat("NEXT_PUBLIC_DISTRIBUTOR_ADDRESS=", vm.toString(address(distributor))));
    }
}
