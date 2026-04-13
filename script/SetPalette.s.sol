// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IBUIDLRenderer {
    function setPalette(bytes3[8] calldata newPalette) external;
    function palette(uint256 index) external view returns (bytes3);
}

/// @notice Update on-chain palette to bold primary LEGO-like colours.
///
/// New palette (matching app lib/palette.ts):
///   0: #000000  Empty (not selectable)
///   1: #FF3333  Red
///   2: #FF9933  Orange
///   3: #FFCC33  Yellow
///   4: #33CC66  Green
///   5: #33CCFF  Light Blue
///   6: #9933CC  Purple
///   7: #333333  Black
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/SetPalette.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast --chain-id 8453 --slow -vvv
contract SetPalette is Script {
    address constant RENDERER = 0xa240113cB2F6dCEEd337ccd28A197D64521d7B7D;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        console.log("Deployer:", vm.addr(pk));

        bytes3[8] memory newPalette = [
            bytes3(0x000000), // 0 - Empty
            bytes3(0xFF3333), // 1 - Red
            bytes3(0xFF9933), // 2 - Orange
            bytes3(0xFFCC33), // 3 - Yellow
            bytes3(0x33CC66), // 4 - Green
            bytes3(0x33CCFF), // 5 - Light Blue
            bytes3(0x9933CC), // 6 - Purple
            bytes3(0x333333)  // 7 - Black
        ];

        console.log("Setting palette on BUIDLRenderer at:", RENDERER);

        vm.startBroadcast(pk);
        IBUIDLRenderer(RENDERER).setPalette(newPalette);
        vm.stopBroadcast();

        console.log("Palette updated. Verifying...");
        for (uint256 i = 0; i < 8; i++) {
            bytes3 c = IBUIDLRenderer(RENDERER).palette(i);
            console.log("  palette[%d] = %s", i);
        }
        console.log("Done.");
    }
}
