// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "src/EmissionsController.sol";

contract EmissionsControllerTest is Test {
    EmissionsController private c;

    uint256 private constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        c = new EmissionsController(address(this), SUPPLY, 8000);
    }

    function testRollSingleDayUpdatesState() public {
        c.recordFlows(100_000e18, 10_000e18, 5_000e18);
        vm.warp(block.timestamp + 1 days);

        EmissionsController.RollResult memory r = c.rollToCurrentEpoch();

        assertEq(r.daysRolled, 2); // day 1 + day 2 rolled on first call
        assertGt(r.lastEmission, 0);
        assertEq(c.lastRolledEpoch(), 2);
        assertEq(c.rolledLockedTotal(), 90_000e18);
        assertEq(c.emissionByEpoch(1) > 0, true);
        assertEq(c.emissionByEpoch(2) > 0, true);
    }

    function testCatchUpPreservesTotalsAcrossMissedDays() public {
        c.recordFlows(70_000e18, 14_000e18, 0);
        vm.warp(block.timestamp + 7 days);
        c.rollToCurrentEpoch();

        assertEq(c.rolledLockedTotal(), 56_000e18);
        assertEq(c.lastRolledEpoch(), 8);
    }

    function testRateLimiterCapsUpMove() public {
        c.setBounds(0.7e18, 1.3e18, 0.2e18, 0.3e18, 0, 100_000_000, 0, 100_000_000);

        c.recordFlows(1_000e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        c.rollToCurrentEpoch();
        uint256 e1 = c.prevEmission();
        assertGt(e1, 0);

        c.recordFlows(500_000_000e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        c.rollToCurrentEpoch();
        uint256 e2 = c.prevEmission();

        uint256 upBound = (e1 * (1e18 + c.rhoUpWad())) / 1e18;
        assertLe(e2, upBound);
    }

    function testEmergencyModeStopsAfterMaxConsecutiveDays() public {
        c.setBounds(0.7e18, 1.3e18, 0.2e18, 0.3e18, 0, 500_000_000, 0, 500_000_000);
        c.setRecycleParams(0.02e18, 0.5e18, 2, true);

        c.setEmergencyMode(true);
        c.recordFlows(10_000e18, 0, 0);
        vm.warp(block.timestamp + 3 days);
        c.rollToCurrentEpoch();

        // Emergency turns off after hitting max consecutive days.
        assertEq(c.emergencyMode(), false);
        assertEq(c.emergencyStreakDays(), 0);
    }

    function testMinMaxPpbGuards() public {
        c.setBounds(0.7e18, 1.3e18, 1e18, 1e18, 10_000, 20_000, 0, 100_000_000);

        c.recordFlows(10e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        c.rollToCurrentEpoch();
        uint256 e = c.prevEmission();

        uint256 eMin = (SUPPLY * c.minDailyPpb()) / 1e9;
        uint256 eMax = (SUPPLY * c.maxDailyPpb()) / 1e9;
        assertGe(e, eMin);
        assertLe(e, eMax);
    }

    function testLockCoupledEmissionTracksPriorLocksAfterWarmup() public {
        c.recordLock(10_000_000e18);
        vm.warp(block.timestamp + 1 days);
        c.rollToCurrentEpoch();

        for (uint256 i = 0; i < 30; i++) {
            c.recordFlows(150_000e18, 50_000e18, 2_000e18);
            vm.warp(block.timestamp + 1 days);
            c.rollToCurrentEpoch();
        }

        // In late mature days, emission should stay near lock-coupled target band.
        for (uint256 epoch = 25; epoch <= c.lastRolledEpoch(); epoch++) {
            uint256 e = c.emissionByEpoch(epoch);
            uint256 ref = c.referenceLockByEpoch(epoch);
            if (ref == 0) continue;
            uint256 ratioWad = (e * 1e18) / ref;
            assertGe(ratioWad, 0.8e18);
            assertLe(ratioWad, 1.05e18);
        }
    }
}
