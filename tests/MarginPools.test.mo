// Pure-function unit tests for src/backend/lib/MarginPools.mo in integer base
// units (10^8). Pins the position-accounting math (VWAP entry, realized PnL on
// reduce/flip), the display math, and — the strong check — the conservation
// invariant cashflow + size·mark == realized + uPnL, which holds EXACTLY in
// integers (no tolerance). Runs in moc's interpreter via `mops test`.

import MP "../src/backend/lib/MarginPools";
import Fixed "../src/backend/lib/Fixed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func eqI(name : Text, a : Int, b : Int) {
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

Debug.print("── MarginPools.test ──");

// ── applyFill: open / increase (VWAP) / reduce (realize) / flip / close ──
// (prices ×10^8: $100 = 10_000_000_000; sizes ×10^8: 2 BTC = 200_000_000)

// open a long: 2 @ 100
let f1 = MP.applyFill(0, 0, 200_000_000, 10_000_000_000);
eqI("open long: size", f1.size, 200_000_000);
eqN("open long: entry = fill", f1.entryPrice, 10_000_000_000);
eqI("open long: no realized", f1.realizedDelta, 0);

// increase: +2 @ 120 → VWAP (2@100 + 2@120 = 4 @ 110)
let f2 = MP.applyFill(f1.size, f1.entryPrice, 200_000_000, 12_000_000_000);
eqI("increase: size", f2.size, 400_000_000);
eqN("increase: VWAP entry 110", f2.entryPrice, 11_000_000_000);
eqI("increase: no realized", f2.realizedDelta, 0);

// reduce by 1 @ 130 → realize (130-110)*1 = +20, entry unchanged
let f3 = MP.applyFill(f2.size, f2.entryPrice, -100_000_000, 13_000_000_000);
eqI("reduce: size", f3.size, 300_000_000);
eqN("reduce: entry unchanged", f3.entryPrice, 11_000_000_000);
eqI("reduce: realized +20", f3.realizedDelta, 2_000_000_000);

// flip: sell 4 @ 90 → reduceQty min(4,3)=3, realized (90-110)*3 = -60, remainder -1 @ 90
let f4 = MP.applyFill(f3.size, f3.entryPrice, -400_000_000, 9_000_000_000);
eqI("flip: size now short", f4.size, -100_000_000);
eqN("flip: entry = fill", f4.entryPrice, 9_000_000_000);
eqI("flip: realized -60", f4.realizedDelta, -6_000_000_000);

// fully close a short → entry resets to 0; (90-80)*1 short = +10
let c0 = MP.applyFill(-100_000_000, 9_000_000_000, 100_000_000, 8_000_000_000);
eqI("close short: flat size", c0.size, 0);
eqN("close short: entry reset", c0.entryPrice, 0);
eqI("close short: realized +10", c0.realizedDelta, 1_000_000_000);

// ── Conservation: cashflow + size·mark == realizedTotal + uPnL (EXACT) ──
let fills : [(Int, Nat)] = [
  (200_000_000, 10_000_000_000), (200_000_000, 12_000_000_000),
  (-100_000_000, 13_000_000_000), (-400_000_000, 9_000_000_000)
];
var size : Int = 0; var entry : Nat = 0; var realizedTotal : Int = 0; var cashflow : Int = 0;
for ((fs, fp) in fills.vals()) {
  let r = MP.applyFill(size, entry, fs, fp);
  size := r.size; entry := r.entryPrice; realizedTotal += r.realizedDelta;
  cashflow += -(fs * fp) / 100_000_000;       // quote out on buys, in on sells
};
let mark : Nat = 9_000_000_000;
let lhs : Int = cashflow + (size * mark) / 100_000_000;
let rhs : Int = realizedTotal + MP.unrealizedPnl(size, entry, mark);
eqI("conservation: cashflow PnL = -40", lhs, -4_000_000_000);
eqI("conservation: cashflow == position PnL", lhs, rhs);

