// Pure-function unit tests for src/backend/lib/AMM.mo in integer base units
// (10^8). The HEURISTICS (skew/floor/barrier bps, rebalance sizing) take Nat
// reserves and still return their bps/side decisions; the LP LEDGER (mint/burn,
// pool value) is exact integer. Runs in moc's interpreter via `mops test`.

import AMM "../src/backend/lib/AMM";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

func eq(name : Text, actual : Int, expected : Int) {
  if (actual != expected) { Runtime.trap("FAIL: " # name # " — expected " # debug_show expected # " got " # debug_show actual) };
  Debug.print("  ✓ " # name);
};
func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func nearN(name : Text, a : Nat, b : Nat, tol : Nat) {
  let d = if (a > b) { a - b } else { b - a };
  if (d > tol) { Runtime.trap("FAIL: " # name # " — expected ~" # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── AMM.test ──");

// ── computeInventorySkewBps ── (reserves ×10^8: 2 BTC = 200_000_000) ──
let p0 = AMM.emptyPool("BTC-ICPUSD", "BTC");
let p = { p0 with inventoryTargetBase = 200_000_000; skewIntensityBps = 200 };

eq("skew at target",         AMM.computeInventorySkewBps(p, 200_000_000), 0);
eq("skew 50% over (long)",   AMM.computeInventorySkewBps(p, 300_000_000), -100);
eq("skew 50% under (short)", AMM.computeInventorySkewBps(p, 100_000_000), 100);
eq("skew 100% over clamped", AMM.computeInventorySkewBps(p, 400_000_000), -200);
eq("skew 200% over still clamped at 100%", AMM.computeInventorySkewBps(p, 600_000_000), -200);
eq("skew 100% under clamped", AMM.computeInventorySkewBps(p, 0), 200);

eq("skew with zero intensity", AMM.computeInventorySkewBps({ p with skewIntensityBps = 0 }, 300_000_000), 0);
eq("skew with zero target (disabled)", AMM.computeInventorySkewBps({ p with inventoryTargetBase = 0 }, 300_000_000), 0);

// ── inventoryFloor & computeFloorBarrierBps (#92) ── floor = 15% of 2.0 = 0.3 ──
eqN("inventoryFloor = 15% of target", AMM.inventoryFloor(p), 30_000_000);
eqN("inventoryFloor 0 when unconfigured", AMM.inventoryFloor({ p with inventoryTargetBase = 0 }), 0);

eq("barrier at target = 0",        AMM.computeFloorBarrierBps(p, 200_000_000), 0);
eq("barrier when long = 0",        AMM.computeFloorBarrierBps(p, 300_000_000), 0);
eq("barrier at floor = cap",       AMM.computeFloorBarrierBps(p, 30_000_000), 50000);
eq("barrier below floor = cap",    AMM.computeFloorBarrierBps(p, 10_000_000), 50000);
eq("barrier disabled (intensity)", AMM.computeFloorBarrierBps({ p with skewIntensityBps = 0 }, 100_000_000), 0);
eq("barrier disabled (target 0)",  AMM.computeFloorBarrierBps({ p with inventoryTargetBase = 0 }, 100_000_000), 0);

// Hyperbolic rise: strictly increasing as base falls from target to floor.
let b19 = AMM.computeFloorBarrierBps(p, 190_000_000);
let b15 = AMM.computeFloorBarrierBps(p, 150_000_000);
let b10 = AMM.computeFloorBarrierBps(p, 100_000_000);
if (not (b19 > 0 and b15 > b19 and b10 > b15)) {
  Runtime.trap("FAIL: barrier should rise monotonically toward the floor — got " # debug_show (b19, b15, b10));
};
Debug.print("  ✓ barrier rises monotonically as base falls toward floor");

// ── decideRebalance ── (qty is now Nat base units) ──
let cooldownNs : Int = 60_000_000_000;
let pRb = { p with inventoryTargetBase = 200_000_000 }; // target 2 BTC

// Long, plenty over threshold → returns sell rebalance (qty 0.10 = 10_000_000)
switch (AMM.decideRebalance(pRb, 300_000_000, 1_000_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case (?d) {
    if (d.side != #sell) { Runtime.trap("FAIL: expected sell side") };
    nearN("rebalance qty long 50% over", d.quantity, 10_000_000, 2);
    Debug.print("  ✓ rebalance fires when long");
  };
  case null { Runtime.trap("FAIL: rebalance should have fired (long, deviation 50%)") };
};

// Short → buy
switch (AMM.decideRebalance(pRb, 100_000_000, 1_000_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case (?d) {
    if (d.side != #buy) { Runtime.trap("FAIL: expected buy side when short") };
    Debug.print("  ✓ rebalance fires when short");
  };
  case null { Runtime.trap("FAIL: rebalance should have fired (short)") };
};

// At target — no rebalance
switch (AMM.decideRebalance(pRb, 200_000_000, 1_000_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case null { Debug.print("  ✓ no rebalance at target") };
  case (?_) { Runtime.trap("FAIL: shouldn't rebalance at target") };
};

// 10% over (under 25% threshold) — no rebalance
switch (AMM.decideRebalance(pRb, 220_000_000, 1_000_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case null { Debug.print("  ✓ no rebalance under threshold") };
  case (?_) { Runtime.trap("FAIL: shouldn't rebalance at 10% deviation with 25% threshold") };
};

// Cooldown active → no rebalance
let pHot = { pRb with lastRebalanceNs = 1_000_000_000_000 };
switch (AMM.decideRebalance(pHot, 300_000_000, 1_000_000_000_000 + 30_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case null { Debug.print("  ✓ no rebalance during cooldown") };
  case (?_) { Runtime.trap("FAIL: cooldown should suppress") };
};

// Target=0 (unconfigured) — never fires
switch (AMM.decideRebalance({ pRb with inventoryTargetBase = 0 }, 10_000_000_000, 1_000_000_000_000, 0.25, 0.10, cooldownNs, 50_000_000)) {
  case null { Debug.print("  ✓ no rebalance when target unconfigured") };
  case (?_) { Runtime.trap("FAIL: should not fire with target=0") };
};

// Dust regression: deviation triggers via fractionPerTick but caps below dust.
// target 2.0 → dust 0.002; rawQty = 0.5 * 0.001 = 0.0005 < dust.
switch (AMM.decideRebalance(pRb, 250_000_000, 1_000_000_000_000, 0.10, 0.001, cooldownNs, 50_000_000)) {
  case null { Debug.print("  ✓ dust filter rejects sub-threshold rebalance") };
  case (?_) { Runtime.trap("FAIL: dust filter should have rejected micro-rebalance") };
};

// ── computeLPMint / computeLPBurn ── exact integer ledger (refPrice $75000) ──
let pLp = { p0 with refPrice = 7_500_000_000_000 };

// First deposit (1 BTC + 75000 ICPUSD = $150000 value) anchors 1 LP == $1.
let (mint1, supply1) = AMM.computeLPMint(pLp, 0, 0, 100_000_000, 7_500_000_000_000);
eqN("first deposit anchored at deposit value", mint1, 15_000_000_000_000);
eqN("first deposit supply == mint", supply1, 15_000_000_000_000);

// Second deposit at same valuePerLP=1.0 mints proportionally ($75000 → half).
let pLp2 = { pLp with totalLPSupply = 15_000_000_000_000 };
let (mint2, supply2) = AMM.computeLPMint(pLp2, 100_000_000, 7_500_000_000_000, 50_000_000, 3_750_000_000_000);
eqN("second deposit (half size) mints half", mint2, 7_500_000_000_000);
eqN("supply after 2nd deposit", supply2, 22_500_000_000_000);

// computeLPBurn: redeem 50% of supply → 50% of the basket.
let (baseOut, quoteOut, supplyAfter) = AMM.computeLPBurn(pLp2, 100_000_000, 7_500_000_000_000, 7_500_000_000_000);
eqN("burn 50% of supply gives 50% base", baseOut, 50_000_000);
eqN("burn 50% of supply gives 50% quote", quoteOut, 3_750_000_000_000);
eqN("supply decreases by burned amount", supplyAfter, 7_500_000_000_000);

// ── buildQuoteLadder ── the ONLY AMM fn whose output settles as real orders ──
// (price,qty) pairs are computed in Float from the Nat refPrice then quantized;
// a sign error or bad clamp here mis-prices every AMM quote. Prices use a
// tolerance (Float→Nat quantization noise ~tens of base units); structure is exact.

// empty when unpriced or zero-level
let ladEmpty = AMM.buildQuoteLadder(AMM.emptyPool("BTC-ICPUSD", "BTC"), 0, 0); // refPrice 0
truth("empty ladder when refPrice=0", ladEmpty.bids.size() == 0 and ladEmpty.asks.size() == 0);
let pq = { p0 with refPrice = 7_500_000_000_000; numLevels = 3 };  // $75000, 3 levels, default 20/15 bps, depth 0.05
truth("empty ladder when numLevels=0", AMM.buildQuoteLadder({ pq with numLevels = 0 }, 0, 0).bids.size() == 0);

let lad = AMM.buildQuoteLadder(pq, 0, 0);
eqN("ladder emits numLevels bids", lad.bids.size(), 3);
eqN("ladder emits numLevels asks", lad.asks.size(), 3);

// spread brackets refPrice and never crosses
truth("best bid < refPrice",           lad.bids[0].0 < 7_500_000_000_000);
truth("best ask > refPrice",           lad.asks[0].0 > 7_500_000_000_000);
truth("best bid < best ask (uncrossed)", lad.bids[0].0 < lad.asks[0].0);

// levels step monotonically away from mid
truth("bids strictly descending", lad.bids[0].0 > lad.bids[1].0 and lad.bids[1].0 > lad.bids[2].0);
truth("asks strictly ascending",  lad.asks[0].0 < lad.asks[1].0 and lad.asks[1].0 < lad.asks[2].0);

// every level quotes quoteDepthBase (0.05 base = 5_000_000)
truth("every bid qty == quoteDepthBase",
  lad.bids[0].1 == 5_000_000 and lad.bids[1].1 == 5_000_000 and lad.bids[2].1 == 5_000_000);
truth("every ask qty == quoteDepthBase",
  lad.asks[0].1 == 5_000_000 and lad.asks[1].1 == 5_000_000 and lad.asks[2].1 == 5_000_000);

// half-spread is 20bps: best bid/ask ≈ refPrice ∓ 0.20% ($75000 ∓ $150)
nearN("best bid ≈ refPrice − 20bps", lad.bids[0].0, 7_485_000_000_000, 10_000_000);
nearN("best ask ≈ refPrice + 20bps", lad.asks[0].0, 7_515_000_000_000, 10_000_000);

// skew SIGN (regression for the historic inverted-skew bug): +askSkew lifts asks,
// −bidSkew lowers bids (long-base → negative skew → ladder drops).
let ladSkew = AMM.buildQuoteLadder(pq, -100, 100);   // bidSkew −1%, askSkew +1%
truth("negative bidSkew lowers the bid ladder", ladSkew.bids[0].0 < lad.bids[0].0);
truth("positive askSkew raises the ask ladder", ladSkew.asks[0].0 > lad.asks[0].0);

// volatility widening: an elevated volRegime widens the half-spread both ways
let ladVol = AMM.buildQuoteLadder({ pq with volRegime = 40.0 }, 0, 0); // +20bps half-widening
truth("vol widens ask further from mid", ladVol.asks[0].0 > lad.asks[0].0);
truth("vol widens bid further from mid", ladVol.bids[0].0 < lad.bids[0].0);

// ── never-cross-ref invariant ── (drain fix: quotes must straddle refPrice
// whatever the skew inputs — a crossed mid let adversarial flow round-trip
// the vault at a guaranteed profit). bidMid clamps ≤ ref, askMid ≥ ref.
let refPx : Nat = 7_500_000_000_000;

// A large POSITIVE bid skew (the old symmetric short-inventory lean) must NOT
// lift any bid to/above ref: with half-spread 20bp the best bid stays ≈ ref−20bp.
let ladCrossBid = AMM.buildQuoteLadder(pq, 200, 200);
truth("bid ladder clamped below ref under +200bp skew", ladCrossBid.bids[0].0 < refPx);
nearN("clamped bid sits at ref − half-spread", ladCrossBid.bids[0].0, 7_485_000_000_000, 10_000_000);

// A large NEGATIVE ask skew (old long-inventory lean) must NOT push any ask
// to/below ref: best ask stays ≈ ref+20bp.
let ladCrossAsk = AMM.buildQuoteLadder(pq, -200, -200);
truth("ask ladder clamped above ref under −200bp skew", ladCrossAsk.asks[0].0 > refPx);
nearN("clamped ask sits at ref + half-spread", ladCrossAsk.asks[0].0, 7_515_000_000_000, 10_000_000);

// Extreme adversarial inputs (±100% skew both directions at once): still uncrossed,
// still straddling ref, and monotone away from mid on both sides.
let ladWild = AMM.buildQuoteLadder(pq, 10_000, -10_000);
truth("wild skews: best bid < ref",  ladWild.bids[0].0 < refPx);
truth("wild skews: best ask > ref",  ladWild.asks[0].0 > refPx);
truth("wild skews: book uncrossed",  ladWild.bids[0].0 < ladWild.asks[0].0);
truth("wild skews: bids descend",    ladWild.bids[0].0 > ladWild.bids[1].0);
truth("wild skews: asks ascend",     ladWild.asks[0].0 < ladWild.asks[1].0);

// One-sided intent preserved: a legitimate short-inventory premium (askSkew>0,
// bidSkew=0) raises asks while bids hold at ref − half.
let ladShort = AMM.buildQuoteLadder(pq, 0, 100);
nearN("short: bids hold at ref − half", ladShort.bids[0].0, lad.bids[0].0, 10_000_000);
truth("short: asks carry the premium",  ladShort.asks[0].0 > lad.asks[0].0);
// …and the long-side mirror (bidSkew<0, askSkew=0): bids back away, asks hold.
let ladLong = AMM.buildQuoteLadder(pq, -100, 0);
nearN("long: asks hold at ref + half", ladLong.asks[0].0, lad.asks[0].0, 10_000_000);
truth("long: bids back away",          ladLong.bids[0].0 < lad.bids[0].0);

// Round-trip arithmetic: whatever inventory state produced the quotes, buying
// at the AMM's ask then selling at its bid strictly pays the vault the spread.
truth("round trip pays the vault under short skew", ladShort.asks[0].0 > ladShort.bids[0].0);
truth("round trip pays the vault under long skew",  ladLong.asks[0].0 > ladLong.bids[0].0);
truth("round trip pays the vault under wild skews", ladWild.asks[0].0 > ladWild.bids[0].0);

// ── H-33 (F47): markStaleReason — the play-deposit ADMISSION freshness verdict ──
// null = the mark may value a deposit; ?reason = refuse (the Bridge relays it).
// The bar is the caller's (main.mo passes the 5-min margin wall); pinned here:
// the boundary is inclusive (age == bar fresh, bar + 1 ns stale), a pend
// refuses regardless of age, a zero mark and a never-stamped mark refuse.
let BAR : Int = 300_000_000_000;                      // 5 min, the margin wall
let T0  : Int = 1_700_000_000_000_000_000;
let stamped = AMM.withRefPrice(AMM.emptyPool("BTC-ICPUSD", "BTC"), 6_000_000_000_000, T0);
func isFresh(r : ?Text) : Bool = switch (r) { case null { true }; case (?_) { false } };
func reasonHas(name : Text, r : ?Text, needle : Text) {
  switch (r) {
    case (?t) { if (not Text.contains(t, #text needle)) { Runtime.trap("FAIL: " # name # " — reason '" # t # "' lacks '" # needle # "'") }; Debug.print("  ✓ " # name) };
    case null { Runtime.trap("FAIL: " # name # " — expected a refusal, got fresh") };
  };
};
truth("H-33: a just-stamped mark is fresh",                 isFresh(AMM.markStaleReason(stamped, false, T0, BAR)));
truth("H-33: age 45 s (the quiet-market refresh gap) is fresh", isFresh(AMM.markStaleReason(stamped, false, T0 + 45_000_000_000, BAR)));
truth("H-33: age 240 s — past the 60 s LP bar, under the wall — is fresh", isFresh(AMM.markStaleReason(stamped, false, T0 + 240_000_000_000, BAR)));
truth("H-33: age == bar is fresh (inclusive)",               isFresh(AMM.markStaleReason(stamped, false, T0 + BAR, BAR)));
reasonHas("H-33: age == bar + 1 ns is stale",                AMM.markStaleReason(stamped, false, T0 + BAR + 1, BAR), "BTC mark is stale");
reasonHas("H-33: the stale reason carries the age and the bar", AMM.markStaleReason(stamped, false, T0 + 400_000_000_000, BAR), "400s ago, bar 300s");
reasonHas("H-33: a pended mark refuses even when just stamped", AMM.markStaleReason(stamped, true, T0, BAR), "pending a price-jump confirmation");
reasonHas("H-33: a zero mark refuses",                        AMM.markStaleReason(AMM.emptyPool("BTC-ICPUSD", "BTC"), false, T0, BAR), "no mark price for BTC");
reasonHas("H-33: a never-stamped positive mark refuses",      AMM.markStaleReason({ stamped with refPriceUpdatedNs = 0 }, false, T0, BAR), "never been stamped");
truth("H-33: a clock behind the stamp (negative age) is fresh", isFresh(AMM.markStaleReason(stamped, false, T0 - 1_000_000_000, BAR)));

Debug.print("── AMM.test PASS ──");
