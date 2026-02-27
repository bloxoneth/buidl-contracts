import fs from "node:fs";
import path from "node:path";

const WAD = 10n ** 18n;
const PPB_DEN = 10n ** 9n;
const EMERGENCY_HORIZON_DAYS = 1460n;

function clip(x, lo, hi) {
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}

function wmul(a, b) {
  return (a * b) / WAD;
}

function absSigned(x) {
  return x >= 0n ? x : -x;
}

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    runId: `emissions-controller-${Date.now()}`,
    outDir: path.resolve(process.cwd(), "data", "emissions-controller-runs"),
    profile: "base",
    days: 30,
    totalSupply: 1_000_000_000n * WAD,
    poolBps: 8000n,
    initialLocked: 0n,
    burnHeavyEmergency: true,
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--run-id") out.runId = args[++i];
    else if (a === "--out") out.outDir = args[++i];
    else if (a === "--profile") out.profile = args[++i];
    else if (a === "--days") out.days = Number(args[++i]);
    else if (a === "--initial-locked") out.initialLocked = BigInt(args[++i]) * WAD;
    else if (a === "--burn-heavy-emergency") out.burnHeavyEmergency = args[++i] === "1";
  }
  return out;
}

function buildParams(profile) {
  if (profile === "eth") {
    return {
      lambdaWad: 130000000000000000n,
      clipMultiplierWad: 5n * WAD,
      alphaWad: 800000000000000000n,
      kWad: 15n * WAD,
      betaWad: 15000000000000000n,
      gammaWad: 350000000000000000n,
      gMinWad: 800000000000000000n,
      gMaxWad: 1200000000000000000n,
      rhoUpWad: 150000000000000000n,
      rhoDownWad: 250000000000000000n,
      epsilon: WAD,
      dMinDays: 30n,
      minDailyPpb: 10000n,
      maxDailyPpb: 1000000n,
      maxEmergencyDays: 3n,
      activityGate: true,
      targetLockEmitWad: 920000000000000000n, // 92%
      lockCouplingWad: 995000000000000000n, // 99.5% lock-coupled, 0.5% baseline
      maxDailyPpbLocked: 120000000n, // 12% of active locked/day
      minDailyPpbLocked: 0n,
      lockRefCapWad: 1200000000000000000n, // cap reference lock at 1.2x EMA
    };
  }
  return {
    lambdaWad: 250000000000000000n,
    clipMultiplierWad: 3n * WAD,
    alphaWad: 200000000000000000n,
    kWad: 8n * WAD,
    betaWad: 5000000000000000n,
    gammaWad: 200000000000000000n,
    gMinWad: 700000000000000000n,
    gMaxWad: 1300000000000000000n,
    rhoUpWad: 200000000000000000n,
    rhoDownWad: 700000000000000000n,
    epsilon: WAD,
    dMinDays: 14n,
    minDailyPpb: 10000n,
    maxDailyPpb: 10000000n,
    maxEmergencyDays: 3n,
    activityGate: true,
    targetLockEmitWad: 950000000000000000n, // 95%
    lockCouplingWad: 995000000000000000n, // 99.5% lock-coupled, 0.5% baseline
    maxDailyPpbLocked: 100000000n, // 10% of active locked/day
    minDailyPpbLocked: 0n,
    lockRefCapWad: 1050000000000000000n, // cap reference lock at 1.05x EMA
  };
}

function dailyEvents(kind, day, days) {
  if (kind === "steady_growth") return { L: 150000n * WAD, U: 50000n * WAD, R: 2000n * WAD };
  if (kind === "contraction") return { L: 40000n * WAD, U: 120000n * WAD, R: 6000n * WAD };
  if (kind === "shock_lock")
    return day === 1
      ? { L: 4000000n * WAD, U: 10000n * WAD, R: 0n }
      : { L: 60000n * WAD, U: 30000n * WAD, R: 1000n * WAD };
  if (kind === "burn_heavy") return { L: 25000n * WAD, U: 140000n * WAD, R: 20000n * WAD };
  if (kind === "boot_from_zero")
    return day <= 3
      ? { L: 0n, U: 0n, R: 0n }
      : day <= 7
        ? { L: 30000n * WAD, U: 0n, R: 0n }
        : { L: 60000n * WAD, U: 10000n * WAD, R: 300n * WAD };
  return { L: 50000n * WAD, U: 30000n * WAD, R: 0n };
}