// ── unrealizedPnl signs ──
eqI("long uPnL up", MP.unrealizedPnl(200_000_000, 10_000_000_000, 11_000_000_000), 2_000_000_000);
eqI("short uPnL on price fall", MP.unrealizedPnl(-200_000_000, 10_000_000_000, 9_000_000_000), 2_000_000_000);
eqI("short uPnL on price rise", MP.unrealizedPnl(-200_000_000, 10_000_000_000, 11_000_000_000), -2_000_000_000);

// ── notional & marginUsage (maint 1.15 = 115_000_000) ──
eqN("notional abs", MP.notional(-300_000_000, 5_000_000_000), 15_000_000_000);
eqN("usage: no debt = 0", MP.marginUsage(100_000_000_000, 0, 115_000_000), 0);
// coll 1150, debt 1000, maint 1.15 → usage = 1.0 (at the line)
eqN("usage at line", MP.marginUsage(115_000_000_000, 100_000_000_000, 115_000_000), 100_000_000);
// W5-16 (#38.6): zero collateral with live debt = fully liquidatable (1.0),
// via the EXPLICIT guard. Without it this is a divide-by-zero TRAP — and
// marginUsage is reached from the heartbeat's synchronous leaderboard/margin
// pass, where a trap is not one bad response but PERMANENT maintenance halt
// until an upgrade (the W3-08 class). This fixture is what holds it in place.
eqN("usage: zero collateral + debt = 1.0 (guard, not a heartbeat-halting trap)",
  MP.marginUsage(0, 100_000_000_000, 115_000_000), 100_000_000);
// coll 2300, debt 1000 → usage = 0.5 → 50% to liq
eqN("usage half", MP.marginUsage(230_000_000_000, 100_000_000_000, 115_000_000), 50_000_000);

// ── liquidation price (debt-aware, per-leg — #15.4 + OhShii terms 2/3) ──
// liqPrice(otherColl, otherDebt, heldBase, debtBase, ltv, maint); the health
// identity these fixtures assert: evaluating getHealth's OWN equation at the
// returned price lands exactly on the maintenance ratio (1.15).
func healthAt(otherColl : Nat, otherDebt : Nat, held : Nat, borrowed : Nat, ltv : Nat, p : Nat) : Nat {
  // Exactly getHealth's arithmetic: valuations' per-token contribUsd
  // (bal×px DOWN, ×ltv DOWN), debtUsdTotal (principal×px UP), ratio DOWN.
  let coll = otherColl + Fixed.mul(Fixed.mul(held, p, false), ltv, false);
  let debt = otherDebt + Fixed.mul(borrowed, p, true);
  if (debt == 0) { Runtime.trap("healthAt: no debt") };
  Fixed.div(coll, debt, false);
};

// Pure LONG (no base debt): 2 BTC held, ltv 0.85, quote debt $120k, no other
// coll → P = (1.15·120000)/(2·0.85) = 81176.47 — unchanged from the
// pre-#15.4 liqPriceLong (the debt-aware form reduces to it when debtBase=0).
switch (MP.liqPrice(0, 12_000_000_000_000, 200_000_000, 0, 85_000_000, 115_000_000)) {
  case (?p) {
    nearN("liqPrice long 81176.47", p, 8_117_647_058_824, 4);
    eqN("long identity: health at P == 1.15", healthAt(0, 12_000_000_000_000, 200_000_000, 0, 85_000_000, p), 115_000_000);
  };
  case null { Runtime.trap("FAIL: liqPrice long returned null") };
};
// LONG already safe: cash margin $200k covers maint·debt → null
truth("liqPrice long null when safe", MP.liqPrice(20_000_000_000_000, 12_000_000_000_000, 200_000_000, 0, 85_000_000, 115_000_000) == null);
// Pure SHORT (no residual base): cash $100k, 1 BTC borrowed →
// P = 100000/1.15 = 86956.52 — unchanged from the pre-#15.4 liqPriceShort.
switch (MP.liqPrice(10_000_000_000_000, 0, 0, 100_000_000, 85_000_000, 115_000_000)) {
  case (?p) {
    nearN("liqPrice short 86956.52", p, 8_695_652_173_913, 4);
    eqN("short identity: health at P == 1.15", healthAt(10_000_000_000_000, 0, 0, 100_000_000, 85_000_000, p), 115_000_000);
  };
  case null { Runtime.trap("FAIL: liqPrice short returned null") };
};

