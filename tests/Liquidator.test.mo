// Pure-function unit tests for src/backend/lib/Liquidator.mo in integer base
// units (10^8) — the single most money-critical path. Pins: the race-safe no-op
// on a healthy user, the planLiquidation decision, an end-to-end liquidation's
// INVARIANTS (debt down, health restored above maintenance, collateral moved to
// the vault, penalty kept — asserted as properties), and the internally-netted
// long↔short settlement (deterministic, exact).

import LQ "../src/backend/lib/Liquidator";
import BE "../src/backend/lib/BorrowEngine";
import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Option "mo:core/Option";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
let QUOTE = Types.QUOTE_TOKEN;
let vault = Principal.fromText("aaaaa-aa");
let alice = Principal.fromText("2vxsx-fae");
let bob   = Principal.fromText("tz2ag-zx777-77776-aaabq-cai");

func px(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000_000 }; case (_) { null } } };  // $100000
func pxCrash(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?500_000_000_000 }; case (_) { null } } }; // $5000
func noReserved(_ : Principal, _ : Types.TokenId) : Nat { 0 };

// alice: 1 BTC collateral, 40k ICPUSD borrowed (healthy at BTC=100k).
func liquidatableAlice() : (BE.LoanState, ME.MarginState, Accounts.AccountState) {
  let st = BE.emptyState(); let mg = ME.emptyState(); let acc = Accounts.emptyState();
  Accounts.setBalance(acc, vault, QUOTE, 100_000_000_000_000);  // 1,000,000 ICPUSD
  switch (ME.open(mg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
  Accounts.setBalance(acc, alice, "BTC", 100_000_000);          // 1 BTC
  switch (BE.borrow(st, mg, acc, noReserved, vault, alice, QUOTE, 4_000_000_000_000, 0, px)) { // 40000
    case (#ok(_)) {}; case (#err(e)) { Runtime.trap("setup borrow: " # e) };
  };
  (st, mg, acc);
};

Debug.print("── Liquidator.test ──");

// ── Healthy user: no-op (#healthy) and no plan ──
let (st0, mg0, acc0) = liquidatableAlice();
switch (LQ.tryLiquidate(st0, mg0, acc0, noReserved, alice, vault, 1, px)) {
  case (#healthy) { Debug.print("  ✓ healthy user → #healthy no-op") };
  case (_) { Runtime.trap("FAIL: liquidated a healthy user") };
};
truth("planLiquidation: null when healthy", Option.isNull(LQ.planLiquidation(st0, mg0, acc0, noReserved, alice, px)));

// ── Crash BTC 100k→5k → alice liquidatable ──
let (st, mg, acc) = liquidatableAlice();
let hBefore = BE.getHealth(st, mg, acc, noReserved, alice, pxCrash);
truth("setup: liquidatable after crash", hBefore.isLiquidatable);

switch (LQ.planLiquidation(st, mg, acc, noReserved, alice, pxCrash)) {
  case (?plan) {
    truth("plan: targets ICPUSD debt", plan.debtToken == QUOTE);
    truth("plan: seize qty > 0", plan.seizeQty > 0);
  };
  case null { Runtime.trap("FAIL: no plan for a liquidatable user") };
};

let debtBefore  = BE.loanOf(st, alice, QUOTE);
let aliceBefore = Accounts.getBalance(acc, alice, QUOTE);
let vaultBefore = Accounts.getBalance(acc, vault, QUOTE);
switch (LQ.tryLiquidate(st, mg, acc, noReserved, alice, vault, 1, pxCrash)) {
  case (#liquidated(_)) { Debug.print("  ✓ liquidatable user → #liquidated") };
  case (#insolvent(_)) { Debug.print("  ✓ liquidatable user → #insolvent (acceptable: collateral short)") };
  case (_) { Runtime.trap("FAIL: liquidatable user not acted on") };
};
truth("liquidate: debt reduced", BE.loanOf(st, alice, QUOTE) < debtBefore);
truth("liquidate: collateral seized from user", Accounts.getBalance(acc, alice, QUOTE) < aliceBefore);
truth("liquidate: collateral + penalty to vault", Accounts.getBalance(acc, vault, QUOTE) > vaultBefore);
let hAfter = BE.getHealth(st, mg, acc, noReserved, alice, pxCrash);
truth("liquidate: health strictly improved", hAfter.healthRatio > hBefore.healthRatio);
truth("liquidate: restored out of liquidatable range", not hAfter.isLiquidatable);

// ── #insolvent: liquidatable, owes debt, but NO seizable collateral → zero-recovery
//    event (so the insurance fund closes it instead of leaving a perpetual zombie) ──
let (ist, img, iacc) = liquidatableAlice();
// strip ALL of alice's balances: she still owes 40k ICPUSD but holds nothing to seize.
Accounts.setBalance(iacc, alice, "BTC", 0);
Accounts.setBalance(iacc, alice, QUOTE, 0);
let hIns = BE.getHealth(ist, img, iacc, noReserved, alice, px);
truth("insolvent setup: liquidatable", hIns.isLiquidatable);
truth("insolvent setup: still owes debt", hIns.debtUsd > 0);
let debtBeforeIns = BE.loanOf(ist, alice, QUOTE);
switch (LQ.tryLiquidate(ist, img, iacc, noReserved, alice, vault, 1, px)) {
  case (#insolvent(ev)) {
    eqN("insolvent: zero debt repaid", ev.debtRepaid, 0);
    eqN("insolvent: zero collateral seized", ev.collateralSeized, 0);
    truth("insolvent: names the owed token", ev.debtToken == QUOTE);
    Debug.print("  ✓ no-collateral liquidatable user → #insolvent (zero recovery)");
  };
  case (#liquidated(_)) { Runtime.trap("FAIL: seized collateral from a user who has none") };
  case (#healthy) { Runtime.trap("FAIL: reported healthy despite open debt + zero collateral") };
};
// insolvent repays nothing, so the debt is never REDUCED (it may tick up by the
// 1-base-unit interest accrued between the borrow and the liquidation instant).
truth("insolvent: debt not repaid (left standing for the insurance fund)", BE.loanOf(ist, alice, QUOTE) >= debtBeforeIns);

// ── #insolvent with a SEIZING pass: the penalty is REAL on the insolvent path ──
// classifySeizingPass returns #insolvent when the pass DID seize but the user is
// still liquidatable with nothing seizable left — and every seize keeps the 5%
// penalty in the vault, so penaltyUsd = proceedsUsd − debtRepaidUsd > 0. main.mo
// answers this event with accrueInsurancePenalty + absorbBadDebt (issue #48.2:
// the accrual used to be skipped, so the fund paid the shortfall while its
// earned penalty stayed with LPs). This pins the Liquidator half: a non-zero,
// exactly-derived penaltyUsd rides the #insolvent event.
let (pst, pmg, pacc) = liquidatableAlice();
Accounts.setBalance(pacc, alice, QUOTE, 0); // only the 1 BTC remains seizable
let hPen = BE.getHealth(pst, pmg, pacc, noReserved, alice, pxCrash);
truth("seizing-insolvent setup: liquidatable at BTC=5k", hPen.isLiquidatable);
truth("seizing-insolvent setup: collateral value < debt", hPen.collateralUsd < hPen.debtUsd);
switch (LQ.tryLiquidate(pst, pmg, pacc, noReserved, alice, vault, 1, pxCrash)) {
  case (#insolvent(ev)) {
    truth("seizing-insolvent: the pass DID seize (debt repaid > 0)", ev.debtRepaidUsd > 0);
    truth("seizing-insolvent: penaltyUsd is non-zero", ev.penaltyUsd > 0);
    eqN("seizing-insolvent: penaltyUsd = proceedsUsd − debtRepaidUsd",
        ev.penaltyUsd, ev.proceedsUsd - ev.debtRepaidUsd);
    Debug.print("  ✓ seizing pass → #insolvent with a real penalty (penaltyUsd = " # debug_show ev.penaltyUsd # ")");
  };
  case (#liquidated(_)) { Runtime.trap("FAIL: 1 BTC @5k cannot cover 40k debt — expected #insolvent") };
  case (#healthy) { Runtime.trap("FAIL: reported healthy despite 40k debt against 5k collateral") };
  case (#err(e)) { Runtime.trap("FAIL: seizing-insolvent errored: " # e) };
};
// The seized BTC (repaid + penalty worth) is retained by the vault.
eqN("seizing-insolvent: all BTC seized from alice", Accounts.getBalance(pacc, alice, "BTC"), 0);

// ── Internal netting: long (holds BTC, owes ICPUSD) ↔ short (holds ICPUSD, owes BTC) ──
let nst = BE.emptyState(); let nmg = ME.emptyState(); let nacc = Accounts.emptyState();
Accounts.setBalance(nacc, vault, QUOTE, 100_000_000_000_000);
Accounts.setBalance(nacc, vault, "BTC", 100_000_000); // 1 BTC lendable (cap 0.5)
// seller (alice): 1 BTC, borrows 30k ICPUSD
switch (ME.open(nmg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(nacc, alice, "BTC", 100_000_000);
switch (BE.borrow(nst, nmg, nacc, noReserved, vault, alice, QUOTE, 3_000_000_000_000, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("seller borrow: " # e) } };
// buyer (bob): 50k ICPUSD, borrows 0.2 BTC
switch (ME.open(nmg, bob, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
Accounts.setBalance(nacc, bob, QUOTE, 5_000_000_000_000);
switch (BE.borrow(nst, nmg, nacc, noReserved, vault, bob, "BTC", 20_000_000, 0, px)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap("buyer borrow: " # e) } };

// net 0.2 BTC @ mid 100000 = 20000 cash. Settle at now=0 (same instant as the
// borrows) so no interest accrues — isolates the netting arithmetic.
let settled = LQ.settleNettedPair(nst, nacc, alice, bob, "BTC", 20_000_000, 10_000_000_000_000, vault, 0);
eqN("netting: USD settled = 20000", settled.cash, 2_000_000_000_000);
eqN("netting: base qty settled = 0.2", settled.qty, 20_000_000);
eqN("netting: seller BTC 1.0 → 0.8", Accounts.getBalance(nacc, alice, "BTC"), 80_000_000);
eqN("netting: seller ICPUSD debt 30k → 10k", BE.loanOf(nst, alice, QUOTE), 1_000_000_000_000);
eqN("netting: buyer ICPUSD 50k → 30k", Accounts.getBalance(nacc, bob, QUOTE), 3_000_000_000_000);
eqN("netting: buyer BTC debt 0.2 → 0", BE.loanOf(nst, bob, "BTC"), 0);
eqN("netting: vault absorbed 0.2 BTC", Accounts.getBalance(nacc, vault, "BTC"), 100_000_000); // 1.0 − 0.2 lent + 0.2 netted

// ── §1.3 regression battery: dust must never strand a liquidation ─────────
// docs/issue-triage-2026-08.md §1.3. Shape: a SHORT pool borrowed 2 BTC at
// $50k, sold it, and holds SOL; BTC is squeezed to $84k so health < 1.15.
// Each case plants a dust balance that the OLD pickCollateral preferred on
// `balance > 0` alone. Its derived repay floored to ZERO, writeOffLoan
// rejects a zero amount, and the driver did `break L` on the resulting #err —
// so the pool's REAL collateral was never examined, on every 30s sweep,
// forever, while absorbBadDebt never ran and the risk panel stayed green.
//
// The dust window is NOT "exactly one base unit". Seizing q ICPUSD base units
// against BTC at $84,000 gives grossDebtUnits = ⌊q / 84_000⌋ and then repays
// ⌊grossDebtUnits / 1.05⌋ — zero for EVERY q < 168_000, i.e. anything below
// $0.00168. That is twice the reported width, because the 5% penalty
// multiplier floors a second time. Reachable by accident, not just by attack.
func pxSqueeze(t : Types.TokenId) : ?Nat {
  switch (t) {
    case ("BTC") { ?8_400_000_000_000 };   // $84,000 — post-squeeze
    case ("SOL") { ?20_000_000_000 };      // $200
    case (_)     { null };
  };
};
func pxEntry(t : Types.TokenId) : ?Nat {
  switch (t) {
    case ("BTC") { ?5_000_000_000_000 };   // $50,000 — pre-squeeze
    case ("SOL") { ?20_000_000_000 };
    case (_)     { null };
  };
};

// alice shorts 2 BTC at $50k against `sol` SOL of collateral, then sells the
// borrowed BTC (balance zeroed — that is what makes the debt token one she no
// longer holds). Valued at pxSqueeze she is liquidatable.
func squeezedShort(sol : Nat) : (BE.LoanState, ME.MarginState, Accounts.AccountState) {
  let st = BE.emptyState(); let mg = ME.emptyState(); let acc = Accounts.emptyState();
  Accounts.setBalance(acc, vault, "BTC", 1_000_000_000);   // 10 BTC lendable (cap 5)
  switch (ME.open(mg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
  Accounts.setBalance(acc, alice, "SOL", sol);
  switch (BE.borrow(st, mg, acc, noReserved, vault, alice, "BTC", 200_000_000, 0, pxEntry)) {
    case (#ok(_)) {}; case (#err(e)) { Runtime.trap("short setup borrow: " # e) };
  };
  Accounts.setBalance(acc, alice, "BTC", 0);               // the short SOLD it
  (st, mg, acc);
};

// The property every dust case must satisfy: the driver walks PAST the dust
// and closes against the pool's real SOL collateral.
func mustLiquidateThroughDust(
  name : Text,
  st   : BE.LoanState,
  mg   : ME.MarginState,
  acc  : Accounts.AccountState,
) {
  truth(name # ": setup is liquidatable", BE.getHealth(st, mg, acc, noReserved, alice, pxSqueeze).isLiquidatable);
  let solBefore  = Accounts.getBalance(acc, alice, "SOL");
  let debtBefore = BE.loanOf(st, alice, "BTC");
  switch (LQ.tryLiquidate(st, mg, acc, noReserved, alice, vault, 1, pxSqueeze)) {
    case (#liquidated(ev)) {
      truth(name # ": seized the REAL collateral, not the dust", ev.collateralToken == "SOL");
    };
    case (#err(e)) { Runtime.trap("FAIL: " # name # " — driver stranded on dust: " # e) };
    case (#insolvent(_)) { Runtime.trap("FAIL: " # name # " — #insolvent despite 1000 SOL of seizable collateral") };
    case (#healthy) { Runtime.trap("FAIL: " # name # " — reported healthy while under maintenance") };
  };
  truth(name # ": SOL collateral actually moved", Accounts.getBalance(acc, alice, "SOL") < solBefore);
  truth(name # ": BTC debt reduced", BE.loanOf(st, alice, "BTC") < debtBefore);
  truth(name # ": health restored above maintenance",
    not BE.getHealth(st, mg, acc, noReserved, alice, pxSqueeze).isLiquidatable);
};

// Case 1 (headline) — ONE base unit of QUOTE_TOKEN dust beside 1000 SOL.
let (d1st, d1mg, d1acc) = squeezedShort(100_000_000_000);
Accounts.setBalance(d1acc, alice, QUOTE, 1);
mustLiquidateThroughDust("dust 1 unit ICPUSD", d1st, d1mg, d1acc);
eqN("dust 1 unit ICPUSD: dust left where it was (never seizable)", Accounts.getBalance(d1acc, alice, QUOTE), 1);

// Case 2 — dust just UNDER the whole-unit threshold ($0.00167999 vs $0.00168).
// The reporter thought the window was one base unit; it is everything below
// 168_000 units of ICPUSD against BTC at $84k.
let (d2st, d2mg, d2acc) = squeezedShort(100_000_000_000);
Accounts.setBalance(d2acc, alice, QUOTE, 167_999);
mustLiquidateThroughDust("dust just under threshold ($0.00168)", d2st, d2mg, d2acc);
eqN("dust just under threshold: dust left where it was", Accounts.getBalance(d2acc, alice, QUOTE), 167_999);

// Case 3 — the SECOND route: dust in the DEBT token itself, which
// pickCollateral's same-token first pass took on `balance > 0` alone.
let (d3st, d3mg, d3acc) = squeezedShort(100_000_000_000);
Accounts.setBalance(d3acc, alice, "BTC", 1);
mustLiquidateThroughDust("same-token dust (1 base unit of BTC)", d3st, d3mg, d3acc);
// ROLLBACK PROOF for the direct/same-token branch: it used to seize this unit
// and then return #err WITHOUT unwinding — silently confiscating it to the
// vault on every sweep, contradicting seizeOnce's own contract comment.
eqN("same-token dust: direct branch leaves the user's balance UNCHANGED", Accounts.getBalance(d3acc, alice, "BTC"), 1);

// Case 4 — pickCollateral ranks on value; QUOTE_TOKEN is no longer automatic.
// $10,000 of ICPUSD beside $200,000 of SOL: the old code took the ICPUSD
// (unconditional preference) and drained it. One SOL leg reaches target, so
// after the fix the ICPUSD is never touched at all.
let (d4st, d4mg, d4acc) = squeezedShort(100_000_000_000);
Accounts.setBalance(d4acc, alice, QUOTE, 1_000_000_000_000);   // $10,000
let d4SolBefore = Accounts.getBalance(d4acc, alice, "SOL");
truth("pickCollateral ranking: setup is liquidatable", BE.getHealth(d4st, d4mg, d4acc, noReserved, alice, pxSqueeze).isLiquidatable);
switch (LQ.tryLiquidate(d4st, d4mg, d4acc, noReserved, alice, vault, 1, pxSqueeze)) {
  case (#liquidated(ev)) { truth("pickCollateral ranking: primary collateral is SOL, not ICPUSD", ev.collateralToken == "SOL") };
  case (_) { Runtime.trap("FAIL: pickCollateral ranking — expected #liquidated") };
};
truth("pickCollateral ranking: seized the LARGER SOL holding", Accounts.getBalance(d4acc, alice, "SOL") < d4SolBefore);
eqN("pickCollateral ranking: the $10k ICPUSD was NOT preferred over $200k of SOL",
  Accounts.getBalance(d4acc, alice, QUOTE), 1_000_000_000_000);

// Case 5 — ONLY dust: the honest answer is #insolvent (so the caller's
// absorbBadDebt runs and the risk panel stops showing a solvent book), never
// a permanent #err loop, and nothing is confiscated on the way.
let (d5st, d5mg, d5acc) = squeezedShort(100_000_000_000);
Accounts.setBalance(d5acc, alice, "SOL", 0);
Accounts.setBalance(d5acc, alice, QUOTE, 1);
Accounts.setBalance(d5acc, alice, "BTC", 1);
truth("all-dust: setup is liquidatable", BE.getHealth(d5st, d5mg, d5acc, noReserved, alice, pxSqueeze).isLiquidatable);
switch (LQ.tryLiquidate(d5st, d5mg, d5acc, noReserved, alice, vault, 1, pxSqueeze)) {
  case (#insolvent(ev)) {
    eqN("all-dust: zero debt repaid", ev.debtRepaid, 0);
    eqN("all-dust: zero collateral seized", ev.collateralSeized, 0);
    Debug.print("  ✓ dust-only collateral → #insolvent (absorbBadDebt can run)");
  };
  case (#err(e)) { Runtime.trap("FAIL: all-dust — #err re-arms the same sweep forever: " # e) };
  case (_) { Runtime.trap("FAIL: all-dust — expected #insolvent") };
};
eqN("all-dust: same-token dust not confiscated", Accounts.getBalance(d5acc, alice, "BTC"), 1);
eqN("all-dust: quote dust not confiscated", Accounts.getBalance(d5acc, alice, QUOTE), 1);

// ── #insolvent must mean COLLATERAL exhausted, not BUDGET exhausted ───────
// A pass is bounded at MAX_SEIZE_ITERS seizes, which is a message-size bound —
// each iteration re-runs getHealth and walks the collateral set. The classifier
// used to read only the resulting health, so both terminal states that leave a
// user liquidatable collapsed to the same answer: "walked every collateral and
// none could move the debt" (genuinely insolvent) and "ran out of iterations
// mid-walk" (simply unfinished). The second one is expensive to get wrong:
// main.mo answers #insolvent with absorbBadDebt, which writes off EVERY
// remaining loan and socialises the residual to the insurance pool and then to
// AMM LPs — so a fully-collateralised position gets booked as a loss while the
// user keeps the collateral the pass never reached.
//
// The invariant, stated so it holds for any scenario rather than one tuned
// shape: #insolvent may only be returned when nothing seizable is left.
func insolventImpliesCollateralExhausted(
  name : Text,
  st   : BE.LoanState,
  mg   : ME.MarginState,
  acc  : Accounts.AccountState,
  pxf  : Types.TokenId -> ?Nat,
) {
  switch (LQ.tryLiquidate(st, mg, acc, noReserved, alice, vault, 1, pxf)) {
    case (#insolvent(_)) {
      // Value what the user still holds across the collateral basket. Anything
      // an iteration could have seized makes the write-off premature.
      var remainingUsd : Nat = 0;
      for (tok in Types.MARGIN_COLLATERAL_TOKENS.vals()) {
        let bal = Accounts.getBalance(acc, alice, tok);
        if (bal > 0) {
          // The quote is the unit of account, so it has no oracle entry.
          let p = if (tok == QUOTE) { 100_000_000 } else { Option.get(pxf(tok), 0) };
          remainingUsd += (bal * p) / 100_000_000;
        };
      };
      // A base unit or two of a cheap token cannot repay anything (that is the
      // §1.3 dust window, deliberately left alone). Anything of real value
      // means the pass gave up early and the caller is about to write off a
      // recoverable debt.
      if (remainingUsd > 100_000) {   // $0.001
        Runtime.trap(
          "FAIL: " # name # " — #insolvent while holding " # debug_show remainingUsd
          # " base-USD of seizable collateral; absorbBadDebt would write off recoverable debt"
        );
      };
      Debug.print("  ✓ " # name # ": #insolvent only with collateral genuinely exhausted");
    };
    case (#liquidated(_)) { Debug.print("  ✓ " # name # ": partial/complete close, no write-off") };
    case (#err(_))        { Debug.print("  ✓ " # name # ": transient #err, caller retries (no write-off)") };
    case (#healthy)       { Debug.print("  ✓ " # name # ": healthy") };
  };
};

// A portfolio spread thin across the whole collateral basket against debts in
// several tokens. Every seize is capped by the balance of the token it lands
// on, so no single iteration gets far and the walk needs more passes than the
// budget allows — the shape the bound was always going to meet in production.
func pxWide(t : Types.TokenId) : ?Nat {
  switch (t) {
    case ("BTC") { ?10_000_000_000_000 };  // $100,000
    case ("ETH") { ?300_000_000_000 };     // $3,000
    case ("SOL") { ?20_000_000_000 };      // $200
    case ("ICP") { ?1_000_000_000 };       // $10
    case (_)     { null };
  };
};
func pxWideCrash(t : Types.TokenId) : ?Nat {
  switch (t) {
    case ("BTC") { ?6_000_000_000_000 };   // $60,000
    case ("ETH") { ?180_000_000_000 };     // $1,800
    case ("SOL") { ?12_000_000_000 };      // $120
    case ("ICP") { ?600_000_000 };         // $6
    case (_)     { null };
  };
};

func spreadPortfolio() : (BE.LoanState, ME.MarginState, Accounts.AccountState) {
  let st = BE.emptyState(); let mg = ME.emptyState(); let acc = Accounts.emptyState();
  Accounts.setBalance(acc, vault, QUOTE, 100_000_000_000_000);
  Accounts.setBalance(acc, vault, "BTC", 1_000_000_000);
  Accounts.setBalance(acc, vault, "ETH", 100_000_000_000);
  Accounts.setBalance(acc, vault, "SOL", 100_000_000_000);
  Accounts.setBalance(acc, vault, "ICP", 100_000_000_000);
  switch (ME.open(mg, alice, 0)) { case (#ok(_)) {}; case (#err(e)) { Runtime.trap(e) } };
  // Collateral spread across all five basket tokens.
  Accounts.setBalance(acc, alice, "BTC",  20_000_000);        // 0.2 BTC = $20,000
  Accounts.setBalance(acc, alice, "ETH", 500_000_000);        // 5 ETH   = $15,000
  Accounts.setBalance(acc, alice, "SOL", 5_000_000_000);      // 50 SOL  = $10,000
  Accounts.setBalance(acc, alice, "ICP", 50_000_000_000);     // 500 ICP = $5,000
  Accounts.setBalance(acc, alice, QUOTE, 500_000_000_000);    // $5,000
  // Debts in several tokens, each small enough that clearing one barely moves
  // overall health.
  for (spec in [("ETH", 100_000_000), ("SOL", 1_000_000_000), ("ICP", 10_000_000_000)].vals()) {
    switch (BE.borrow(st, mg, acc, noReserved, vault, alice, spec.0, spec.1, 0, pxWide)) {
      case (#ok(_)) {}; case (#err(e)) { Runtime.trap("spread setup borrow " # spec.0 # ": " # e) };
    };
  };
  switch (BE.borrow(st, mg, acc, noReserved, vault, alice, QUOTE, 2_500_000_000_000, 0, pxWide)) {
    case (#ok(_)) {}; case (#err(e)) { Runtime.trap("spread setup borrow quote: " # e) };
  };
  // The borrowed tokens were sold on, which is what leaves the debts standing
  // against a basket that no longer contains their proceeds. Without this the
  // loans would fund themselves and the position could never go underwater.
  Accounts.setBalance(acc, alice, "ETH", 500_000_000);
  Accounts.setBalance(acc, alice, "SOL", 5_000_000_000);
  Accounts.setBalance(acc, alice, "ICP", 50_000_000_000);
  Accounts.setBalance(acc, alice, QUOTE, 500_000_000_000);
  (st, mg, acc);
};

let (wst, wmg, wacc) = spreadPortfolio();
truth("spread portfolio: liquidatable after the crash",
      BE.getHealth(wst, wmg, wacc, noReserved, alice, pxWideCrash).isLiquidatable);
insolventImpliesCollateralExhausted("spread portfolio", wst, wmg, wacc, pxWideCrash);

// The same invariant on the shapes already exercised above, so a future change
// to the seize walk cannot quietly reintroduce a premature write-off on any of
// them.
let (i1st, i1mg, i1acc) = squeezedShort(100_000_000_000);
insolventImpliesCollateralExhausted("squeezed short with real SOL", i1st, i1mg, i1acc, pxSqueeze);
let (i2st, i2mg, i2acc) = liquidatableAlice();
insolventImpliesCollateralExhausted("crashed long", i2st, i2mg, i2acc, pxCrash);

// The budget itself is a message-size bound and nothing else: it must never be
// read as a solvency signal. Pinned so a future tuning of the number cannot
// silently change what exhausting it MEANS.
truth("seize budget is a positive message-size bound", LQ.MAX_SEIZE_ITERS > 0);

// The decision itself, over all four terminal states. Driving the seize loop
// to its bound end-to-end needs a portfolio shape that is both fiddly to build
// and easy to invalidate with any change to the seize sizing, so the classifier
// is asserted directly — this is the line that decides whether main.mo calls
// absorbBadDebt, and it should be pinned by something a refactor cannot make
// vacuous.
let evt : Types.LiquidationEvent = {
  user = alice; debtToken = QUOTE; debtRepaid = 1; debtRepaidUsd = 1;
  collateralToken = "BTC"; collateralSeized = 1; proceedsUsd = 1; penaltyUsd = 0;
  healthBefore = 100_000_000; healthAfter = 110_000_000; timestamp = 1;
};
func classifiesAs(name : Text, stillLiq : Bool, exhausted : Bool, wantInsolvent : Bool) {
  switch (LQ.classifySeizingPass(stillLiq, exhausted, evt)) {
    case (#insolvent(_)) {
      if (not wantInsolvent) { Runtime.trap("FAIL: " # name # " — got #insolvent, expected #liquidated") };
    };
    case (#liquidated(_)) {
      if (wantInsolvent) { Runtime.trap("FAIL: " # name # " — got #liquidated, expected #insolvent") };
    };
    case (_) { Runtime.trap("FAIL: " # name # " — a seizing pass must report #liquidated or #insolvent") };
  };
  Debug.print("  ✓ " # name);
};
// Collateral walked out, user still under water: the only state that justifies
// socialising the loss.
classifiesAs("still liquidatable, budget intact → #insolvent", true, false, true);
// The defect: the walk was cut short, so nothing has been established about
// the collateral and the debt must NOT be written off.
classifiesAs("still liquidatable, budget EXHAUSTED → #liquidated (no write-off)", true, true, false);
// Healthy again — how the loop ended is immaterial.
classifiesAs("restored to health, budget intact → #liquidated", false, false, false);
classifiesAs("restored to health, budget exhausted → #liquidated", false, true, false);

Debug.print("── Liquidator.test PASSED ──");