function simulateScenario(name, params, days, totalSupply, poolBps, initialLocked, burnHeavyEmergency) {
  const poolInitial = (totalSupply * poolBps) / 10000n;
  let poolRemaining = poolInitial;
  let recycleBuffer = 0n;
  let prevEmission = 0n;
  let emaAbs = 0n;
  let emaDelta = 0n;
  let emaLock = 0n;
  let prevClippedLock = 0n;
  let prevActualLock = 0n;
  let tPrev = initialLocked;
  let emergencyMode = false;
  let emergencyStreak = 0n;

  const rows = [];

  for (let d = 1; d <= days; d++) {
    if (
      burnHeavyEmergency
      && name === "burn_heavy"
      && d >= Math.floor(days / 2)
      && d < Math.floor(days / 2) + 2
    ) {
      emergencyMode = true;
    } else {
      emergencyMode = false;
    }
    if (!emergencyMode) emergencyStreak = 0n;

    const ev = dailyEvents(name, d, days);
    const delta = ev.L - ev.U;
    const absLock = ev.L;
    emaLock = wmul(absLock, params.lambdaWad) + wmul(emaLock, WAD - params.lambdaWad);
    const lockClipBound = wmul(emaLock, params.clipMultiplierWad);
    const clippedLock = clip(ev.L, 0n, lockClipBound);

    const absDelta = absSigned(delta);
    emaAbs = wmul(absDelta, params.lambdaWad) + wmul(emaAbs, WAD - params.lambdaWad);

    const clipBound = wmul(emaAbs, params.clipMultiplierWad);
    let clippedDelta = delta;
    if (clippedDelta > clipBound) clippedDelta = clipBound;
    if (clippedDelta < -clipBound) clippedDelta = -clipBound;

    emaDelta =
      (clippedDelta * params.lambdaWad) / WAD + (emaDelta * (WAD - params.lambdaWad)) / WAD;

    const dayNum = BigInt(d);
    const divisor = dayNum > params.dMinDays ? dayNum : params.dMinDays;
    const baseline = (tPrev * params.alphaWad) / (WAD * divisor);

    const ratio = (emaDelta * WAD) / (tPrev + params.epsilon);
    const growthAdj = (params.kWad * ratio) / WAD;
    let g = WAD + growthAdj;
    if (g < params.gMinWad) g = params.gMinWad;
    if (g > params.gMaxWad) g = params.gMaxWad;

    const adjustedBaseline = wmul(baseline, g);
    const refCap = wmul(emaLock, params.lockRefCapWad);
    const boundedPrevLock = prevClippedLock > refCap ? refCap : prevClippedLock;
    const refLockForEmission = boundedPrevLock > 0n ? boundedPrevLock : clippedLock;
    const lockTarget = wmul(refLockForEmission, params.targetLockEmitWad);
    const coupledCore =
      wmul(lockTarget, params.lockCouplingWad)
      + wmul(adjustedBaseline, WAD - params.lockCouplingWad);
    const drip = clip(
      wmul(recycleBuffer, params.betaWad),
      0n,
      wmul(baseline, params.gammaWad),
    );
    recycleBuffer = recycleBuffer + ev.R - drip;

    let emission = coupledCore + drip;

    if (params.activityGate && tPrev === 0n && recycleBuffer === 0n) {
      emission = 0n;
    }

    const eMinSupply = (totalSupply * params.minDailyPpb) / PPB_DEN;
    const eMaxSupply = (totalSupply * params.maxDailyPpb) / PPB_DEN;
    const eMinLocked = (tPrev * params.minDailyPpbLocked) / PPB_DEN;
    const eMaxLocked = (tPrev * params.maxDailyPpbLocked) / PPB_DEN;
    const eMin = eMinSupply > eMinLocked ? eMinSupply : eMinLocked;
    const eMax = eMaxSupply < eMaxLocked ? eMaxSupply : eMaxLocked;
    emission = clip(emission, eMin, eMax);

    if (prevEmission > 0n) {
      const down = wmul(prevEmission, WAD - params.rhoDownWad);
      const up = wmul(prevEmission, WAD + params.rhoUpWad);
      emission = clip(emission, down, up);
    }

    if (emergencyMode && emergencyStreak < params.maxEmergencyDays) {
      const rem = EMERGENCY_HORIZON_DAYS > dayNum ? EMERGENCY_HORIZON_DAYS - dayNum : 1n;
      emission = clip(poolInitial / rem, 0n, poolRemaining);
      emergencyStreak += 1n;
    }

    if (emission > poolRemaining) emission = poolRemaining;
    poolRemaining -= emission;
    prevEmission = emission;
    prevClippedLock = clippedLock;

    if (delta >= 0n) tPrev += delta;
    else tPrev = tPrev > -delta ? tPrev + delta : 0n;

    const emissionToPrevLock =
      refLockForEmission > 0n ? Number((emission * 10000n) / refLockForEmission) / 100 : null;
    const emissionToPrevActualLock =
      prevActualLock > 0n ? Number((emission * 10000n) / prevActualLock) / 100 : null;
    prevActualLock = ev.L;

    rows.push({
      day: d,
      locked: Number(ev.L / WAD),
      unlocked: Number(ev.U / WAD),
      recycled: Number(ev.R / WAD),
      totalLocked: Number(tPrev / WAD),
      emission: Number(emission / WAD),
      buffer: Number(recycleBuffer / WAD),
      growthFactor: Number(g) / 1e18,
      lockTarget: Number(lockTarget / WAD),
      emissionToPrevLockPct: emissionToPrevLock,
      emissionToPrevActualLockPct: emissionToPrevActualLock,
      emergency: emergencyMode,
    });
  }

  const totalEmitted = rows.reduce((s, r) => s + r.emission, 0);
  const ratioRows = rows.filter((r) => r.emissionToPrevLockPct !== null);
  const ratioActualRows = rows.filter((r) => r.emissionToPrevActualLockPct !== null);
  const avgEmissionToPrevLockPct = ratioRows.length
    ? ratioRows.reduce((s, r) => s + r.emissionToPrevLockPct, 0) / ratioRows.length
    : null;
  const avgEmissionToPrevActualLockPct = ratioActualRows.length
    ? ratioActualRows.reduce((s, r) => s + r.emissionToPrevActualLockPct, 0) / ratioActualRows.length
    : null;
  return {
    name,
    days,
    totalEmitted,
    endingLocked: Number(tPrev / WAD),
    endingPool: Number(poolRemaining / WAD),
    avgEmission: rows.length ? totalEmitted / rows.length : 0,
    avgEmissionToPrevLockPct,
    avgEmissionToPrevActualLockPct,
    rows,
  };
}

