// ── Fixed-point money boundary (integer-money migration) ───────────────
// The backend ledger is exact integers at a uniform 10^8 (e8s / ICRC) scale:
// Candid `Nat`/`Int` money decodes to a JS `bigint` in BASE UNITS. The UI
// renders/computes in HUMAN UNITS (plain `Number`), so we convert at the
// actor boundary — once per fetch — and leave every downstream render/format
// site untouched. The demo/mock actor already emits human Numbers, so a wrapped
// real actor and the mock stay representation-consistent.
//
// Why a boundary normalizer and not ÷1e8 at 360 call sites: money arrives in
// heterogeneous shapes (named record fields, bare scalars, (token,amount)
// tuples) and same-typed non-money bigints (timestamps in ns, ids, counts, bps)
// must NOT be scaled. `normMoney` scales only `bigint` leaves whose KEY is a
// known money field — and because the deliberate Float islands (oracle
// price/stddev, AMM volRegime, counterparty rates) decode to `Number` not
// `bigint`, the `typeof === "bigint"` guard skips them for free, even where they
// share a name with money (e.g. `price` is money on Order, a Float island on
// Aggregate).

export const E8 = 100_000_000;

// bigint base-units (or already a Number) → human-unit Number.
export function fromE8(x) {
  return typeof x === "bigint" ? Number(x) / E8 : Number(x);
}

// human-unit value → bigint base-units, for args sent to the backend. Round to
// the nearest base unit (sub-unit input is operator/UI noise, not ledger money).
//
// The whole-unit part is scaled in BigInt, NOT by `v * 1e8` in floating point.
// 1e8 is not a power of two, so the product carries its own rounding error on
// top of whatever `v` already carried, and past ~2^51 base units the two
// together exceed half a base unit: `Math.round(fromE8(3355443200000019n) *
// 1e8)` lands on …020. Splitting keeps every whole unit exact and confines
// float arithmetic to the sub-unit tail, where 1e8 * (fraction < 1) has ~11
// orders of magnitude of headroom before it could round wrong.
//
// That makes the round trip exact up to 2^52 base units (~45M tokens), which
// is the ceiling for ANY round trip that passes through a human-unit Number:
// beyond it one ulp is wider than one base unit, so adjacent base units share
// a double and no inverse exists. Anything needing exactness above that has to
// keep the bigint.
export function toE8(v) {
  const n = Number(v);
  const whole = Math.trunc(n);
  return BigInt(whole) * BigInt(E8) + BigInt(Math.round((n - whole) * E8));
}

// Field names that were `Float` money/ratio and are now integer base-units
// (@1e8). Derived mechanically from the pre-migration IDL diff (every
// `field: IDL.Float64` that became Nat/Int), minus the Float islands that stay
// Float64 (volRegime/stddevBps/maxStddevBps/adverseRate/totalFillValue/
// jumpThresholdBps/float) and minus the over-generic `ok` (handled per-method).
// Ratio/percent/multiplier fields (ltv, healthRatio, factor, *Weight, *Usage,
// pctToLiquidation, depositMultiplier) were Float and are Nat@1e8 too, so ÷1e8
// recovers the fraction the render code already expects.
export const MONEY_KEYS = new Set([
  "ammAskQty", "ammAskValue", "ammBidQty", "ammBidValue", "amount", "amountUsd",
  "avgEntry", "avgExit", "avgPrice", "balance", "baseAmount", "baseHeld",
  "balanceUsd", "lifetimeFeesUsd", "lifetimeVaultFeesUsd",
  "lifetimeImportUsd", "lifetimeExportUsd", "hourUsedUsd", "hourCapUsd", "perCallCapUsd",
  "bookAskQty", "bookAskValue", "bookBidQty", "bookBidValue", "btc", "bufferUsd",
  "capitalUsd", "cashBalance", "close", "collateralSeized", "collateralUsd",
  "collateralValueUsd", "contribUsd", "currentWeight", "debtRepaid",
  "debtRepaidUsd", "debtUsd", "depositMultiplier", "entryPrice", "equityUsd",
  "estimatedValue", "eth", "factor", "filled", "freeQuote", "freeWalletValueUsd",
  "fromAmount", "grossBidValue", "headroom", "healthAfter", "healthBefore",
  "healthRatio", "high", "icp", "icpusd", "inventoryTargetBase", "lastPrice",
  "lastVolSamplePrice", "limitPrice", "low", "lpAmount", "lpBalance", "lpBurned", "lpMinted", "minted",
  "lpSupply", "ltv", "maintenanceRatio", "makerDebitAmount", "marginUsage",
  "markPrice", "maxAllowed", "maxSlippage", "netAccountValueUsd", "newQuantity",
  "notionalUsd", "oldQuantity", "open", "originalQuantity", "payoutUsd",
  "pctToLiquidation", "penaltyUsd", "poolQuoteValue", "poolValue", "price",
  "priceChange24hAbs", "proceedsUsd", "profitUsd", "qty", "quantity", "quoteAmount",
  "quoteDepthBase", "quoteHeld", "realizedPnl", "refPrice", "remainingQty",
  "sharePercent", "shareValueUsd", "shares", "size", "sol", "spread",
  "takerDebitAmount", "targetWeight", "toAmount", "totalBalance", "totalFilled",
  "totalLPSupply", "totalQuoteValue", "totalShares", "uncoveredBadDebtUsd",
  "unrealizedPnl", "valuePerLP", "valueUsd", "volume", "volume24h",
  "wholeWalletDebtUsd", "worstMarginUsage",
  // Margin heat map + LP risk panel (getMarginHeatmap / getMarginRiskSummary).
  // These MUST be listed: normMoney recurses, so listing them also normalises
  // the nested bucket records, and the renderers then never divide by 1e8
  // themselves. markPrice was ALREADY in this set — mixing one normalised field
  // with hand-divided siblings is exactly how a figure lands 1e8 out (the mark
  // rendered as "$0.00063787" instead of "$63,787" before this).
  // NOT money, deliberately absent: bandLowBps / bandHighBps and
  // vaultUtilisationBps (bps), and positions / positionsTotal /
  // liquidatablePositions (counts).
  "longNotionalUsd", "shortNotionalUsd", "totalLongNotionalUsd", "totalShortNotionalUsd",
  "totalNotionalUsd", "totalDebtUsd", "vaultValueUsd", "vaultBorrowCapUsd",
  "insuranceValueUsd", "liquidatableNotionalUsd", "worstCaseAbsorbUsd",
  // Markets-page telemetry bar (getMarketTele). computedNs is a timestamp
  // and deliberately absent. long/shortNotionalUsd are covered above; the
  // opt-wrapped long/shortHealth stay raw e8 (normMoney keys only direct
  // record fields, not opt array elements) — the renderer divides.
  "totalDepthUsd", "high24h", "low24h",
  // getInsuranceFund returns FIVE e8 fields and every one has to be listed.
  // The other four — bufferUsd, uncoveredBadDebtUsd, totalShares,
  // shareValueUsd — are in the alphabetical block above, and all five are
  // rendered side by side (Earn card, Stats insurance KPIs, Stats issues,
  // vault P&L footer). An omission here does not read as a units bug in the
  // UI: it reads as a fifty-cent liability reported as fifty million dollars,
  // and it clears every `> 0` gate that decides whether to show the figure
  // at all.
  "pendingYieldUsd",
  // getMaxInstantWithdraw (task 1788465539): the LP's instant-liquidity quote.
  // exitFeeBps is bps and deliberately absent; lentOutFraction is a 0..1
  // fraction at e8 (like sharePercent — the render owns the ×100).
  "withdrawableNowUsd", "withdrawableNowLp", "totalNavUsd", "lentOutFraction",
  "vaultHoldingsUsd", "vaultLentOutUsd", "vaultNavUsd",
  // Locked shares (task 1788475756): the caller's locked LP, the vault-wide
  // total, and the NAV the locked shares carry.
  "lockedLp", "vaultLockedLp", "vaultLockedNavUsd",
  // The impairment reserve (task 1788475754): the vault-level expected-loss
  // deduction inside NAV and the caller's share of it; getVaultImpairment's
  // figure set (stressBps / maintenanceRatio are not money and stay raw).
  "vaultImpairmentReserveUsd", "provisionedLossUsd",
  "reserveUsd", "grossExpectedLossUsd", "insuranceFirstLossUsd", "loanBookUsd",
  "impairedDebtUsd", "impairedCollateralUsd",
  "impairmentReserveUsd", "impairmentGrossUsd",
]);

