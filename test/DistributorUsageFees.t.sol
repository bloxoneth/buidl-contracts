// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "src/Distributor.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockBuildNFT {
    mapping(uint256 => address) private owners;
    mapping(uint256 => uint256) private locked;
    Distributor private distributor;

    function setOwner(uint256 buildId, address owner, uint256 lockedBlox) external {
        owners[buildId] = owner;
        locked[buildId] = lockedBlox;
    }

    function ownerOf(uint256 buildId) external view returns (address) {
        address o = owners[buildId];
        require(o != address(0), "NONEXISTENT");
        return o;
    }

    function lockedBloxOf(uint256 buildId) external view returns (uint256) {
        require(owners[buildId] != address(0), "NONEXISTENT");
        return locked[buildId];
    }

    function isActive(uint256 buildId) external view returns (bool) {
        return owners[buildId] != address(0);
    }

    function setDistributor(address payable distributor_) external {
        distributor = Distributor(distributor_);
    }

    function accrue(
        uint256[] calldata buildIds,
        uint256[] calldata counts,
        address payer,
        uint256 buildMass,
        uint256 buildDensity
    )
        external
        payable
    {
        distributor.accrueFromComposition{value: msg.value}(
            buildIds, counts, payer, buildMass, buildDensity
        );
    }
}

contract MockLicenseRegistryForDistributor {
    mapping(uint256 => uint256) public licenseIdForBuild;

    function setLicenseIdForBuild(uint256 buildId, uint256 licenseId) external {
        licenseIdForBuild[buildId] = licenseId;
    }
}