function main() {
  const opts = parseArgs();
  const params = buildParams(opts.profile);
  const runDir = path.join(opts.outDir, opts.runId);
  fs.mkdirSync(runDir, { recursive: true });

  const scenarios = [
    "steady_growth",
    "contraction",
    "shock_lock",
    "burn_heavy",
    "boot_from_zero",
  ];
  const out = scenarios.map((s) =>
    simulateScenario(
      s,
      params,
      opts.days,
      opts.totalSupply,
      opts.poolBps,
      opts.initialLocked,
      opts.burnHeavyEmergency,
    ),
  );

  const safeOpts = {
    ...opts,
    totalSupply: opts.totalSupply.toString(),
    poolBps: opts.poolBps.toString(),
    initialLocked: opts.initialLocked.toString(),
  };
  const safeParams = Object.fromEntries(
    Object.entries(params).map(([k, v]) => [k, typeof v === "bigint" ? v.toString() : v]),
  );
  fs.writeFileSync(
    path.join(runDir, "summary.json"),
    JSON.stringify({ opts: safeOpts, params: safeParams, out }, null, 2),
  );
  for (const s of out) {
    const header =
      "day,locked,unlocked,recycled,totalLocked,lockTarget,emission,emissionToPrevLockPct,emissionToPrevActualLockPct,buffer,growthFactor,emergency";
    const lines = [
      header,
      ...s.rows.map(
        (r) =>
          `${r.day},${r.locked},${r.unlocked},${r.recycled},${r.totalLocked},${r.lockTarget},${r.emission},${r.emissionToPrevLockPct ?? ""},${r.emissionToPrevActualLockPct ?? ""},${r.buffer},${r.growthFactor.toFixed(6)},${r.emergency ? 1 : 0}`,
      ),
    ];
    fs.writeFileSync(path.join(runDir, `${s.name}.csv`), `${lines.join("\n")}\n`);
  }

  // concise terminal report
  // eslint-disable-next-line no-console
  console.log(`Run: ${runDir}`);
  for (const s of out) {
    // eslint-disable-next-line no-console
    console.log(
      `${s.name}: emitted=${s.totalEmitted.toFixed(2)} BLOX, avg/day=${s.avgEmission.toFixed(2)}, avg(E/refLock)=${s.avgEmissionToPrevLockPct?.toFixed(2) ?? "n/a"}%, avg(E/prevActualLock)=${s.avgEmissionToPrevActualLockPct?.toFixed(2) ?? "n/a"}%, endingLocked=${s.endingLocked.toFixed(2)}, endingPool=${s.endingPool.toFixed(2)}`,
    );
  }
}

main();