// Recursively scale money bigints (by key) to human Numbers, in place. Recurses
// plain objects/arrays only — Principal/Blob/typed-array values are left alone
// (constructor !== Object), and non-money or non-bigint leaves pass through.
export function normMoney(x) {
  if (Array.isArray(x)) {
    for (let i = 0; i < x.length; i++) x[i] = normMoney(x[i]);
    return x;
  }
  if (x && typeof x === "object") {
    if (x.constructor && x.constructor !== Object) return x; // Principal, Uint8Array…
    for (const k in x) {
      const v = x[k];
      if (typeof v === "bigint") {
        if (MONEY_KEYS.has(k)) x[k] = Number(v) / E8;
      } else if (v && typeof v === "object") {
        x[k] = normMoney(v);
      }
    }
    return x;
  }
  return x;
}

// Methods whose result the field-keyed walker can't reach because the money is
// unnamed (bare scalar return) or tuple-positional, plus the two mutations
// that return `#ok(money)`. depositLp is NOT one of them since apiVersion
// 6.0.0 (task 1788731608): the sealed door returns `#ok(StagedLpRequest)` — a
// record normMoney walks (its baseAmount / quoteAmount legs scale, its id / ts
// / expiresAt stay bigint). Listed here, the record went through fromE8 and
// came back NaN, so the Earn card read `Number(r.ok.id)` as NaN and polled
// twelve rounds for a request that could never match (task 1793558036).
const BARE_MONEY = new Set([
  "getBalance", "getMyAvailableBalance", "getMyLpBalance", "getMyReservedBalance",
  "getMyVaultLp", "getNettedVolumeUsd", "getTestBalance",
]); // -> (nat) money. NB: purgeZombieOrders/bulkSetTestBalances/seedInsuranceFund return COUNTS — excluded.
const TUPLE_BALANCES = new Set(["getBalances"]); // -> vec record { TokenId; nat }
const OK_MONEY = new Set(["stakeInsurance", "unstakeInsurance"]); // -> variant { ok: nat; err }

// Wrap a real (non-mock) actor so every call's result is money-normalized to
// human Numbers. Reads flow through unchanged for the UI; the mock actor is
// NOT wrapped (it already emits human Numbers).
export function wrapActor(raw) {
  return new Proxy(raw, {
    get(target, prop) {
      const orig = target[prop];
      if (typeof orig !== "function") return orig;
      return async (...args) => {
        const r = await orig.apply(target, args);
        if (BARE_MONEY.has(prop)) return fromE8(r);
        if (TUPLE_BALANCES.has(prop)) return r.map(([tok, amt]) => [tok, fromE8(amt)]);
        if (OK_MONEY.has(prop) && r && typeof r === "object" && "ok" in r) {
          return { ok: fromE8(r.ok) };
        }
        return normMoney(r);
      };
    },
  });
}
