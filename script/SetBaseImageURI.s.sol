// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";

/// @notice Point BuildNFT tokenURI `image` field to the app's server-rendered SVG endpoint.
/// OpenSea / marketplaces will fetch `{baseImageURI}/{tokenId}` for the card image,
/// which serves the high-quality isometric SVG from lib/svg-renderer.ts.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/SetBaseImageURI.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract SetBaseImageURI is Script {
    address constant BUILD_NFT = 0x1213328B55003d0d85D1300f5F79928D6632D4A0;
    string constant BASE_IMAGE_URI = "https://buidl-app.vercel.app/api/builds/svg";

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        console.log("Deployer:", vm.addr(pk));
        console.log("Setting baseImageURI to:", BASE_IMAGE_URI);

        vm.startBroadcast(pk);
        BuildNFT(BUILD_NFT).setBaseImageURI(BASE_IMAGE_URI);
        vm.stopBroadcast();

        console.log("Done. tokenURI image field now uses:", BASE_IMAGE_URI);
    }
}
