// Unit tests for src/backend/lib/BorrowEngine.mo in integer base units (10^8).
// Pins a funded borrow, linear interest accrual, getHealth + the isLiquidatable
// threshold flip on a collateral crash, partial repay, and the borrow guards.

import BE "../src/backend/lib/BorrowEngine";
import Fixed "../src/backend/lib/Fixed";
import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Int "mo:core/Int";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
let vault = Principal.fromText("aaaaa-aa");
let alice = Principal.fromText("2vxsx-fae");
let bob   = Principal.fromText("tz2ag-zx777-77776-aaabq-cai");
let ICPUSD = Types.QUOTE_TOKEN;
func px(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000_000 }; case (_) { null } } };       // $100000
func pxCrash(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?500_000_000_000 }; case (_) { null } } };    // $5000
func noReserved(_ : Principal, _ : Types.TokenId) : Nat { 0 };
let YEAR = Types.YEAR_NS;

Debug.print("── BorrowEngine.test ──");

// ── Main flow: borrow 40k ICPUSD against 1 BTC ──
let st = BE.emptyState();
let mg = ME.emptyState();
let acc = Accounts.emptyState();
Accounts.setBalance(acc, vault, ICPUSD, 100_000_000_000_000); // 1,000,000 ICPUSD lendable
switch (ME.open(mg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc, alice, "BTC", 100_000_000);          // 1 BTC

switch (BE.borrow(st, mg, acc, noReserved, vault, alice, ICPUSD, 4_000_000_000_000, 0, px)) { // 40000 ICPUSD
  case (#ok(_)) { Debug.print("  ✓ borrow: accepted") };
  case (#err(e)) { Runtime.trap("FAIL borrow: " # e) };
};
eqN("borrow: loan principal 40000", BE.loanOf(st, alice, ICPUSD), 4_000_000_000_000);
eqN("borrow: debtUsdTotal 40000", BE.debtUsdTotal(st, alice, px), 4_000_000_000_000);
eqN("borrow: totalOutstanding 40000", BE.totalOutstanding(st, ICPUSD), 4_000_000_000_000);
eqN("borrow: tokens left vault 960000", Accounts.getBalance(acc, vault, ICPUSD), 96_000_000_000_000);
eqN("borrow: tokens reached user 40000", Accounts.getBalance(acc, alice, ICPUSD), 4_000_000_000_000);

// ── Health: normal price healthy; crash flips isLiquidatable ──
let h = BE.getHealth(st, mg, acc, noReserved, alice, px);
eqN("health: collateral 130000", h.collateralUsd, 13_000_000_000_000);
eqN("health: debt 40000", h.debtUsd, 4_000_000_000_000);
eqN("health: ratio 3.25 (×10^8)", h.healthRatio, 325_000_000);
truth("health: not liquidatable", not h.isLiquidatable);
let hc = BE.getHealth(st, mg, acc, noReserved, alice, pxCrash);
eqN("health(crash): collateral 44500", hc.collateralUsd, 4_450_000_000_000);
truth("health(crash): ratio < maintenance", hc.healthRatio < Types.MAINTENANCE_HEALTH_RATIO);
truth("health(crash): isLiquidatable", hc.isLiquidatable);

// ── Interest: 1yr @5% on 40000 → +2000 ──
BE.accrueAll(st, alice, YEAR);
eqN("accrue: 1yr @5% → 42000", BE.loanOf(st, alice, ICPUSD), 4_200_000_000_000);
BE.accrueAll(st, alice, YEAR);
eqN("accrue: idempotent same now", BE.loanOf(st, alice, ICPUSD), 4_200_000_000_000);

// ── Partial repay: pay 20000 → debt 22000 ──
switch (BE.repay(st, acc, vault, alice, ICPUSD, 2_000_000_000_000, YEAR, px)) {
  case (#ok(_)) { Debug.print("  ✓ repay: accepted") };
  case (#err(e)) { Runtime.trap("FAIL repay: " # e) };
};
eqN("repay: debt reduced to 22000", BE.loanOf(st, alice, ICPUSD), 2_200_000_000_000);
eqN("repay: user paid", Accounts.getBalance(acc, alice, ICPUSD), 2_000_000_000_000);
eqN("repay: vault refunded", Accounts.getBalance(acc, vault, ICPUSD), 98_000_000_000_000);

// ── Borrow guards (fresh state) ──
let st2 = BE.emptyState();
let mg2 = ME.emptyState();
let acc2 = Accounts.emptyState();
Accounts.setBalance(acc2, vault, ICPUSD, 100_000_000_000_000);
switch (BE.borrow(st2, mg2, acc2, noReserved, vault, bob, ICPUSD, 100_000_000, 0, px)) {
  case (#err(_)) { Debug.print("  ✓ borrow: rejected without margin account") };
  case (#ok(_)) { Runtime.trap("FAIL: borrowed without margin account") };
};
switch (ME.open(mg2, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("open bob: " # e) } };
Accounts.setBalance(acc2, bob, "BTC", 100_000_000);
switch (BE.borrow(st2, mg2, acc2, noReserved, vault, bob, ICPUSD, 0, 0, px)) {
  case (#err(_)) { Debug.print("  ✓ borrow: rejected non-positive amount") };
  case (#ok(_)) { Runtime.trap("FAIL: borrowed zero") };
};
switch (BE.borrow(st2, mg2, acc2, noReserved, vault, bob, ICPUSD, 40_000_000_000_000, 0, px)) { // 400000 → projHealth 1.225 < 1.25
  case (#err(_)) { Debug.print("  ✓ borrow: rejected below initial-margin ratio") };
  case (#ok(_)) { Runtime.trap("FAIL: borrowed past initial-margin gate") };
};
truth("borrow guards: no loan created on rejection", BE.loanOf(st2, bob, ICPUSD) == 0);

let st3 = BE.emptyState();
let mg3 = ME.emptyState();
let acc3 = Accounts.emptyState();
Accounts.setBalance(acc3, vault, ICPUSD, 1_000_000_000_000); // 10000 ICPUSD → cap 5000
switch (ME.open(mg3, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc3, alice, "BTC", 100_000_000);
switch (BE.borrow(st3, mg3, acc3, noReserved, vault, alice, ICPUSD, 600_000_000_000, 0, px)) { // 6000 > cap
  case (#err(_)) { Debug.print("  ✓ borrow: rejected over vault cap") };
  case (#ok(_)) { Runtime.trap("FAIL: borrowed past vault cap") };
};

Debug.print("── BorrowEngine.test PASSED ──");

// ── W5-03: boundary fixtures — the rounding DIRECTION pinned at the two
// DECISION call sites (not the primitive; Fixed.test.mo owns that). The
// operands make the ratio division non-even, so flipping the flag at the
// site changes the observable verdict and turns this red.
Debug.print("── W5-03 boundary fixtures ──");

// Liquidation threshold: coll 11_499_999_999 / debt 10_000_000_000 is one
// dust-unit below 1.15. DOWN → ratio 114_999_999 → LIQUIDATABLE. A flip to
// UP would read exactly 115_000_000 and spare the position.
let st4 = BE.emptyState();
let mg4 = ME.emptyState();
let acc4 = Accounts.emptyState();
func pxB(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000 }; case (_) { null } } }; // $100
func pxNone(_ : Types.TokenId) : ?Nat { null };  // BTC leg vanishes; quote counts at par
Accounts.setBalance(acc4, vault, ICPUSD, 100_000_000_000);
switch (ME.open(mg4, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc4, alice, ICPUSD, 1_499_999_999);
Accounts.setBalance(acc4, alice, "BTC", 100_000_000);   // admission collateral only
switch (BE.borrow(st4, mg4, acc4, noReserved, vault, alice, ICPUSD, 10_000_000_000, 0, pxB)) {
  case (#ok(_)) {}; case (#err(e)) { Runtime.trap("FAIL boundary borrow: " # e) };
};
let hb = BE.getHealth(st4, mg4, acc4, noReserved, alice, pxNone);
eqN("boundary health: collateral 11_499_999_999", hb.collateralUsd, 11_499_999_999);
eqN("boundary health: debt 10_000_000_000", hb.debtUsd, 10_000_000_000);
eqN("boundary health: ratio rounds DOWN (114_999_999)", hb.healthRatio, 114_999_999);
truth("boundary health: DOWN direction LIQUIDATES the boundary position (UP would spare it)", hb.isLiquidatable);

// Borrow admission: projected coll 12_499_999_999 / debt 10_000_000_000 is
// one dust-unit below 1.25. DOWN → 124_999_999 → REFUSED. A flip to UP
// would read exactly 125_000_000 and admit it.
let st5 = BE.emptyState();
let mg5 = ME.emptyState();
let acc5 = Accounts.emptyState();
Accounts.setBalance(acc5, vault, ICPUSD, 100_000_000_000);
switch (ME.open(mg5, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc5, bob, ICPUSD, 2_499_999_999);   // + borrowed 10e9 → proj coll 12_499_999_999
switch (BE.borrow(st5, mg5, acc5, noReserved, vault, bob, ICPUSD, 10_000_000_000, 0, pxNone)) {
  case (#err(_)) { Debug.print("  ✓ admission: DOWN direction REFUSES the boundary borrow (UP would admit it)") };
  case (#ok(_)) { Runtime.trap("FAIL: boundary borrow admitted — projected ratio rounded UP") };
};
// One dust-unit more collateral crosses the line: proves the gate sits
// exactly at the boundary rather than somewhere coarser.
Accounts.setBalance(acc5, bob, ICPUSD, 2_500_000_001);
switch (BE.borrow(st5, mg5, acc5, noReserved, vault, bob, ICPUSD, 10_000_000_000, 0, pxNone)) {
  case (#ok(_)) { Debug.print("  ✓ admission: one dust-unit over the line is admitted") };
  case (#err(e)) { Runtime.trap("FAIL: over-boundary borrow refused: " # e) };
};
Debug.print("W5-03 fixtures green");

// ── Task 1788516128: a SHORT close — accrue BEFORE sizing, then settle the
// settlement-message base residue from quote under a cap. The close's buy-back
// is sized from base held − base DEBT; read at the last accrual it under-asks
// by the interest booked since, and the fill (a later message) leaves that
// interest as base debt the pool holds no base to pay. Numbers: 1 BTC at 8 %
// books 5 units over 21 s (round-down) and 1 more over the next 5 s.
Debug.print("── 1788516128: short close — accrue-then-size + capped base-residue cash settle ──");
let st6 = BE.emptyState();
let mg6 = ME.emptyState();
let acc6 = Accounts.emptyState();
Accounts.setBalance(acc6, vault, "BTC", 1_000_000_000);               // the vault lends BTC (10)
Accounts.setBalance(acc6, vault, ICPUSD, 0);
switch (ME.open(mg6, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc6, bob, ICPUSD, 10_000_000_000_000);           // $100k collateral
switch (BE.borrow(st6, mg6, acc6, noReserved, vault, bob, "BTC", 100_000_000, 0, px)) { // short 1 BTC
  case (#ok(_)) { Debug.print("  ✓ short: borrowed 1 BTC against $100k") };
  case (#err(e)) { Runtime.trap("FAIL short borrow: " # e) };
};
// The pool sells the borrowed BTC: base 0, quote +$100k.
Accounts.setBalance(acc6, bob, "BTC", 0);
Accounts.setBalance(acc6, bob, ICPUSD, 20_000_000_000_000);
let T_CALL : Int = 21_000_000_000;   // closePosition 21 s later
eqN("stale read: loanOf at the last accrual is the bare principal (what the old close sized on)", BE.loanOf(st6, bob, "BTC"), 100_000_000);
BE.accrueAll(st6, bob, T_CALL);
eqN("accrue-then-size: the call-time debt carries 5 units of interest (1 BTC × 8 % × 21 s, round-down)", BE.loanOf(st6, bob, "BTC"), 100_000_005);
let sized = BE.loanOf(st6, bob, "BTC");
// The fill lands 5 s later: the pool bought exactly `sized` base; deleveragePool
// accrues first (1788515291), repays in kind, and a residue of 1 unit remains.
let T_FILL : Int = T_CALL + 5_000_000_000;
Accounts.setBalance(acc6, bob, "BTC", sized);
BE.accrueAll(st6, bob, T_FILL);
eqN("settlement message: 1 more unit booked in flight", BE.loanOf(st6, bob, "BTC"), 100_000_006);
switch (BE.repay(st6, acc6, vault, bob, "BTC", sized, T_FILL, px)) {
  case (#ok(_)) {}; case (#err(e)) { Runtime.trap("FAIL in-kind repay: " # e) };
};
eqN("in-kind repay leaves the in-flight interest as BASE debt (1 unit)", BE.loanOf(st6, bob, "BTC"), 1);
eqN("…and the pool holds no base to pay it", Accounts.getBalance(acc6, bob, "BTC"), 0);
let CAP5 : Nat = 500_000_000;   // $5 — main.mo's BASE_RESIDUE_CASH_SETTLE_CAP_USD
switch (BE.settleFromQuote(st6, acc6, vault, bob, "BTC", T_FILL, px, CAP5)) {
  case (#ok(paid)) { eqN("cash settle: 1 unit at $100k costs $0.001, rounded UP against the borrower", paid, 100_000) };
  case (#err(e)) { Runtime.trap("FAIL cash settle: " # e) };
};
eqN("cash settle: base debt gone", BE.loanOf(st6, bob, "BTC"), 0);
truth("cash settle: loan entry deleted outright (no dust record survives)", not BE.hasLoanEntry(st6, bob));
eqN("cash settle: the vault received the quote", Accounts.getBalance(acc6, vault, ICPUSD), 100_000);
eqN("cash settle: the borrower paid it", Accounts.getBalance(acc6, bob, ICPUSD), 20_000_000_000_000 - 100_000);
eqN("cash settle: idempotent — nothing left settles nothing", switch (BE.settleFromQuote(st6, acc6, vault, bob, "BTC", T_FILL, px, CAP5)) { case (#ok(p)) { p }; case (#err(_)) { 999 } }, 0);

// A REAL short is never cash-settled: 1 BTC of debt at $100k is far over the
// cap — refused, the loan and both balances untouched. And the cap is exact:
// a residue worth exactly the cap settles, one worth a unit more does not.
let st7 = BE.emptyState();
let mg7 = ME.emptyState();
let acc7 = Accounts.emptyState();
Accounts.setBalance(acc7, vault, "BTC", 1_000_000_000);
switch (ME.open(mg7, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(acc7, bob, ICPUSD, 10_000_000_000_000);
switch (BE.borrow(st7, mg7, acc7, noReserved, vault, bob, "BTC", 100_000_000, 0, px)) {
  case (#ok(_)) {}; case (#err(e)) { Runtime.trap("FAIL real-short borrow: " # e) };
};
Accounts.setBalance(acc7, bob, "BTC", 0);
Accounts.setBalance(acc7, bob, ICPUSD, 20_000_000_000_000);
switch (BE.settleFromQuote(st7, acc7, vault, bob, "BTC", 0, px, CAP5)) {
  case (#err(_)) { Debug.print("  ✓ cap: a real 1 BTC short ($100k) is REFUSED, not cash-settled") };
  case (#ok(_)) { Runtime.trap("FAIL: a real short was cash-settled under the cap") };
};
eqN("cap refusal: debt untouched", BE.loanOf(st7, bob, "BTC"), 100_000_000);
eqN("cap refusal: borrower's quote untouched", Accounts.getBalance(acc7, bob, ICPUSD), 20_000_000_000_000);
eqN("cap refusal: vault's quote untouched", Accounts.getBalance(acc7, vault, ICPUSD), 0);
switch (BE.settleFromQuote(st7, acc7, vault, bob, "BTC", 0, pxNone, 100_000_000_000_000)) {
  case (#err(_)) { Debug.print("  ✓ no mark: refused even under an unbounded cap (never a free write-off)") };
  case (#ok(_)) { Runtime.trap("FAIL: settled a debt with no mark") };
};
// Exactly-at-cap: 5_000 units at $100k = $5.00 settles under a $5 cap; 5_001 does not.
Accounts.setBalance(acc7, bob, "BTC", 100_000_000 - 5_001);
switch (BE.repay(st7, acc7, vault, bob, "BTC", 100_000_000 - 5_001, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("FAIL trim repay: " # e) } };
eqN("boundary: 5_001 units of residue", BE.loanOf(st7, bob, "BTC"), 5_001);
switch (BE.settleFromQuote(st7, acc7, vault, bob, "BTC", 0, px, CAP5)) {
  case (#err(_)) { Debug.print("  ✓ boundary: $5.001 of residue is over the $5 cap — refused") };
  case (#ok(_)) { Runtime.trap("FAIL: over-cap residue settled") };
};
Accounts.setBalance(acc7, bob, "BTC", 1);
switch (BE.repay(st7, acc7, vault, bob, "BTC", 1, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("FAIL unit repay: " # e) } };
switch (BE.settleFromQuote(st7, acc7, vault, bob, "BTC", 0, px, CAP5)) {
  case (#ok(paid)) { eqN("boundary: exactly $5.00 of residue settles under the $5 cap", paid, 500_000_000) };
  case (#err(e)) { Runtime.trap("FAIL at-cap settle: " # e) };
};
truth("boundary: entry deleted", not BE.hasLoanEntry(st7, bob));
Debug.print("1788516128 fixtures green");

// ── Task 1793732895: the fill-time initial-margin projection ──────────────
// The release clamp's inequality (clampToInitialMargin in main.mo) in closed
// form — fillDeltaPerUnit / fillHeadroom / fillRoom, the ONE source
// previewOpenPosition shares with the release — pinned here so the rule, its
// roundings and the per-asset ceilings it yields cannot move silently. (The
// venue half, preview == release to the base unit, is test_initial_margin §H.)
func eqI(name : Text, a : Int, b : Int) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func between(name : Text, x : Nat, lo : Nat, hi : Nat) {
  if (x < lo or x > hi) { Runtime.trap("FAIL: " # name # " — expected " # debug_show lo # ".." # debug_show hi # " got " # debug_show x) };
  Debug.print("  ✓ " # name # " (" # debug_show x # ")");
};
func ltvOf(t : Types.TokenId) : Nat { switch (Types.marginLTV(t)) { case (?x) { x }; case null { 0 } } };
Debug.print("── fill-time initial-margin projection (task 1793732895) ──");

// The engine report (2026-11-03): ICP at $2.49, LTV 0.80, a fresh pool with
// $4,980 of margin asked for a 10,000-ICP long (5×). Per unit filled a pool
// long gains 0.8 × 2.49 of collateral and owes 1.25 × 2.49 → −1.1205 per ICP.
let icpPx : Nat = 249_000_000;
eqI("pool long, ICP @ 2.49: delta = 0.8·2.49 − 1.25·2.49 = −1.1205", BE.fillDeltaPerUnit(true, #buy, icpPx, ltvOf("ICP"), icpPx), -112_050_000);
eqI("headroom of a debt-free pool = its collateral", BE.fillHeadroom(498_000_000_000, 0), 498_000_000_000);
eqN("…so the release holds the 10,000-ICP ask to 4,444.44 ICP (2.2×)",
  switch (BE.fillRoom(498_000_000_000, -112_050_000)) { case (?q) { q }; case null { 0 } }, 444_444_444_444);
// The BORROW gate alone — the borrowed quote at LTV 1.0 — reads 4 × margin of
// room, the 5× the preview used to promise for every asset.
eqN("borrow gate alone: quote room = 4 × margin (the old 5× answer)", BE.healthRoom(498_000_000_000, 0, Fixed.SCALE, Fixed.SCALE), 4 * 498_000_000_000);

// Per-asset ceilings on a fresh $10k pool at the mark: notional / margin ≈
// 1 / (1.25 − ltv), in basis points of leverage — and the room is EXACT: the
// largest quantity whose fill keeps the line (one more base unit breaches).
let m : Nat = 1_000_000_000_000;   // $10,000
func ceilingBps(token : Types.TokenId, px : Nat) : Nat {
  let d = BE.fillDeltaPerUnit(true, #buy, px, ltvOf(token), px);
  let q = switch (BE.fillRoom(m, d)) { case (?q) { q }; case null { Runtime.trap("FAIL: a pool long is unbounded?") } };
  truth(token # ": the room is the largest safe quantity (q·|δ| ≤ headroom)", Fixed.mul(q, Int.abs(d), true) <= m);
  truth(token # ": …and one more base unit breaches the line", Fixed.mul(q + 1, Int.abs(d), false) > m);
  Fixed.mul(q, px, false) * 10_000 / m
};
between("ICP long ceiling ≈ 2.22× (1 / 0.45)", ceilingBps("ICP", icpPx), 22_221, 22_223);
between("SOL long ceiling ≈ 2.50× (1 / 0.40)", ceilingBps("SOL", 15_000_000_000), 24_999, 25_000);
between("BTC long ceiling ≈ 2.86× (1 / 0.35)", ceilingBps("BTC", 8_051_000_000_000), 28_570, 28_572);
between("ETH long ceiling ≈ 2.86× (1 / 0.35)", ceilingBps("ETH", 300_000_000_000), 28_570, 28_572);
// Shorts land on the SAME ceiling through the borrow gate (the borrowed base
// valued at its LTV): healthRoom(m, 0, ltv, px) × px / m ≈ 1 / (1.25 − ltv).
between("ICP short ceiling via borrowCheck's closed form ≈ 2.22×", Fixed.mul(BE.healthRoom(m, 0, ltvOf("ICP"), icpPx), icpPx, false) * 10_000 / m, 22_221, 22_223);
between("BTC short ceiling via borrowCheck's closed form ≈ 2.86×", Fixed.mul(BE.healthRoom(m, 0, ltvOf("BTC"), 8_051_000_000_000), 8_051_000_000_000, false) * 10_000 / m, 28_570, 28_572);
// At the mark the long's room and the short's room are the same closed form,
// m / ((1.25 − ltv) × price) — healthRoom divides twice (by 1.25 − ltv, then by
// the price), fillRoom once (by |δ| with 1.25 × qp rounded UP), so the two
// floors may differ by ONE base unit (10⁻⁸ of a token); never more.
let longRoomIcp : Nat = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #buy, icpPx, ltvOf("ICP"), icpPx))) { case (?q) { q }; case null { 0 } };
let shortRoomIcp : Nat = BE.healthRoom(m, 0, ltvOf("ICP"), icpPx);
truth("…and at the mark the long's room is the short's room within one base unit (ICP: " # debug_show longRoomIcp # " vs " # debug_show shortRoomIcp # ")",
  (if (longRoomIcp >= shortRoomIcp) { longRoomIcp - shortRoomIcp } else { shortRoomIcp - longRoomIcp }) <= 1);

// The other arms and the edge shapes.
eqI("pool short: delta = qp − 1.25·oracle (the post-sale world at the floor price)", BE.fillDeltaPerUnit(true, #sell, icpPx, ltvOf("ICP"), 236_550_000), 236_550_000 - 311_250_000);
eqI("wallet-era buy: the collateral swap only (0.8·oracle − qp)", BE.fillDeltaPerUnit(false, #buy, icpPx, ltvOf("ICP"), icpPx), 199_200_000 - 249_000_000);
eqI("wallet-era sell: qp − 0.8·oracle", BE.fillDeltaPerUnit(false, #sell, icpPx, ltvOf("ICP"), icpPx), 249_000_000 - 199_200_000);
truth("delta ≥ 0 → no bound (null)", BE.fillRoom(m, 0) == null and BE.fillRoom(m, 5) == null);
eqN("headroom 0 → room 0 (at the floor)", switch (BE.fillRoom(0, -1)) { case (?q) { q }; case null { 99 } }, 0);
eqN("…negative headroom too (below the floor)", switch (BE.fillRoom(-5, -1)) { case (?q) { q }; case null { 99 } }, 0);
eqI("headroom rounds the required collateral UP (debt side, against the pool)", BE.fillHeadroom(1_000_000_000_000, 400_000_000_001), 1_000_000_000_000 - 500_000_000_002);
Debug.print("1793732895 fixtures green");

// ── Task 1793733917: the SHORT closed form at a floor price ───────────────
// borrowCheck values the borrowed base at its LTV BEFORE the sale: notional ≤
// m / (1.25 − ltv). The release clamp scores the POST-sale world at the floor
// qp = oracle·(1 − slip): the proceeds q·qp against 1.25·q·oracle of base
// debt, so notional ≤ m / (0.25 + slip) — independent of the asset's LTV. The
// clamp binds below the borrow gate exactly when 1 − slip < ltv, the corner
// previewOpenPosition's #buy-only gate missed. Pinned on the brief's venue
// numbers (BTC @ 50,000, a fresh $10k pool; test_initial_margin §H6-H8 is the
// venue half) and on the per-slippage ceilings and per-asset crossovers.
Debug.print("── short fill projection at a floor price (task 1793733917) ──");
let btcPx : Nat = 5_000_000_000_000;   // $50,000
let floor20 : Nat = Fixed.mul(btcPx, Fixed.SCALE - 20_000_000, false);   // 40,000 — the 20 % floor
let floor05 : Nat = Fixed.mul(btcPx, Fixed.SCALE - 5_000_000, false);    // 47,500 — the 5 % floor
eqN("the 20 % floor on BTC @ 50,000 is 40,000", floor20, 4_000_000_000_000);
eqI("pool short at the 20 % floor: delta = 40,000 − 1.25·50,000 = −22,500 per BTC", BE.fillDeltaPerUnit(true, #sell, btcPx, ltvOf("BTC"), floor20), -2_250_000_000_000);
let shortRoom20 : Nat = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #sell, btcPx, ltvOf("BTC"), floor20))) { case (?q) { q }; case null { 0 } };
eqN("…so the clamp holds a fresh $10k pool to 10,000 / 22,500 = 0.44444444 BTC (2.22×)", shortRoom20, 44_444_444);
let borrowRoomBtc : Nat = BE.healthRoom(m, 0, ltvOf("BTC"), btcPx);
eqN("borrowCheck's closed form for the same short: 10,000 / (1.25 − 0.9) / 50,000 = 0.57142857 BTC (2.86×)", borrowRoomBtc, 57_142_857);
truth("at 20 % slippage the clamp binds BELOW the borrow gate (1 − 0.20 < 0.90): min(borrow room, clamp room) is the clamp's 0.4444", shortRoom20 < borrowRoomBtc);
let shortRoom05 : Nat = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #sell, btcPx, ltvOf("BTC"), floor05))) { case (?q) { q }; case null { 0 } };
eqN("at the 5 % floor the clamp's room is 10,000 / 15,000 = 0.66666666 BTC (3.33×)", shortRoom05, 66_666_666);
truth("…above the borrow gate's 0.5714 (1 − 0.05 > 0.90): the borrow gate binds, min(…) = 0.57142857", shortRoom05 > borrowRoomBtc);
// The crossover: at slip = 1 − ltv the two closed forms coincide (one base
// unit of rounding apart at most — healthRoom divides twice, fillRoom once).
let floor10 : Nat = Fixed.mul(btcPx, Fixed.SCALE - 10_000_000, false);   // 45,000 — BTC's 1 − ltv
let shortRoom10 : Nat = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #sell, btcPx, ltvOf("BTC"), floor10))) { case (?q) { q }; case null { 0 } };
truth("at slip = 1 − ltv (BTC: 10 %) the clamp's room equals the borrow gate's within one base unit (" # debug_show shortRoom10 # " vs " # debug_show borrowRoomBtc # ")",
  (if (shortRoom10 >= borrowRoomBtc) { shortRoom10 - borrowRoomBtc } else { borrowRoomBtc - shortRoom10 }) <= 1);
// Per-slippage ceilings of the post-sale rule, notional / margin in bps of
// leverage = 1 / (0.25 + slip): the asset's LTV does not enter.
func shortCeilingBps(slipE8 : Nat) : Nat {
  let qp = Fixed.mul(btcPx, Fixed.SCALE - slipE8, false);
  let q = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #sell, btcPx, ltvOf("BTC"), qp))) { case (?q) { q }; case null { Runtime.trap("FAIL: a pool short is unbounded?") } };
  Fixed.mul(q, btcPx, false) * 10_000 / m
};
between("short ceiling at 5 % slippage ≈ 3.33× (1 / 0.30)", shortCeilingBps(5_000_000), 33_332, 33_334);
between("short ceiling at 15 % slippage = 2.50× (1 / 0.40)", shortCeilingBps(15_000_000), 24_999, 25_000);
between("short ceiling at 20 % slippage ≈ 2.22× (1 / 0.45)", shortCeilingBps(20_000_000), 22_221, 22_223);
between("short ceiling at 25 % slippage = 2.00× (1 / 0.50)", shortCeilingBps(25_000_000), 19_999, 20_000);
// The crossover slippage per asset is 1 − ltv — ICP 20 %, SOL 15 %, BTC/ETH
// 10 % — past it the clamp's ceiling sits under the borrow gate's 1 / (1.25 − ltv).
func clampBindsBelowBorrow(token : Types.TokenId, px : Nat, slipE8 : Nat) : Bool {
  let qp = Fixed.mul(px, Fixed.SCALE - slipE8, false);
  let clampRoom = switch (BE.fillRoom(m, BE.fillDeltaPerUnit(true, #sell, px, ltvOf(token), qp))) { case (?q) { q }; case null { 0 } };
  clampRoom < BE.healthRoom(m, 0, ltvOf(token), px)
};
truth("ICP (LTV 0.80): the clamp binds past 20 % slippage, not before", clampBindsBelowBorrow("ICP", icpPx, 21_000_000) and not clampBindsBelowBorrow("ICP", icpPx, 19_000_000));
truth("SOL (LTV 0.85): past 15 %", clampBindsBelowBorrow("SOL", 15_000_000_000, 16_000_000) and not clampBindsBelowBorrow("SOL", 15_000_000_000, 14_000_000));
truth("BTC / ETH (LTV 0.90): past 10 %",
  clampBindsBelowBorrow("BTC", btcPx, 11_000_000) and not clampBindsBelowBorrow("BTC", btcPx, 9_000_000)
  and clampBindsBelowBorrow("ETH", 300_000_000_000, 11_000_000) and not clampBindsBelowBorrow("ETH", 300_000_000_000, 9_000_000));
Debug.print("1793733917 fixtures green");