// ── OhShii term 2: the reporter's table (#15 comment), verbatim ──
// SOL ltv 0.85, maint 1.15, otherColl $1,000, otherDebt held at 0. The
// pre-fix formula netted first — P = otherColl/(M·|borrowed−held|) — and
// reported $124.2236 / $289.855 for rows 2/3, prices at which the pool's
// health is 1.06 / 0.94 (row 3: INSOLVENT at the price the UI called its
// liquidation price). The true crossings, pinned here exactly:
//   row 1 (control, held 0): $86.9565 — old and new agree;
//   row 2 (held 3, borrowed 10): $111.7318, not $124.2236;
//   row 3 (held 7, borrowed 10): $180.180,  not $289.855.
do {
  let oc = 100_000_000_000; // $1,000
  switch (MP.liqPrice(oc, 0, 0, 1_000_000_000, 85_000_000, 115_000_000)) {
    case (?p) {
      eqN("table row 1 (control): 86.9565", p, 8_695_652_173);
      eqN("row 1 identity: health at P == 1.15", healthAt(oc, 0, 0, 1_000_000_000, 85_000_000, p), 115_000_000);
    };
    case null { Runtime.trap("FAIL: table row 1 null") };
  };
  switch (MP.liqPrice(oc, 0, 300_000_000, 1_000_000_000, 85_000_000, 115_000_000)) {
    case (?p) {
      eqN("table row 2: 111.7318 (old code said 124.2236)", p, 11_173_184_357);
      eqN("row 2 identity: health at P == 1.15", healthAt(oc, 0, 300_000_000, 1_000_000_000, 85_000_000, p), 115_000_000);
    };
    case null { Runtime.trap("FAIL: table row 2 null") };
  };
  switch (MP.liqPrice(oc, 0, 700_000_000, 1_000_000_000, 85_000_000, 115_000_000)) {
    case (?p) {
      eqN("table row 3: 180.180 (old code said 289.855)", p, 18_018_018_018);
      truth("row 3: the pre-fix number is gone", p != 28_985_507_246);
      eqN("row 3 identity: health at P == 1.15", healthAt(oc, 0, 700_000_000, 1_000_000_000, 85_000_000, p), 115_000_000);
    };
    case null { Runtime.trap("FAIL: table row 3 null") };
  };
  // Term 1 (#15.4 proper): pool-wide OTHER debt now enters the short branch.
  // Row-2 legs + otherDebt $200 → P = (1000 − 1.15·200)/(1.15·10 − 0.85·3)
  // = 770/8.95 = $86.0335 (the debt-blind row-2 answer was $111.73).
  switch (MP.liqPrice(oc, 20_000_000_000, 300_000_000, 1_000_000_000, 85_000_000, 115_000_000)) {
    case (?p) {
      eqN("term 1: other-market debt pulls the short crossing in (86.0335)", p, 8_603_351_955);
      eqN("term 1 identity: health at P == 1.15", healthAt(oc, 20_000_000_000, 300_000_000, 1_000_000_000, 85_000_000, p), 115_000_000);
    };
    case null { Runtime.trap("FAIL: term 1 case null") };
  };
  // Direction follows the HEALTH SLOPE, not the net-size sign: net long
  // (held 10 > borrowed 9) but held·ltv (8.5) < M·debtBase (10.35) → the
  // crossing is ABOVE the entry region (short-like), P = 100/1.85 = $54.05.
  switch (MP.liqPrice(10_000_000_000, 0, 1_000_000_000, 900_000_000, 85_000_000, 115_000_000)) {
    case (?p) {
      eqN("direction by slope: net-long pool liquidating on a RISING mark", p, 5_405_405_405);
      eqN("slope-case identity: health at P == 1.15", healthAt(10_000_000_000, 0, 1_000_000_000, 900_000_000, 85_000_000, p), 115_000_000);
    };
    case null { Runtime.trap("FAIL: slope case null") };
  };
  // A = 0 (held·ltv == M·debtBase: 23·0.85 == 17·1.15): price-insensitive → null.
  truth("liqPrice null when price-insensitive", MP.liqPrice(oc, 0, 2_300_000_000, 1_700_000_000, 85_000_000, 115_000_000) == null);
  // Short-like with nothing price-independent left (otherColl ≤ M·otherDebt):
  // liquidatable at EVERY price → 0, the at-or-below-mark display signal.
  truth("liqPrice 0 when liquidatable at every price", MP.liqPrice(0, 10_000_000_000, 0, 300_000_000, 85_000_000, 115_000_000) == ?0);
};

