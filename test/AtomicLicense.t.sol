// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {Distributor} from "src/Distributor.sol";
import {LicenseNFT} from "src/LicenseNFT.sol";
import {LicenseRegistry} from "src/LicenseRegistry.sol";
import {GeometryRegistry} from "src/GeometryRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";

/// @notice Tests for the atomic license flow:
///   - BuildNFT._handleComponents() calls LicenseRegistry.mintLicenseOnBehalfOf()
///   - Licenses are minted directly to BuildNFT for escrow
///   - License fees in BLOX are charged from payer to protocolTreasury
///   - Bricks with components also get license handling
contract AtomicLicenseTest is Test {
    BuildNFT private buildNFT;
    GeometryRegistry private geometryRegistry;
    LicenseNFT private licenseNFT;
    LicenseRegistry private licenseRegistry;
    ERC20Mock private blox;
    Distributor private distributor;

    address private liquidityReceiver = address(0x200);
    address private protocolTreasury = address(0x300);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    uint8 private constant KIND_BRICK = 0;
    uint8 private constant KIND_BUILD = 1;
    uint256 private constant BLOX_PER_MASS = 1e18;
    uint256 private constant FEE_PER_MINT = 0.001 ether;

    function setUp() public {
        // Predict BuildNFT address (nonce: 0=blox, 1=distributor, 2=licenseNFT, 3=licenseRegistry, 4=buildNFT)
        uint256 nonce = vm.getNonce(address(this));
        address predictedBuild = vm.computeCreateAddress(address(this), nonce + 4);

        blox = new ERC20Mock();
        distributor = new Distributor(address(blox), address(this));
        licenseNFT = new LicenseNFT("ipfs://licenses");
        licenseRegistry =
            new LicenseRegistry(predictedBuild, address(licenseNFT), protocolTreasury);
        buildNFT = new BuildNFT(
            address(blox),
            address(distributor),
            liquidityReceiver,
            protocolTreasury,
            address(licenseRegistry),
            address(licenseNFT),
            1_000_000
        );
        require(address(buildNFT) == predictedBuild, "BuildNFT address mismatch");

        geometryRegistry = new GeometryRegistry(address(this));
        geometryRegistry.setBuildNFT(address(buildNFT));
        buildNFT.setGeometryRegistry(address(geometryRegistry));

        // Wire LicenseNFT
        licenseNFT.setRegistry(address(licenseRegistry));
        licenseNFT.setDistributor(address(distributor));

        // Wire Distributor
        distributor.setBuildNFT(address(buildNFT));
        distributor.setProtocolTreasury(protocolTreasury);
        distributor.setLicenseContracts(address(licenseRegistry), address(licenseNFT));

        // Enable build kind
        buildNFT.setKindEnabled(uint16(KIND_BUILD), true);

        // Fund users
        blox.mint(alice, 10_000 ether);
        blox.mint(bob, 10_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // Users approve BuildNFT for BLOX (lock + license fees)
        vm.prank(alice);
        blox.approve(address(buildNFT), type(uint256).max);
        vm.prank(bob);
        blox.approve(address(buildNFT), type(uint256).max);
    }

    // ==============================
    // Helpers
    // ==============================

    function _mintGenesisBrick(address minter, bytes32 geo) internal returns (uint256 tokenId) {
        vm.prank(minter);
        tokenId = buildNFT.mint{value: FEE_PER_MINT}(
            geo,
            1, // mass
            hex"01010101" hex"01", // genesis geometry: 1x1x1, colour 1
            new uint256[](0),
            new uint256[](0),
            new BuildNFT.PlacedComponent[](0),
            KIND_BRICK,
            1, // width
            1, // depth
            0  // density (unused)
        );
    }

    function _licenseCost(uint256[] memory componentIds, uint256[] memory componentCounts) internal view returns (uint256 cost) {
        for (uint256 i = 0; i < componentIds.length; i++) {
            cost += licenseRegistry.quote(componentIds[i], componentCounts[i]);
        }
    }

    function _mintBrickWithComponents(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint8 width,
        uint8 depth,
        uint256[] memory componentIds,
        uint256[] memory componentCounts
    ) internal returns (uint256 tokenId) {
        uint256 lc = _licenseCost(componentIds, componentCounts);
        vm.prank(minter);
        tokenId = buildNFT.mint{value: FEE_PER_MINT + lc}(
            geo,
            mass,
            "",
            componentIds,
            componentCounts,
            new BuildNFT.PlacedComponent[](0),
            KIND_BRICK,
            width,
            depth,
            0
        );
    }

    function _mintBuild(
        address minter,
        bytes32 geo,
        uint256 mass,
        uint256[] memory componentIds,
        uint256[] memory componentCounts
    ) internal returns (uint256 tokenId) {
        uint256 lc = _licenseCost(componentIds, componentCounts);
        vm.prank(minter);
        tokenId = buildNFT.mint{value: FEE_PER_MINT + lc}(
            geo,
            mass,
            "",
            componentIds,
            componentCounts,
            new BuildNFT.PlacedComponent[](0),
            KIND_BUILD,
            0,
            0,
            0
        );
    }

    // ==============================
    // Test: Genesis brick (no components)
    // ==============================

    function testMintGenesisBrick_NoComponents() public {
        bytes32 geo = keccak256("genesis-1x1");
        uint256 balBefore = blox.balanceOf(alice);

        uint256 tokenId = _mintGenesisBrick(alice, geo);

        assertEq(buildNFT.ownerOf(tokenId), alice);
        assertEq(buildNFT.massOf(tokenId), 1);
        assertEq(buildNFT.kindOf(tokenId), KIND_BRICK);
        // Only 1 BLOX locked (mass=1), no license fee
        assertEq(blox.balanceOf(alice), balBefore - 1 ether);
        assertEq(buildNFT.lockedBloxOf(tokenId), 1 ether);
    }

    // ==============================
    // Test: Brick with components (atomic license)
    // ==============================

    function testMintBrickWithComponents_AutoRegistersAndMintsLicense() public {
        // First mint a genesis 1x1 brick as a component
        uint256 componentId = _mintGenesisBrick(alice, keccak256("component-1x1"));

        // Now mint a 1x2 brick using that component
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 2; // 1x2 = 2 studs

        uint256 treasuryBefore = protocolTreasury.balance;

        uint256 brickId = _mintBrickWithComponents(
            alice,
            keccak256("brick-1x2"),
            2, // mass
            1,
            2,
            ids,
            counts
        );

        // Verify the brick was minted
        assertEq(buildNFT.ownerOf(brickId), alice);
        assertEq(buildNFT.kindOf(brickId), KIND_BRICK);

        // Verify license was auto-registered for the component
        uint256 licenseId = licenseRegistry.licenseIdForBuild(componentId);
        assertGt(licenseId, 0, "License should be auto-registered");

        // Verify license is escrowed in BuildNFT
        uint256 escrowedQty = buildNFT.escrowedLicenseQty(brickId, licenseId);
        assertEq(escrowedQty, 2, "License qty should be escrowed");

        // Verify license NFT balance is in BuildNFT
        assertGt(
            licenseNFT.balanceOf(address(buildNFT), licenseId),
            0,
            "BuildNFT should hold escrowed licenses"
        );

        // Verify ETH license fee was charged to protocolTreasury
        uint256 treasuryAfter = protocolTreasury.balance;
        assertGt(treasuryAfter, treasuryBefore, "Treasury should receive license fee in ETH");
    }

    // ==============================
    // Test: Build with components (atomic license)
    // ==============================

    function testMintBuildWithComponents_AtomicLicenseFlow() public {
        // Mint a genesis brick as component
        uint256 componentId = _mintGenesisBrick(alice, keccak256("build-component"));

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 1;

        uint256 aliceBloxBefore = blox.balanceOf(alice);
        uint256 treasuryBefore = protocolTreasury.balance;

        uint256 buildId = _mintBuild(
            alice,
            keccak256("build-1"),
            5, // mass
            ids,
            counts
        );

        // Verify the build was minted
        assertEq(buildNFT.ownerOf(buildId), alice);
        assertEq(buildNFT.kindOf(buildId), KIND_BUILD);
        assertEq(buildNFT.massOf(buildId), 5);

        // Verify license auto-registration
        uint256 licenseId = licenseRegistry.licenseIdForBuild(componentId);
        assertGt(licenseId, 0, "License should be auto-registered for component");

        // Verify escrowed license in BuildNFT
        uint256 escrowedQty = buildNFT.escrowedLicenseQty(buildId, licenseId);
        assertEq(escrowedQty, 1, "License should be escrowed");

        // Verify BLOX locked (mass=5)
        uint256 aliceBloxAfter = blox.balanceOf(alice);
        uint256 lockAmount = 5 ether;
        assertEq(aliceBloxBefore - aliceBloxAfter, lockAmount, "Should lock 5 BLOX");

        // Verify ETH license fee went to treasury
        uint256 treasuryAfter = protocolTreasury.balance;
        uint256 licenseFee = treasuryAfter - treasuryBefore;
        assertGt(licenseFee, 0, "Treasury should receive license fee in ETH");
    }

    // ==============================
    // Test: mintLicenseOnBehalfOf reverts for non-BuildNFT caller
    // ==============================

    function testMintLicenseOnBehalfOf_RevertsForNonBuildNFT() public {
        // Mint a genesis brick first so there's something to register
        uint256 componentId = _mintGenesisBrick(alice, keccak256("revert-test"));

        // Try calling mintLicenseOnBehalfOf directly as alice (not BuildNFT)
        vm.prank(alice);
        vm.expectRevert("only buildNFT");
        licenseRegistry.mintLicenseOnBehalfOf(componentId, 1, alice);

        // Try as bob
        vm.prank(bob);
        vm.expectRevert("only buildNFT");
        licenseRegistry.mintLicenseOnBehalfOf(componentId, 1, bob);

        // Try as contract deployer (this)
        vm.expectRevert("only buildNFT");
        licenseRegistry.mintLicenseOnBehalfOf(componentId, 1, address(this));
    }

    // ==============================
    // Test: License fee charged correctly from payer to treasury
    // ==============================

    function testLicenseFeeChargedCorrectly() public {
        // Mint a genesis brick
        uint256 componentId = _mintGenesisBrick(alice, keccak256("fee-component"));

        // Quote what the license should cost (mass=1 => maxSupply=10_000_000 => very low price tier)
        // After auto-register, the creator gets 1 free license, so sold=1.
        // For the mint, qty=1, so the price is startPrice + 1*step (since sold=1 after creator mint)
        // We'll verify by checking the actual transfer amounts.

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 1;

        uint256 aliceBloxBefore = blox.balanceOf(alice);
        uint256 treasuryEthBefore = protocolTreasury.balance;
        uint256 buildNFTBloxBefore = blox.balanceOf(address(buildNFT));

        _mintBuild(alice, keccak256("fee-build"), 3, ids, counts);

        uint256 aliceBloxAfter = blox.balanceOf(alice);
        uint256 treasuryEthAfter = protocolTreasury.balance;
        uint256 buildNFTBloxAfter = blox.balanceOf(address(buildNFT));

        uint256 lockAmount = 3 ether;
        uint256 licenseFeeEth = treasuryEthAfter - treasuryEthBefore;

        // Lock amount (BLOX) should go to BuildNFT
        assertEq(buildNFTBloxAfter - buildNFTBloxBefore, lockAmount, "BuildNFT should hold locked BLOX");

        // BLOX spent by alice = just lock amount (no BLOX license fee anymore)
        assertEq(aliceBloxBefore - aliceBloxAfter, lockAmount, "Only BLOX lock, no BLOX license fee");

        // License fee in ETH should go to treasury
        assertGt(licenseFeeEth, 0, "License fee in ETH should be positive");
    }

    // ==============================
    // Test: Licenses escrowed in BuildNFT after mint
    // ==============================

    function testLicensesEscrowedInBuildNFT() public {
        // Mint a 1x1 genesis brick as first component
        uint256 comp1 = _mintGenesisBrick(alice, keccak256("escrow-comp1"));

        // Mint a 1x2 brick as second component (different spec key than 1x1)
        uint256[] memory c1ids = new uint256[](1);
        uint256[] memory c1counts = new uint256[](1);
        c1ids[0] = comp1;
        c1counts[0] = 2;
        uint256 comp2 = _mintBrickWithComponents(
            alice, keccak256("escrow-comp2"), 2, 1, 2, c1ids, c1counts
        );

        uint256[] memory ids = new uint256[](2);
        uint256[] memory counts = new uint256[](2);
        ids[0] = comp1;
        ids[1] = comp2;
        counts[0] = 3;
        counts[1] = 2;

        uint256 buildId = _mintBuild(alice, keccak256("escrow-build"), 10, ids, counts);

        uint256 lic1 = licenseRegistry.licenseIdForBuild(comp1);
        uint256 lic2 = licenseRegistry.licenseIdForBuild(comp2);

        // Verify escrow quantities
        assertEq(buildNFT.escrowedLicenseQty(buildId, lic1), 3, "comp1 escrow qty");
        assertEq(buildNFT.escrowedLicenseQty(buildId, lic2), 2, "comp2 escrow qty");

        // Verify BuildNFT holds the license tokens
        assertGe(licenseNFT.balanceOf(address(buildNFT), lic1), 3, "BuildNFT holds lic1");
        assertGe(licenseNFT.balanceOf(address(buildNFT), lic2), 2, "BuildNFT holds lic2");
    }

    // ==============================
    // Test: Licenses released on burn
    // ==============================

    function testLicensesReleasedOnBurn() public {
        uint256 comp1 = _mintGenesisBrick(alice, keccak256("burn-comp"));

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = comp1;
        counts[0] = 1;

        uint256 buildId = _mintBuild(alice, keccak256("burn-build"), 5, ids, counts);

        uint256 licenseId = licenseRegistry.licenseIdForBuild(comp1);

        // Alice should not hold the escrowed license yet (it's in BuildNFT)
        uint256 aliceLicBefore = licenseNFT.balanceOf(alice, licenseId);

        // Burn the build
        uint256 burnFee = buildNFT.BURN_FEE();
        vm.prank(alice);
        buildNFT.burn{value: burnFee}(buildId);

        // After burn, escrowed licenses should be returned to alice
        uint256 aliceLicAfter = licenseNFT.balanceOf(alice, licenseId);
        assertEq(aliceLicAfter - aliceLicBefore, 1, "License returned to owner on burn");
    }

    // ==============================
    // Test: Different user (bob) minting with alice's component
    // ==============================

    function testCrossUserAtomicLicense() public {
        // Alice mints a genesis brick
        uint256 componentId = _mintGenesisBrick(alice, keccak256("cross-user-comp"));

        // Bob uses that component in a build
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 1;

        uint256 treasuryBefore = protocolTreasury.balance;

        uint256 buildId = _mintBuild(bob, keccak256("cross-build"), 2, ids, counts);

        // Bob owns the build
        assertEq(buildNFT.ownerOf(buildId), bob);

        // Treasury received the license fee in ETH
        uint256 treasuryAfter = protocolTreasury.balance;
        assertGt(treasuryAfter, treasuryBefore, "Treasury received ETH fee from bob's mint");

        // License is escrowed in BuildNFT for bob's build
        uint256 licenseId = licenseRegistry.licenseIdForBuild(componentId);
        assertEq(buildNFT.escrowedLicenseQty(buildId, licenseId), 1);
    }

    // ==============================
    // Test: Multiple qty for same component
    // ==============================

    function testMultipleQtyLicenseFee() public {
        uint256 componentId = _mintGenesisBrick(alice, keccak256("multi-qty-comp"));

        // Mint with qty=5 of the same component
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 5;

        uint256 treasuryBefore = protocolTreasury.balance;

        // Mint a brick (1x2 to use 2+ studs; but we need width/depth to make sense)
        // Actually for a build we don't need width/depth
        uint256 buildId = _mintBuild(alice, keccak256("multi-qty-build"), 10, ids, counts);

        uint256 treasuryAfter = protocolTreasury.balance;
        uint256 licenseFee = treasuryAfter - treasuryBefore;

        // With qty=5 the fee should be based on the bonding curve for 5 units
        // (starting from sold=1 since creator gets 1 free)
        assertGt(licenseFee, 0, "License fee for qty=5 should be positive");

        // Verify escrow
        uint256 licenseId = licenseRegistry.licenseIdForBuild(componentId);
        assertEq(buildNFT.escrowedLicenseQty(buildId, licenseId), 5);
        assertGe(licenseNFT.balanceOf(address(buildNFT), licenseId), 5);
    }

    // ==============================
    // Test: Reusing already-registered component doesn't re-register
    // ==============================

    function testReusesExistingRegistration() public {
        uint256 componentId = _mintGenesisBrick(alice, keccak256("reuse-comp"));

        // First build uses the component (triggers auto-register)
        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 1;

        _mintBuild(alice, keccak256("reuse-build-1"), 3, ids, counts);

        uint256 licenseId1 = licenseRegistry.licenseIdForBuild(componentId);
        uint256 nextLicBefore = licenseRegistry.nextLicenseId();

        // Second build uses the same component (should reuse, not re-register)
        _mintBuild(alice, keccak256("reuse-build-2"), 3, ids, counts);

        uint256 licenseId2 = licenseRegistry.licenseIdForBuild(componentId);
        uint256 nextLicAfter = licenseRegistry.nextLicenseId();

        assertEq(licenseId1, licenseId2, "Same licenseId for same component");
        assertEq(nextLicBefore, nextLicAfter, "No new license ID created");
    }

    // ==============================
    // Test: Insufficient ETH for license fees reverts
    // ==============================

    function testRevertsOnInsufficientETHForLicenseFee() public {
        uint256 componentId = _mintGenesisBrick(alice, keccak256("insuf-comp"));

        uint256[] memory ids = new uint256[](1);
        uint256[] memory counts = new uint256[](1);
        ids[0] = componentId;
        counts[0] = 1;

        // Send only FEE_PER_MINT, not enough for license fee
        vm.prank(bob);
        vm.expectRevert(); // Should revert due to insufficient ETH for license fee
        buildNFT.mint{value: FEE_PER_MINT}(
            keccak256("insuf-build"),
            3,
            "",
            ids,
            counts,
            new BuildNFT.PlacedComponent[](0),
            KIND_BUILD,
            0,
            0,
            0
        );
    }
}
