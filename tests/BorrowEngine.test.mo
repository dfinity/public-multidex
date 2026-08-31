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