// pctToLiq: mark 100000, liq 80000 → 20%
switch (MP.pctToLiq(10_000_000_000_000, ?8_000_000_000_000)) {
  case (?d) { eqN("pctToLiq 20%", d, 20_000_000) };
  case null { Runtime.trap("FAIL: pctToLiq null") };
};
truth("pctToLiq null when liq null", MP.pctToLiq(10_000_000_000_000, null) == null);

// ── pool principal: deterministic + injective ──
truth("poolPrincipal deterministic", Principal.equal(MP.poolPrincipal(7), MP.poolPrincipal(7)));
truth("poolPrincipal distinct ids", not Principal.equal(MP.poolPrincipal(1), MP.poolPrincipal(2)));
truth("poolPrincipal distinct large", not Principal.equal(MP.poolPrincipal(1), MP.poolPrincipal(4294967297)));

Debug.print("── MarginPools.test: all passed ──");

// ── W5-03: liquidation-price display direction, decided and pinned ──
// LONG-like rounds UP (the mark FALLS toward its liq price — a displayed
// price may never look farther away than reality); SHORT-like rounds DOWN
// (the mark RISES toward it). Operands chosen so the final division does
// NOT come out even: flipping the rounding flag at the call site flips the
// exact value and turns this red. The liquidation DECISION is getHealth's
// DOWN-rounded ratio, pinned in BorrowEngine.test.mo — these are display.
// (Pinned across the #15.4 debt-aware rewrite: the same operand shapes,
// expressed as liqPrice's per-leg inputs, produce the same pinned values.)
Debug.print("── W5-03 liq-price direction ──");
do {
  // maintOtherDebt = ceil(1.15 × $100) = 11_500_000_000; num = 10_000_000_000;
  // heldLtv = 3.0 × 1.0 = 300_000_000 → P = 10e9/3 = 3_333_333_333.33…
  let long = MP.liqPrice(1_500_000_000, 10_000_000_000, 3_00_000_000, 0, 100_000_000, 115_000_000);
  switch (long) {
    case (?p) { eqN("liqPrice long-like rounds UP (3_333_333_334, conservative for a falling mark)", p, 3_333_333_334) };
    case null { truth("liqPrice long-like returned a price", false) };
  };
  // maintDebtBase = ceil(3.0 × 1.15) = 345_000_000 → P = 10e9/3.45 = 2_898_550_724.63…
  let shortP = MP.liqPrice(10_000_000_000, 0, 0, 3_00_000_000, 85_000_000, 115_000_000);
  switch (shortP) {
    case (?p) { eqN("liqPrice short-like rounds DOWN (2_898_550_724, conservative for a rising mark)", p, 2_898_550_724) };
    case null { truth("liqPrice short-like returned a price", false) };
  };
};
Debug.print("W5-03 direction pinned");
