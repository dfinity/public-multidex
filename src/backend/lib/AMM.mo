import Map "mo:core/Map";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Float "mo:core/Float";
import Nat "mo:core/Nat";
import Types "Types";
import Fixed "Fixed";

// AMM.mo — per-market automated market maker.
//
// Money representation (see lib/Fixed.mo): the LP LEDGER and prices are exact
// integers at 10^8 — reserves, refPrice, totalLPSupply, quote-token value, LP
// mint/burn, quoted prices/sizes. The market-making HEURISTICS that only SHAPE
// quotes — volatility regime (log-returns), inventory skew/floor/depth
// multipliers — remain Float: they read the Nat state via Fixed.toFloat and
// their outputs are quantized back to Nat (a quote price/size, a bps lean)
// before they touch the ledger. Quotes settle exactly via the integer matching
// engine regardless, so a sub-unit difference in a heuristic multiplier can
// never create or destroy value — the same boundary PriceFeed sits behind.
//
// Architecture:
//   Each market can have at most one Pool. The Pool's reserves live as regular
//   balances in Accounts under a dedicated AMM principal. Quotes are posted as
//   PROTECTED limit orders. LP tokens and inventory/skew logic live on top.

module {

  // ── Pool state ────────────────────────────────────────────────────
  public type Pool = {
    marketId  : Types.MarketId;
    baseToken : Types.TokenId;

    // Config (set by admin, rarely changes)
    spreadBps           : Nat;   // half-spread in bps (e.g. 20 = 0.20%)
    quoteDepthBase      : Nat;   // base-token quantity per level (10^8)
    numLevels           : Nat;   // levels per side (e.g. 3)
    levelSpacingBps     : Nat;   // spacing between adjacent levels (bps)
    protectionWindowSec : Nat;   // settlement window applied to every AMM quote
    enabled             : Bool;

    // Inventory target & skew parameters (used in Phase 4).
    inventoryTargetBase : Nat;   // nominal base-token holding target (10^8)
    skewIntensityBps    : Nat;   // how hard to lean quotes when off-target

    // Live state
    refPrice            : Nat;   // quote-per-base price (10^8)
    refPriceUpdatedNs   : Int;
    activeBidIds        : [Nat];
    activeAskIds        : [Nat];
    lastRequoteNs       : Int;

    // LP accounting (Phase 3)
    totalLPSupply       : Nat;   // LP tokens (10^8)

    // Volatility tracking (Phase 4) — HEURISTIC, stays Float.
    volRegime           : Float; // rolling stdev of log-returns in bps
    lastVolSamplePrice  : Nat;   // price sample (10^8)
    lastVolSampleNs     : Int;

    // Rebalance cooldown (Phase 5)
    lastRebalanceNs     : Int;
  };

  public func emptyPool(marketId : Types.MarketId, baseToken : Types.TokenId) : Pool = {
    marketId;
    baseToken;
    spreadBps           = 20;
    quoteDepthBase      = 5_000_000;   // 0.05 base
    numLevels           = 3;
    levelSpacingBps     = 15;
    protectionWindowSec = 8;
    enabled             = false;
    inventoryTargetBase = 0;
    skewIntensityBps    = 0;
    refPrice            = 0;
    refPriceUpdatedNs   = 0;
    activeBidIds        = [];
    activeAskIds        = [];
    lastRequoteNs       = 0;
    totalLPSupply       = 0;
    volRegime           = 0.0;
    lastVolSamplePrice  = 0;
    lastVolSampleNs     = 0;
    lastRebalanceNs     = 0;
  };

  // ── Numeric helpers ───────────────────────────────────────────────

  public func bpsToFraction(bps : Nat) : Float {
    Float.fromInt(bps) / 10000.0;
  };

  // Signed skew (bps) → multiplicative factor.
  public func skewBpsToFactor(bps : Int) : Float {
    Float.fromInt(bps) / 10000.0;
  };

  // Compute inventory skew in bps based on how far the pool's base reserves
  // deviate from the configured target. Long-base → NEGATIVE skew. Short-base
  // → POSITIVE skew. Returns 0 if disabled. Deviation clamped to ±1.0.
  // (Heuristic — Float math, Nat in / Int bps out.)
  //
  // The caller applies this ONE-SIDED (see ammRequote): a negative lean lowers
  // the BID ladder only (long → back away from buying more; asks stay pinned
  // at ref + half, the most competitive sell allowed); a positive lean raises
  // the ASK ladder only (short → scarcity premium; bids stay pinned at
  // ref − half, refilling below the mark). Never feed the same signed lean to
  // both sides: buildQuoteLadder clamps mids to the reference price, so the
  // cross-mid half of a symmetric lean is discarded by design.
  public func computeInventorySkewBps(pool : Pool, baseHeld : Nat) : Int {
    if (pool.skewIntensityBps == 0 or pool.inventoryTargetBase == 0) { return 0 };
    let target = Fixed.toFloat(pool.inventoryTargetBase);
    let deviation = (Fixed.toFloat(baseHeld) - target) / target;
    let clamped = Float.max(-1.0, Float.min(1.0, deviation));
    // Negate so long-base → negative skew → ladder drops → tighter asks.
    let bps = -clamped * Float.fromInt(pool.skewIntensityBps);
    Float.toInt(bps);
  };

  // ── Inventory floor & floor-barrier skew (#92) ────────────────────
  let FLOOR_FRACTION : Float = 0.15;          // reserve = 15% of inventoryTargetBase
  let FLOOR_FRACTION_E8 : Nat = 15_000_000;   // 0.15 at 10^8 (for the Nat floor)
  let FLOOR_SKEW_MAX_BPS : Float = 50_000.0;  // cap the barrier at +500%

  // The base-token reserve the AMM will not sell below (a base QUANTITY → Nat).
  public func inventoryFloor(pool : Pool) : Nat {
    if (pool.inventoryTargetBase == 0) { 0 } else { Fixed.mul(pool.inventoryTargetBase, FLOOR_FRACTION_E8, false) };
  };

  // Ask-ONLY upward skew (bps, ≥ 0) growing hyperbolically as base holdings fall
  // from target toward the floor. (Heuristic — Float math, Nat in / Int bps out.)
  public func computeFloorBarrierBps(pool : Pool, baseHeld : Nat) : Int {
    if (pool.skewIntensityBps == 0 or pool.inventoryTargetBase == 0) { return 0 };
    let target = Fixed.toFloat(pool.inventoryTargetBase);
    let heldF = Fixed.toFloat(baseHeld);
    if (heldF >= target) { return 0 };                  // only the short side gets the barrier
    let floor = FLOOR_FRACTION * target;
    let x = (heldF - floor) / (target - floor);          // 1.0 at target → 0.0 at floor
    let barrier = if (x <= 0.0) { FLOOR_SKEW_MAX_BPS }
                  else { Float.min(FLOOR_SKEW_MAX_BPS, Float.fromInt(pool.skewIntensityBps) * (1.0 / x - 1.0)) };
    Float.toInt(barrier);
  };

  // ── Inventory-aware quote DEPTH ────────────────────────────────────
  // Scales depth on the side that REDUCES the imbalance. Returns (bidMul,
  // askMul), each ≥ 1.0. (Heuristic — Float multipliers, applied by the caller.)
  let DEPTH_INVENTORY_K   : Float = 3.0;  // +3× base depth per 100% of imbalance
  let DEPTH_INVENTORY_MAX : Float = 4.0;  // cap at 4× base depth
  public func computeInventoryDepthMul(pool : Pool, baseHeld : Nat) : (Float, Float) {
    if (pool.skewIntensityBps == 0 or pool.inventoryTargetBase == 0) { return (1.0, 1.0) };
    let target = Fixed.toFloat(pool.inventoryTargetBase);
    let deviation = (Fixed.toFloat(baseHeld) - target) / target;
    let surplus = Float.max(0.0, deviation);   // overweight → bigger asks
    let deficit = Float.max(0.0, -deviation);  // underweight → bigger bids
    let askMul = Float.min(DEPTH_INVENTORY_MAX, 1.0 + DEPTH_INVENTORY_K * surplus);
    let bidMul = Float.min(DEPTH_INVENTORY_MAX, 1.0 + DEPTH_INVENTORY_K * deficit);
    (bidMul, askMul);
  };

  // ── Quote ladder computation ──────────────────────────────────────
  // Builds (price, qty) pairs around refPrice — each price quantized to Nat
  // (10^8). The curve math runs in Float (reading the Nat refPrice via toFloat)
  // because a sub-unit difference in a quoted price is harmless — the quote
  // settles exactly at its Nat price via the matching engine.
  public type QuoteLadder = {
    bids : [(Nat, Nat)]; // (price, quantity), tightest first
    asks : [(Nat, Nat)];
  };

  public func buildQuoteLadder(pool : Pool, bidSkewBps : Int, askSkewBps : Int) : QuoteLadder {
    if (pool.refPrice == 0 or pool.numLevels == 0) {
      return { bids = []; asks = [] };
    };
    let refF = Fixed.toFloat(pool.refPrice);
    // INVARIANT (LP-capital protection): no skew input may push a ladder mid
    // across the reference price — bidMid ≤ ref ≤ askMid, so with any positive
    // half-spread every bid < ref < every ask. The AMM can therefore never buy
    // above or sell below its own mark: a round trip through its quotes always
    // pays the vault ≥ the full spread, whatever the inventory state. (The old
    // symmetric lean shifted BOTH mids and crossed ref once |lean| exceeded the
    // half-spread — an adversary could drain one side, then trade the refill
    // against quotes parked on the wrong side of fair.) Inventory pressure must
    // arrive as a one-sided premium: bidSkewBps ≤ 0 ≤ askSkewBps. The clamp
    // holds even if a caller passes something else.
    let bidMid = Float.min(refF, refF * (1.0 + skewBpsToFactor(bidSkewBps)));
    let askMid = Float.max(refF, refF * (1.0 + skewBpsToFactor(askSkewBps)));
    // Widen half-spread when vol is elevated: base half-spread + 0.5 * stdev(bps).
    let volWideningBps = pool.volRegime * 0.5;
    let halfBps = Float.fromInt(pool.spreadBps) + volWideningBps;
    // W4-23 (R12 retargeted): bound the COMBINED half-spread. Every widening
    // term feeds this line (vol regime, staleness, breaker — the
    // caller folds the last two in ×2 via withVol), and one unbounded term
    // was reachable: an UNCONFIRMED breaker pend proposing >2× ref put
    // breakerBps past 9,980, drove half ≥ 1.0, zeroed the whole bid ladder —
    // and ammApplyQuotes' off-ladder sweep then CANCELLED every resting bid,
    // silently. A 50% half-spread already quotes nothing tradeable; beyond
    // it, extra width only withdraws liquidity. Clamping HERE bounds all
    // four contributors at once (clamping volRegime alone leaves breakerBps
    // open — R12 aimed at the wrong term).
    let half = Float.min(0.5, halfBps / 10000.0);
    let spacing = bpsToFraction(pool.levelSpacingBps);
    let depth = pool.quoteDepthBase;

    let bids = Array.tabulate<(Nat, Nat)>(pool.numLevels, func(i) {
      let offset = Float.fromInt(i);
      let p = bidMid * (1.0 - half - spacing * offset);
      (Fixed.fromFloat(p), depth);   // fromFloat clamps p ≤ 0 → 0
    });
    let asks = Array.tabulate<(Nat, Nat)>(pool.numLevels, func(i) {
      let offset = Float.fromInt(i);
      let p = askMid * (1.0 + half + spacing * offset);
      (Fixed.fromFloat(p), depth);
    });
    { bids; asks };
  };

  // ── Pool map helpers ──────────────────────────────────────────────

  public type PoolMap = Map.Map<Types.MarketId, Pool>;

  public func getPool(pools : PoolMap, marketId : Types.MarketId) : ?Pool {
    Map.get(pools, Text.compare, marketId);
  };

  public func putPool(pools : PoolMap, pool : Pool) {
    Map.add(pools, Text.compare, pool.marketId, pool);
  };

  public func allPools(pools : PoolMap) : [Pool] {
    var xs : [Pool] = [];
    for ((_, p) in Map.entries(pools)) {
      let n = xs.size();
      xs := Array.tabulate<Pool>(n + 1, func(i) {
        if (i < n) { xs[i] } else { p }
      });
    };
    xs;
  };

  // ── LP token math (Phase 3) ── exact integer ledger ───────────────

  public func quoteDenomValue(pool : Pool, baseAmount : Nat, quoteAmount : Nat) : Nat {
    Fixed.mul(baseAmount, pool.refPrice, false) + quoteAmount;
  };

  public func poolQuoteValue(pool : Pool, baseHeld : Nat, quoteHeld : Nat) : Nat {
    Fixed.mul(baseHeld, pool.refPrice, false) + quoteHeld;
  };

  // (lpToMint, newTotalSupply). Mint rounds DOWN — depositor gets no more than
  // their fair share (protects existing LPs).
  public func computeLPMint(
    pool : Pool,
    baseHeldBefore : Nat,
    quoteHeldBefore : Nat,
    baseAdd : Nat,
    quoteAdd : Nat,
  ) : (Nat, Nat) {
    let addValue = quoteDenomValue(pool, baseAdd, quoteAdd);
    if (addValue == 0) { return (0, pool.totalLPSupply) };
    if (pool.totalLPSupply == 0 or (baseHeldBefore + quoteHeldBefore) == 0) {
      return (addValue, addValue);
    };
    // Value the existing pool slightly HIGH (base leg rounded UP) — as the mint
    // DENOMINATOR, a larger poolValueBefore can only shrink `minted`, so the
    // depositor provably never receives MORE than their fair share (the addValue
    // numerator is floored DOWN for the same reason). poolQuoteValue itself stays
    // DOWN for display/valuation; only this denominator use rounds up.
    let poolValueBefore = Fixed.mul(baseHeldBefore, pool.refPrice, true) + quoteHeldBefore;
    let minted = if (poolValueBefore == 0) { addValue } else {
      Fixed.mulDiv(addValue, pool.totalLPSupply, poolValueBefore, false)
    };
    (minted, pool.totalLPSupply + minted);
  };

  // (baseOut, quoteOut, newTotalSupply). Withdrawals round DOWN — never more
  // than the burned share (protects remaining LPs).
  public func computeLPBurn(
    pool : Pool,
    baseHeld : Nat,
    quoteHeld : Nat,
    lpAmount : Nat,
  ) : (Nat, Nat, Nat) {
    if (pool.totalLPSupply == 0 or lpAmount == 0) {
      return (0, 0, pool.totalLPSupply);
    };
    let burn = Nat.min(lpAmount, pool.totalLPSupply);   // share ≤ 1.0
    let baseOut  = Fixed.mulDiv(baseHeld, burn, pool.totalLPSupply, false);
    let quoteOut = Fixed.mulDiv(quoteHeld, burn, pool.totalLPSupply, false);
    (baseOut, quoteOut, pool.totalLPSupply - burn);
  };

  // ── Volatility tracking (Phase 4) ── HEURISTIC (Float) ────────────
  // EWMA variance of log-returns; stores stdev in bps in pool.volRegime.
  public func updateVolatility(pool : Pool, newMid : Nat, now : Int) : Pool {
    if (newMid == 0) return pool;
    if (pool.lastVolSamplePrice == 0) {
      return withVol(pool, pool.volRegime, newMid, now);
    };
    let r = Float.log(Fixed.toFloat(newMid) / Fixed.toFloat(pool.lastVolSamplePrice));
    let alpha = 0.1;
    let oldVar = (pool.volRegime / 10000.0) * (pool.volRegime / 10000.0);
    let newVar = (1.0 - alpha) * oldVar + alpha * r * r;
    // W4-23: clamp the STABLE field too — 2× the ladder's half-clamp
    // threshold, so an absurd regime cannot persist across an upgrade or sit
    // undecayed on a disabled pool (requote early-returns there).
    let newStdBps = Float.min(20_000.0, Float.sqrt(newVar) * 10000.0);
    withVol(pool, newStdBps, newMid, now);
  };

  // ── Functional pool-field updaters ────────────────────────────────

  public func withConfig(
    pool : Pool,
    spreadBps : Nat,
    quoteDepthBase : Nat,
    numLevels : Nat,
    levelSpacingBps : Nat,
    protectionWindowSec : Nat,
  ) : Pool = {
    pool with
    spreadBps;
    quoteDepthBase;
    numLevels;
    levelSpacingBps;
    protectionWindowSec;
  };

  public func withEnabled(pool : Pool, enabled : Bool) : Pool = {
    pool with enabled
  };

  public func withRefPrice(pool : Pool, price : Nat, now : Int) : Pool = {
    pool with
    refPrice          = price;
    refPriceUpdatedNs = now;
  };

  public func withActiveOrders(pool : Pool, bidIds : [Nat], askIds : [Nat], now : Int) : Pool = {
    pool with
    activeBidIds  = bidIds;
    activeAskIds  = askIds;
    lastRequoteNs = now;
  };

  public func withLPSupply(pool : Pool, totalLPSupply : Nat) : Pool = {
    pool with totalLPSupply
  };

  public func withSkewConfig(
    pool : Pool,
    inventoryTargetBase : Nat,
    skewIntensityBps : Nat,
  ) : Pool = {
    pool with
    inventoryTargetBase;
    skewIntensityBps;
  };

  public func withRebalance(pool : Pool, now : Int) : Pool = {
    pool with lastRebalanceNs = now
  };

  // ── Phase 5: rebalance decision ── HEURISTIC sizing, Nat qty out ──
  public type RebalanceDecision = {
    side     : Types.Side;
    quantity : Nat;
  };

  public func decideRebalance(
    pool            : Pool,
    baseHeld        : Nat,
    now             : Int,
    thresholdPct    : Float,   // e.g. 0.25
    fractionPerTick : Float,   // e.g. 0.10
    cooldownNs      : Int,     // e.g. 60 * 1e9
    maxQtyPerTick   : Nat,     // e.g. 0.2 base
  ) : ?RebalanceDecision {
    if (pool.inventoryTargetBase == 0) { return null };
    if (now - pool.lastRebalanceNs < cooldownNs) { return null };
    let targetF = Fixed.toFloat(pool.inventoryTargetBase);
    let gap = Fixed.toFloat(baseHeld) - targetF;
    let absGap = Float.abs(gap);
    if (absGap < targetF * thresholdPct) { return null };
    let rawQty = absGap * fractionPerTick;
    let cappedQty = Float.min(rawQty, Fixed.toFloat(maxQtyPerTick));
    // Dust filter scales per-asset off inventoryTargetBase.
    let dust = targetF * 0.001;
    if (cappedQty < dust) { return null };
    let side : Types.Side = if (gap > 0.0) { #sell } else { #buy };
    ?{ side; quantity = Fixed.fromFloat(cappedQty) };
  };

  public func withVol(pool : Pool, volRegime : Float, lastVolSamplePrice : Nat, lastVolSampleNs : Int) : Pool = {
    pool with
    volRegime;
    lastVolSamplePrice;
    lastVolSampleNs;
  };

};