contract DistributorUsageFeesTest is Test {
    Distributor private distributor;
    MockBuildNFT private buildNFT;
    LicenseNFT private licenseNFT;
    MockLicenseRegistryForDistributor private licenseRegistry;
    ERC20Mock private blox;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA11);
    address private dave = address(0xDA7E);
    address private protocolTreasury = address(0xBEEF);

    function setUp() public {
        blox = new ERC20Mock();
        distributor = new Distributor(address(blox), address(this));
        buildNFT = new MockBuildNFT();
        licenseNFT = new LicenseNFT("ipfs://licenses/{id}.json");
        licenseRegistry = new MockLicenseRegistryForDistributor();

        buildNFT.setOwner(1, alice, 2 ether);
        buildNFT.setOwner(2, bob, 1 ether);
        buildNFT.setOwner(3, carol, 3 ether);

        buildNFT.setDistributor(payable(address(distributor)));
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);
        distributor.setLicenseContracts(address(licenseRegistry), address(licenseNFT));
        licenseNFT.setDistributor(address(distributor));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave, 10 ether);
    }

    function testAccrueSplitsByCountsAndTracksUniqueUsers() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory counts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        counts[0] = 32;
        counts[1] = 10;
        counts[2] = 8;

        uint256 value = 0.005 ether;
        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer, 10, 1);

        uint256 owedAlice = distributor.ethOwed(alice);
        uint256 owedBob = distributor.ethOwed(bob);
        uint256 owedCarol = distributor.ethOwed(carol);

        assertEq(owedAlice + owedBob + owedCarol, value);
        assertTrue(owedAlice > 0);
        assertTrue(owedBob > 0);
        assertTrue(owedCarol > 0);

        assertEq(distributor.uniqueUsers(1), 1);
        assertEq(distributor.uniqueUsers(2), 1);
        assertEq(distributor.uniqueUsers(3), 1);
        int256 bwBefore = distributor.bwScore(1);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer, 10, 1);

        assertEq(distributor.uniqueUsers(1), 1);
        assertEq(distributor.uniqueUsers(2), 1);
        assertEq(distributor.uniqueUsers(3), 1);
        assertTrue(distributor.bwScore(1) > bwBefore);
    }

    function testSelfPayAllowedAccruesToOwner() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory counts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        counts[0] = 3;
        counts[1] = 1;

        uint256 value = 0.004 ether;

        vm.prank(alice);
        buildNFT.accrue{value: value}(ids, counts, alice, 10, 1);

        uint256 share1 = distributor.ethOwed(alice);
        uint256 share2 = distributor.ethOwed(bob);
        assertEq(share1 + share2, value);
        assertEq(distributor.ethOwed(protocolTreasury), 0);
        assertTrue(share1 > 0);
        assertTrue(share2 > 0);
        assertEq(distributor.uniqueUsers(1), 1);
    }

    function testClaimResetsAndTransfers() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = 2;
        counts[0] = 1;

        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        buildNFT.accrue{value: 0.001 ether}(ids, counts, payer, 10, 1);

        uint256 owed = distributor.ethOwed(bob);
        uint256 before = bob.balance;

        vm.prank(bob);
        distributor.claim();

        assertEq(distributor.ethOwed(bob), 0);
        assertEq(bob.balance, before + owed);
    }

    function testOnlyBuildNFTCanAccrue() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = 1;
        counts[0] = 1;

        vm.expectRevert(bytes("only buildNFT"));
        distributor.accrueFromComposition{value: 1}(ids, counts, alice, 10, 1);
    }

    function testBurnedComponentRoutesToTreasury() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory counts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 999;
        counts[0] = 1;
        counts[1] = 1;

        uint256 value = 0.006 ether;
        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);

        uint256 treasuryBefore = distributor.ethOwed(protocolTreasury);
        uint256 aliceBefore = distributor.ethOwed(alice);

        vm.prank(payer);
        buildNFT.accrue{value: value}(ids, counts, payer, 10, 1);

        uint256 aliceDelta = distributor.ethOwed(alice) - aliceBefore;
        uint256 treasuryDelta = distributor.ethOwed(protocolTreasury) - treasuryBefore;
        assertEq(aliceDelta + treasuryDelta, value);
        assertTrue(aliceDelta > 0);
        assertTrue(treasuryDelta > 0);
    }

    function testLicenseHoldersAccrueAndClaimShare() public {
        distributor.setLicenseHolderBps(5_000); // 50% of component-owner slice

        uint256 buildId = 1;
        uint256 licenseId = 11;
        licenseRegistry.setLicenseIdForBuild(buildId, licenseId);

        licenseNFT.setRegistry(address(this));
        licenseNFT.setMaxSupply(licenseId, 10);
        licenseNFT.mint(bob, licenseId, 1);
        licenseNFT.mint(carol, licenseId, 1);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = buildId;
        counts[0] = 1;

        address payer = address(0xD00D);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        buildNFT.accrue{value: 1 ether}(ids, counts, payer, 10, 1);

        // Single component => 1 ETH goes to its route.
        // With 50% split: 0.5 ETH to owner (alice), 0.5 ETH to license pool.
        assertEq(distributor.ethOwed(alice), 0.5 ether);

        uint256[] memory licenseIds = new uint256[](1);
        licenseIds[0] = licenseId;
        (uint256 totalBob,) = distributor.pendingLicenseRewards(bob, licenseIds);
        (uint256 totalCarol,) = distributor.pendingLicenseRewards(carol, licenseIds);
        assertEq(totalBob, 0.25 ether);
        assertEq(totalCarol, 0.25 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        distributor.claimLicenseRewards(licenseIds);
        assertEq(bob.balance, bobBefore + 0.25 ether);
    }

    function testLicenseTransferChangesFutureAccrualOnly() public {
        distributor.setLicenseHolderBps(5_000);

        uint256 buildId = 1;
        uint256 licenseId = 11;
        licenseRegistry.setLicenseIdForBuild(buildId, licenseId);

        licenseNFT.setRegistry(address(this));
        licenseNFT.setMaxSupply(licenseId, 10);
        licenseNFT.mint(bob, licenseId, 1);
        licenseNFT.mint(carol, licenseId, 1);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = buildId;
        counts[0] = 1;
        uint256[] memory licenseIds = new uint256[](1);
        licenseIds[0] = licenseId;

        // Round 1: bob+carol each earn 0.25
        address payer = address(0xD00D);
        vm.deal(payer, 2 ether);
        vm.prank(payer);
        buildNFT.accrue{value: 1 ether}(ids, counts, payer, 10, 1);

        // Transfer bob's license to dave
        vm.prank(bob);
        licenseNFT.safeTransferFrom(bob, dave, licenseId, 1, "");

        // Round 2: dave+carol each earn 0.25
        vm.prank(payer);
        buildNFT.accrue{value: 1 ether}(ids, counts, payer, 10, 1);

        (uint256 bobPending,) = distributor.pendingLicenseRewards(bob, licenseIds);
        (uint256 carolPending,) = distributor.pendingLicenseRewards(carol, licenseIds);
        (uint256 davePending,) = distributor.pendingLicenseRewards(dave, licenseIds);

        assertEq(bobPending, 0); // already crystallized into ethOwed via transfer hooks
        assertEq(distributor.ethOwed(bob), 0.25 ether);
        assertEq(carolPending, 0.5 ether);
        assertEq(davePending, 0.25 ether);
    }
}
