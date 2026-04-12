// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BLOX} from "src/BLOX.sol";
import {BasebloxAccessPass} from "src/BasebloxAccessPass.sol";

contract BasebloxAccessPassTest is Test {
    BLOX private blox;
    BasebloxAccessPass private pass;

    address private owner = address(this);
    address private treasury = address(0xBEEF);
    address private alice = address(0xA11CE);

    function setUp() public {
        blox = new BLOX(owner);
        pass = new BasebloxAccessPass(
            address(blox),
            treasury,
            "ipfs://bafybeixpass/",
            "ipfs://bafybeixpass/contract.json"
        );
        blox.transfer(address(pass), 20_000_000e18);
        vm.deal(alice, 100 ether);
    }

    function testMintRequiresSaleActive() public {
        vm.prank(alice);
        vm.expectRevert(bytes("sale inactive"));
        pass.mint{value: 0.05 ether}(1);
    }

    function testMintTransfersPassAndBlox() public {
        pass.setSaleActive(true);

        vm.prank(alice);
        pass.mint{value: 0.1 ether}(2);

        assertEq(pass.totalMinted(), 2);
        assertEq(pass.ownerOf(1), alice);
        assertEq(pass.ownerOf(2), alice);
        assertEq(blox.balanceOf(alice), 0);
        assertEq(address(pass).balance, 0.1 ether);
    }

    function testMintRevertsOnWrongPayment() public {
        pass.setSaleActive(true);
        vm.prank(alice);
        vm.expectRevert(bytes("bad eth"));
        pass.mint{value: 0.05 ether}(2);
    }

    function testWithdrawETHToTreasury() public {
        pass.setSaleActive(true);
        vm.prank(alice);
        pass.mint{value: 0.05 ether}(1);

        uint256 beforeBal = treasury.balance;
        pass.withdrawETH();
        assertEq(address(pass).balance, 0);
        assertEq(treasury.balance, beforeBal + 0.05 ether);
    }

    function testTokenURIFormatting() public {
        pass.setSaleActive(true);
        vm.prank(alice);
        pass.mint{value: 0.05 ether}(1);
        assertEq(pass.tokenURI(1), "ipfs://bafybeixpass/1.json");
    }

    function testClaimBloxOncePerTokenAfterStart() public {
        pass.setSaleActive(true);
        vm.prank(alice);
        pass.mint{value: 0.1 ether}(2);

        pass.setClaimStart(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;

        vm.prank(alice);
        vm.expectRevert(bytes("claim not open"));
        pass.claimBlox(ids);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        pass.claimBlox(ids);
        assertEq(blox.balanceOf(alice), 20_000e18);

        vm.prank(alice);
        vm.expectRevert(bytes("already claimed"));
        pass.claimBlox(ids);
    }
}
