// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Daily emissions controller with bounded dynamics and catch-up rolling.
contract EmissionsController is Ownable {
    uint256 public constant WAD = 1e18;
    uint256 public constant PPB_DENOMINATOR = 1e9;
    uint256 public constant EMERGENCY_HORIZON_DAYS = 1460;

    struct RollResult {
        uint256 daysRolled;
        uint256 fromEpoch;
        uint256 toEpoch;
        uint256 lastEmission;
        uint256 poolRemaining;
        uint256 recycleBuffer;
        uint256 rolledLockedTotal;
    }

    uint256 public immutable launchTimestamp;
    uint256 public immutable totalBloxSupply;
    uint256 public immutable poolInitial;

    // params (1e18 fixed point except ppb/day values)
    uint256 public lambdaWad;
    uint256 public clipMultiplierWad;
    uint256 public alphaWad;
    uint256 public kWad;
    uint256 public betaWad;
    uint256 public gammaWad;
    uint256 public targetLockEmitWad;
    uint256 public lockCouplingWad;
    uint256 public lockRefCapWad;
    uint256 public gMinWad;
    uint256 public gMaxWad;
    uint256 public rhoUpWad;
    uint256 public rhoDownWad;
    uint256 public epsilon;
    uint32 public dMinDays;
    uint32 public minDailyPpb;
    uint32 public maxDailyPpb;
    uint32 public minDailyPpbLocked;
    uint32 public maxDailyPpbLocked;
    uint16 public maxEmergencyDays;
    bool public activityGate;

    bool public paramsFrozen;

    uint256 public poolRemaining;
    uint256 public recycleBuffer;
    uint256 public prevEmission;
    uint256 public emaAbsDelta;
    int256 public emaDelta;
    uint256 public emaLock;
    uint256 public prevClippedLock;
    uint256 public lastReferenceLock;

    uint256 public lastRolledEpoch;
    uint256 public rolledLockedTotal;

    uint256 public cumulativeLocked;
    uint256 public cumulativeUnlocked;
    uint256 public cumulativeRecycled;

    uint256 public snapshotLocked;
    uint256 public snapshotUnlocked;
    uint256 public snapshotRecycled;

    bool public emergencyMode;
    uint256 public emergencyStreakDays;

    mapping(uint256 => uint256) public emissionByEpoch;
    mapping(uint256 => uint256) public referenceLockByEpoch;

    event ParamsSet();
    event ParamsFrozen();
    event EmergencyModeSet(bool enabled);
    event FlowsRecorded(uint256 lockAmount, uint256 unlockAmount, uint256 recycleAmount);
    event DayRolled(uint256 indexed epoch, uint256 emission, uint256 tAfter, int256 delta);
    event Rolled(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 daysRolled);

    error InvalidParams();
    error ParamsAreFrozen();
    error InvalidFlow();
    error NothingToRoll();

    constructor(address owner_, uint256 totalBloxSupply_, uint16 poolBps) Ownable(owner_) {
        if (totalBloxSupply_ == 0 || poolBps == 0 || poolBps > 10_000) revert InvalidParams();
        launchTimestamp = block.timestamp;
        totalBloxSupply = totalBloxSupply_;
        poolInitial = (totalBloxSupply_ * poolBps) / 10_000;
        poolRemaining = poolInitial;

        // Base-like defaults
        lambdaWad = 0.25e18;
        clipMultiplierWad = 3e18;
        alphaWad = 0.2e18;
        kWad = 8e18;
        betaWad = 0.005e18;
        gammaWad = 0.2e18;
        targetLockEmitWad = 0.95e18;
        lockCouplingWad = 0.995e18;
        lockRefCapWad = 1.05e18;
        gMinWad = 0.7e18;
        gMaxWad = 1.3e18;
        rhoUpWad = 0.2e18;
        rhoDownWad = 0.7e18;
        epsilon = 1e18;
        dMinDays = 14;
        minDailyPpb = 10_000;
        maxDailyPpb = 10_000_000;
        minDailyPpbLocked = 0;
        maxDailyPpbLocked = 100_000_000;
        maxEmergencyDays = 3;
        activityGate = true;
    }

    function currentEpoch() public view returns (uint256) {
        return ((block.timestamp - launchTimestamp) / 1 days) + 1;
    }

    function setCoreParams(
        uint256 lambdaWad_,
        uint256 clipMultiplierWad_,
        uint256 alphaWad_,
        uint256 kWad_,
        uint256 epsilon_,
        uint32 dMinDays_
    ) external onlyOwner {
        if (paramsFrozen) revert ParamsAreFrozen();
        if (lambdaWad_ == 0 || lambdaWad_ > WAD) revert InvalidParams();
        if (clipMultiplierWad_ == 0 || alphaWad_ == 0 || kWad_ == 0) revert InvalidParams();
        if (epsilon_ == 0 || dMinDays_ == 0) revert InvalidParams();

        lambdaWad = lambdaWad_;
        clipMultiplierWad = clipMultiplierWad_;
        alphaWad = alphaWad_;
        kWad = kWad_;
        epsilon = epsilon_;
        dMinDays = dMinDays_;
        emit ParamsSet();
    }

    function setBounds(
        uint256 gMinWad_,
        uint256 gMaxWad_,
        uint256 rhoUpWad_,
        uint256 rhoDownWad_,
        uint32 minDailyPpb_,
        uint32 maxDailyPpb_,
        uint32 minDailyPpbLocked_,
        uint32 maxDailyPpbLocked_
    ) external onlyOwner {
        if (paramsFrozen) revert ParamsAreFrozen();
        if (gMinWad_ == 0 || gMaxWad_ < gMinWad_) revert InvalidParams();
        if (rhoUpWad_ > WAD || rhoDownWad_ > WAD) revert InvalidParams();
        if (minDailyPpb_ > maxDailyPpb_) revert InvalidParams();
        if (minDailyPpbLocked_ > maxDailyPpbLocked_) revert InvalidParams();

        gMinWad = gMinWad_;
        gMaxWad = gMaxWad_;
        rhoUpWad = rhoUpWad_;
        rhoDownWad = rhoDownWad_;
        minDailyPpb = minDailyPpb_;
        maxDailyPpb = maxDailyPpb_;
        minDailyPpbLocked = minDailyPpbLocked_;
        maxDailyPpbLocked = maxDailyPpbLocked_;
        emit ParamsSet();
    }

    function setLockCouplingParams(
        uint256 targetLockEmitWad_,
        uint256 lockCouplingWad_,
        uint256 lockRefCapWad_
    ) external onlyOwner {
        if (paramsFrozen) revert ParamsAreFrozen();
        if (targetLockEmitWad_ > WAD || lockCouplingWad_ > WAD) revert InvalidParams();
        if (lockRefCapWad_ == 0) revert InvalidParams();

        targetLockEmitWad = targetLockEmitWad_;
        lockCouplingWad = lockCouplingWad_;
        lockRefCapWad = lockRefCapWad_;
        emit ParamsSet();
    }

    function setRecycleParams(
        uint256 betaWad_,
        uint256 gammaWad_,
        uint16 maxEmergencyDays_,
        bool activityGate_
    ) external onlyOwner {
        if (paramsFrozen) revert ParamsAreFrozen();
        if (betaWad_ > WAD || gammaWad_ > WAD) revert InvalidParams();
        if (maxEmergencyDays_ == 0) revert InvalidParams();

        betaWad = betaWad_;
        gammaWad = gammaWad_;
        maxEmergencyDays = maxEmergencyDays_;
        activityGate = activityGate_;
        emit ParamsSet();
    }

    function freezeParams() external onlyOwner {
        paramsFrozen = true;
        emit ParamsFrozen();
    }

    function setEmergencyMode(bool enabled) external onlyOwner {
        emergencyMode = enabled;
        if (!enabled) emergencyStreakDays = 0;
        emit EmergencyModeSet(enabled);
    }

    function recordLock(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidFlow();
        cumulativeLocked += amount;
        emit FlowsRecorded(amount, 0, 0);
    }

    function recordUnlock(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidFlow();
        cumulativeUnlocked += amount;
        emit FlowsRecorded(0, amount, 0);
    }

    function recordRecycle(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidFlow();
        cumulativeRecycled += amount;
        emit FlowsRecorded(0, 0, amount);
    }

    function recordFlows(uint256 lockAmount, uint256 unlockAmount, uint256 recycleAmount)
        external
        onlyOwner
    {
        if (lockAmount == 0 && unlockAmount == 0 && recycleAmount == 0) revert InvalidFlow();
        if (lockAmount > 0) cumulativeLocked += lockAmount;
        if (unlockAmount > 0) cumulativeUnlocked += unlockAmount;
        if (recycleAmount > 0) cumulativeRecycled += recycleAmount;
        emit FlowsRecorded(lockAmount, unlockAmount, recycleAmount);
    }

    function rollToCurrentEpoch() external returns (RollResult memory out) {
        uint256 epochNow = currentEpoch();
        if (epochNow <= lastRolledEpoch) revert NothingToRoll();

        uint256 daysElapsed = epochNow - lastRolledEpoch;
        uint256 deltaLockTotal = cumulativeLocked - snapshotLocked;
        uint256 deltaUnlockTotal = cumulativeUnlocked - snapshotUnlocked;
        uint256 deltaRecycleTotal = cumulativeRecycled - snapshotRecycled;

        uint256 lockPerDay = deltaLockTotal / daysElapsed;
        uint256 lockRem = deltaLockTotal % daysElapsed;
        uint256 unlockPerDay = deltaUnlockTotal / daysElapsed;
        uint256 unlockRem = deltaUnlockTotal % daysElapsed;
        uint256 recyclePerDay = deltaRecycleTotal / daysElapsed;
        uint256 recycleRem = deltaRecycleTotal % daysElapsed;

        uint256 fromEpoch = lastRolledEpoch + 1;
        uint256 epoch = fromEpoch;
        for (uint256 i = 0; i < daysElapsed; i++) {
            uint256 lToday = lockPerDay + (i < lockRem ? 1 : 0);
            uint256 uToday = unlockPerDay + (i < unlockRem ? 1 : 0);
            uint256 rToday = recyclePerDay + (i < recycleRem ? 1 : 0);
            _rollOneDay(epoch, lToday, uToday, rToday);
            epoch++;
        }

        lastRolledEpoch = epochNow;
        snapshotLocked = cumulativeLocked;
        snapshotUnlocked = cumulativeUnlocked;
        snapshotRecycled = cumulativeRecycled;

        out = RollResult({
            daysRolled: daysElapsed,
            fromEpoch: fromEpoch,
            toEpoch: epochNow,
            lastEmission: prevEmission,
            poolRemaining: poolRemaining,
            recycleBuffer: recycleBuffer,
            rolledLockedTotal: rolledLockedTotal
        });

        emit Rolled(fromEpoch, epochNow, daysElapsed);
    }

    function _rollOneDay(uint256 dayNum, uint256 lToday, uint256 uToday, uint256 rToday) internal {
        int256 delta = int256(lToday) - int256(uToday);
        uint256 clippedLock;
        {
            emaLock = _ema(emaLock, lToday, lambdaWad);
            uint256 lockClipBound = _wmul(emaLock, clipMultiplierWad);
            clippedLock = _clip(lToday, 0, lockClipBound);

            uint256 absDelta = _abs(delta);
            emaAbsDelta = _ema(emaAbsDelta, absDelta, lambdaWad);
            int256 clipBound = int256(_wmul(emaAbsDelta, clipMultiplierWad));
            int256 clippedDelta = _clipSigned(delta, -clipBound, clipBound);
            emaDelta = _emaSigned(emaDelta, clippedDelta, lambdaWad);
        }

        uint256 emission;
        emission = _computeEmissionCore(dayNum, clippedLock, rToday);

        if (activityGate && rolledLockedTotal == 0 && recycleBuffer == 0) emission = 0;

        {
            uint256 eMinSupply = (totalBloxSupply * minDailyPpb) / PPB_DENOMINATOR;
            uint256 eMaxSupply = (totalBloxSupply * maxDailyPpb) / PPB_DENOMINATOR;
            uint256 eMinLocked = (rolledLockedTotal * minDailyPpbLocked) / PPB_DENOMINATOR;
            uint256 eMaxLocked = (rolledLockedTotal * maxDailyPpbLocked) / PPB_DENOMINATOR;
            uint256 eMin = eMinSupply > eMinLocked ? eMinSupply : eMinLocked;
            uint256 eMax = eMaxSupply < eMaxLocked ? eMaxSupply : eMaxLocked;
            if (eMax < eMin) eMax = eMin;
            emission = _clip(emission, eMin, eMax);
        }

        if (prevEmission > 0) {
            uint256 down = _wmul(prevEmission, WAD - rhoDownWad);
            uint256 up = _wmul(prevEmission, WAD + rhoUpWad);
            emission = _clip(emission, down, up);
        }

        emission = _applyEmergency(dayNum, emission);

        if (emission > poolRemaining) emission = poolRemaining;
        poolRemaining -= emission;
        prevEmission = emission;
        prevClippedLock = clippedLock;
        emissionByEpoch[dayNum] = emission;

        if (delta >= 0) {
            rolledLockedTotal += uint256(delta);
        } else {
            uint256 dec = uint256(-delta);
            rolledLockedTotal = dec > rolledLockedTotal ? 0 : rolledLockedTotal - dec;
        }

        emit DayRolled(dayNum, emission, rolledLockedTotal, delta);
    }

    function _computeEmissionCore(uint256 dayNum, uint256 clippedLock, uint256 rToday)
        internal
        returns (uint256)
    {
        uint256 divisor = dayNum > dMinDays ? dayNum : dMinDays;
        uint256 baselineRaw = (rolledLockedTotal * alphaWad) / (WAD * divisor);

        int256 ratio = (emaDelta * int256(WAD)) / int256(rolledLockedTotal + epsilon);
        int256 tweak = (int256(kWad) * ratio) / int256(WAD);
        int256 g = int256(WAD) + tweak;
        if (g < int256(gMinWad)) g = int256(gMinWad);
        if (g > int256(gMaxWad)) g = int256(gMaxWad);

        uint256 adjustedBaseline = _wmul(baselineRaw, uint256(g));
        uint256 lockRefCap = _wmul(emaLock, lockRefCapWad);
        uint256 boundedPrev = prevClippedLock > lockRefCap ? lockRefCap : prevClippedLock;
        uint256 refLock = boundedPrev > 0 ? boundedPrev : clippedLock;
        lastReferenceLock = refLock;
        referenceLockByEpoch[dayNum] = refLock;
        uint256 lockTarget = _wmul(refLock, targetLockEmitWad);
        uint256 coupledCore =
            _wmul(lockTarget, lockCouplingWad) + _wmul(adjustedBaseline, WAD - lockCouplingWad);
        uint256 dripCap = _wmul(baselineRaw, gammaWad);
        uint256 drip = _min(_wmul(recycleBuffer, betaWad), dripCap);
        recycleBuffer = recycleBuffer + rToday - drip;
        return coupledCore + drip;
    }

    function _wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function _applyEmergency(uint256 dayNum, uint256 emission) internal returns (uint256) {
        if (!emergencyMode) {
            emergencyStreakDays = 0;
            return emission;
        }

        if (emergencyStreakDays >= maxEmergencyDays) {
            emergencyMode = false;
            emergencyStreakDays = 0;
            return emission;
        }

        uint256 remDays = dayNum >= EMERGENCY_HORIZON_DAYS ? 1 : (EMERGENCY_HORIZON_DAYS - dayNum);
        emergencyStreakDays += 1;
        return poolInitial / remDays;
    }

    function _ema(uint256 prev, uint256 cur, uint256 lambdaWad_) internal pure returns (uint256) {
        return _wmul(cur, lambdaWad_) + _wmul(prev, WAD - lambdaWad_);
    }

    function _emaSigned(int256 prev, int256 cur, uint256 lambdaWad_) internal pure returns (int256) {
        int256 termCur = (cur * int256(lambdaWad_)) / int256(WAD);
        int256 termPrev = (prev * int256(WAD - lambdaWad_)) / int256(WAD);
        return termCur + termPrev;
    }

    function _clip(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function _clipSigned(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
