// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Mint genesis brick (token #1) on new BuildNFT.
contract MintGenesis is Script {
    address constant BLOX = 0x6D280a9D90d16F84cea93D541fAAa23aB60b145f;
    address constant BUILD_NFT = 0xd92F0f448CDc90F45Ff2F53e705FD27031eC90B1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        BuildNFT buildNFT = BuildNFT(BUILD_NFT);

        bytes memory genesisGeo = hex"01010101" hex"01";
        bytes32 genesisHash = keccak256(genesisGeo);

        IERC20(BLOX).approve(address(buildNFT), 1e18);
        buildNFT.mint{value: 0.001 ether}(
            genesisHash,
            1,
            genesisGeo,
            new uint256[](0),
            new uint256[](0),
            new BuildNFT.PlacedComponent[](0),
            0,
            1,
            1,
            0
        );
        console.log("Genesis brick minted as token #1");

        vm.stopBroadcast();
    }
}
