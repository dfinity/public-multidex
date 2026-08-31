// Pure-function unit tests for src/backend/lib/MatchingEngine.mo in integer base
// units (10^8). Pins: an empty book fills nothing; a market buy walks resting
// asks best-price-first, produces the right trades + VWAP, fully settles both
// sides' balances; and the slippage cap stops the walk at the price bound. (The
// protected / deferred path is integration-exercised by the sim.)
// Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8; slippage frac ×10^8.

import MX "../src/backend/lib/MatchingEngine";
import OB "../src/backend/lib/OrderBook";
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
let QUOTE = Types.QUOTE_TOKEN;
let mkt = "BTC-ICPUSD";
let base = "BTC";
let alice = Principal.fromText("2vxsx-fae"); // maker
let bob   = Principal.fromText("aaaaa-aa");   // taker

Debug.print("── MatchingEngine.test ──");

// ── Empty book → nothing fills ──
let s0 = OB.emptyStore();
let a0 = Accounts.emptyState();
Accounts.setBalance(a0, bob, QUOTE, 100_000_000_000);  // 1000 ICPUSD
let r0 = MX.executeMarketOrder(s0, a0, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 1); // buy 1 @ 10%
eqN("empty book: nothing filled", r0.totalFilled, 0);
eqN("empty book: remaining = qty", r0.remainingQty, 100_000_000);
truth("empty book: no trades", r0.trades.size() == 0);

// ── Market buy walks best-price-first; VWAP; full settlement ──
// Book: alice rests 2 BTC @ 100 and 1 BTC @ 101. bob buys 2.5 BTC @ 10% slippage.
let s = OB.emptyStore();
let acc = Accounts.emptyState();
Accounts.setBalance(acc, alice, base, 500_000_000);     // 5 BTC
Accounts.setBalance(acc, bob, QUOTE, 100_000_000_000);  // 1000 ICPUSD
ignore OB.createOrder(s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
ignore OB.createOrder(s, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2); // 1 @ 101
let r = MX.executeMarketOrder(s, acc, mkt, base, bob, #buy, 250_000_000, 10_000_000, false, 3); // buy 2.5 @ 10%
eqN("fill: totalFilled = 2.5", r.totalFilled, 250_000_000);
eqN("fill: VWAP = (2×100 + 0.5×101)/2.5 = 100.2", r.avgPrice, 10_020_000_000);
truth("fill: two trades (100 then 101)", r.trades.size() == 2);
eqN("fill: nothing left over", r.remainingQty, 0);
// settlement (cost = 2×100 + 0.5×101 = 250.5 = 25_050_000_000)
eqN("settle: bob received 2.5 BTC", Accounts.getBalance(acc, bob, base), 250_000_000);
eqN("settle: bob paid 250.5 ICPUSD", Accounts.getBalance(acc, bob, QUOTE), 100_000_000_000 - 25_050_000_000);
eqN("settle: alice delivered 2.5 BTC", Accounts.getBalance(acc, alice, base), 500_000_000 - 250_000_000);
eqN("settle: alice received 250.5 ICPUSD", Accounts.getBalance(acc, alice, QUOTE), 25_050_000_000);

// ── Slippage cap stops the walk ──
// Same book, but 0% slippage → maxPrice = best (100); the 101 level is skipped.
let s2 = OB.emptyStore();
let acc2 = Accounts.emptyState();
Accounts.setBalance(acc2, alice, base, 500_000_000);
Accounts.setBalance(acc2, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(s2, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1);
ignore OB.createOrder(s2, mkt, alice, #sell, #limit, 10_100_000_000, 100_000_000, 2);
let r2 = MX.executeMarketOrder(s2, acc2, mkt, base, bob, #buy, 250_000_000, 0, false, 3); // 0% slippage
eqN("slippage 0: fills only the 100 level (2.0)", r2.totalFilled, 200_000_000);
eqN("slippage 0: 0.5 left unfilled", r2.remainingQty, 50_000_000);

// ════════════════════════════════════════════════════════════════════
// noPartialFill (fill-or-kill) pre-check — exercises simulateAvailableFill,
// which walks levelsByMarketSide best→worst and either confirms the FULL
// quantity is fillable or returns an empty result (kill) WITHOUT settling.
// Previously untested; pins the O(book) level-walk rewrite (was O(book²)).
// ════════════════════════════════════════════════════════════════════
Debug.print("── FOK / noPartialFill ──");

// A) KILL — insufficient depth: book holds 2 BTC, FOK wants 3 → kill, no settle.
let fa_s = OB.emptyStore();
let fa_a = Accounts.emptyState();
Accounts.setBalance(fa_a, alice, base, 500_000_000);          // 5 BTC maker
Accounts.setBalance(fa_a, bob, QUOTE, 100_000_000_000);       // 1000 ICPUSD taker (plenty)
ignore OB.createOrder(fa_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
let fa_r = MX.executeMarketOrder(fa_s, fa_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK kill (thin book): nothing filled", fa_r.totalFilled, 0);
eqN("FOK kill (thin book): remaining = full qty", fa_r.remainingQty, 300_000_000);
truth("FOK kill (thin book): no trades", fa_r.trades.size() == 0);
eqN("FOK kill: taker quote untouched", Accounts.getBalance(fa_a, bob, QUOTE), 100_000_000_000);
eqN("FOK kill: maker base untouched", Accounts.getBalance(fa_a, alice, base), 500_000_000);

// B) PASS — multi-level: 2 @ 100 + 2 @ 101, FOK 3 → fills across both levels.
let fb_s = OB.emptyStore();
let fb_a = Accounts.emptyState();
Accounts.setBalance(fb_a, alice, base, 500_000_000);
Accounts.setBalance(fb_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(fb_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
ignore OB.createOrder(fb_s, mkt, alice, #sell, #limit, 10_100_000_000, 200_000_000, 2); // 2 @ 101
let fb_r = MX.executeMarketOrder(fb_s, fb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 3); // FOK buy 3
eqN("FOK pass (multi-level): filled full 3", fb_r.totalFilled, 300_000_000);
eqN("FOK pass (multi-level): nothing left", fb_r.remainingQty, 0);
truth("FOK pass (multi-level): two trades", fb_r.trades.size() == 2);
eqN("FOK pass (multi-level): taker received 3 BTC", Accounts.getBalance(fb_a, bob, base), 300_000_000);

// C) KILL — slippage band hides deeper liquidity: 1 @ 100 + 5 @ 101, FOK 3 @ 0% slip.
let fc_s = OB.emptyStore();
let fc_a = Accounts.emptyState();
Accounts.setBalance(fc_a, alice, base, 1_000_000_000);
Accounts.setBalance(fc_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(fc_s, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1); // 1 @ 100
ignore OB.createOrder(fc_s, mkt, alice, #sell, #limit, 10_100_000_000, 500_000_000, 2); // 5 @ 101 (out of band)
let fc_r = MX.executeMarketOrder(fc_s, fc_a, mkt, base, bob, #buy, 300_000_000, 0, true, 3); // FOK buy 3 @ 0% slip
eqN("FOK kill (band): nothing filled", fc_r.totalFilled, 0);
truth("FOK kill (band): no trades", fc_r.trades.size() == 0);
eqN("FOK kill (band): taker quote untouched", Accounts.getBalance(fc_a, bob, QUOTE), 100_000_000_000);

// D) KILL — balance can't afford the FULL size: 5 @ 100, FOK 3, taker holds 250 (<300).
let fd_s = OB.emptyStore();
let fd_a = Accounts.emptyState();
Accounts.setBalance(fd_a, alice, base, 500_000_000);
Accounts.setBalance(fd_a, bob, QUOTE, 25_000_000_000);  // 250 ICPUSD (3@100 costs 300)
ignore OB.createOrder(fd_s, mkt, alice, #sell, #limit, 10_000_000_000, 500_000_000, 1); // 5 @ 100
let fd_r = MX.executeMarketOrder(fd_s, fd_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK kill (balance): nothing filled", fd_r.totalFilled, 0);
eqN("FOK kill (balance): taker quote untouched", Accounts.getBalance(fd_a, bob, QUOTE), 25_000_000_000);

// E) PASS — exact balance: 5 @ 100, FOK 3, taker holds exactly 300.
let fe_s = OB.emptyStore();
let fe_a = Accounts.emptyState();
Accounts.setBalance(fe_a, alice, base, 500_000_000);
Accounts.setBalance(fe_a, bob, QUOTE, 30_000_000_000);  // 300 ICPUSD exactly
ignore OB.createOrder(fe_s, mkt, alice, #sell, #limit, 10_000_000_000, 500_000_000, 1); // 5 @ 100
let fe_r = MX.executeMarketOrder(fe_s, fe_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2); // FOK buy 3
eqN("FOK pass (exact balance): filled 3", fe_r.totalFilled, 300_000_000);
eqN("FOK pass (exact balance): taker spent all 300", Accounts.getBalance(fe_a, bob, QUOTE), 0);
eqN("FOK pass (exact balance): taker got 3 BTC", Accounts.getBalance(fe_a, bob, base), 300_000_000);

// F) KILL — sell-side FOK against thin bids (exercises the #sell / descending walk).
let ff_s = OB.emptyStore();
let ff_a = Accounts.emptyState();
Accounts.setBalance(ff_a, alice, QUOTE, 100_000_000_000);  // bid maker funded
Accounts.setBalance(ff_a, bob, base, 500_000_000);          // taker holds 5 BTC
ignore OB.createOrder(ff_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1); // bid 1 @ 100
let ff_r = MX.executeMarketOrder(ff_s, ff_a, mkt, base, bob, #sell, 300_000_000, 10_000_000, true, 2); // FOK sell 3
eqN("FOK sell kill (thin bids): nothing filled", ff_r.totalFilled, 0);
eqN("FOK sell kill: taker base untouched", Accounts.getBalance(ff_a, bob, base), 500_000_000);

// ════════════════════════════════════════════════════════════════════
// Symmetric maker/taker fee + self-trade prevention. The engine fees BOTH legs
// in QUOTE — buyer pays C+buyerFee, seller receives C-sellerFee, treasury gets
// both — keyed off MAKER(resting) vs TAKER(incoming), NOT buy/sell. STP makes a
// taker skip + cancel its OWN resting maker. Test rates: MAKER=5 bps, TAKER=10.
// ════════════════════════════════════════════════════════════════════
Debug.print("── symmetric maker/taker fee + STP ──");
let treas = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"); // stand-in treasury

// Beneficial-owner resolver — the test's stand-in for main.mo's archiveOwnerOf:
// a margin pool's derived principal resolves to the POOL'S OWNER, every other
// principal to itself. EVERY ctx below routes STP through this, so the plain
// alice-vs-alice case is a genuine resolver miss (not a hardcoded identity) and
// the sibling-pool cases can only pass if the engine compares BENEFICIARIES
// rather than raw principals. carol owns two pools; dave owns one.
let carol  = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let dave   = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
let poolC1 = Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai");  // carol's pool #1
let poolC2 = Principal.fromText("qoctq-giaaa-aaaaa-aaaea-cai");  // carol's pool #2
let poolD1 = Principal.fromText("renrk-eyaaa-aaaaa-aaada-cai");  // dave's pool
func beneficial(p : Principal) : Principal {
  if (Principal.equal(p, poolC1) or Principal.equal(p, poolC2)) { carol }
  else if (Principal.equal(p, poolD1)) { dave }
  else { p };
};

// A ctx mirroring the real engine contract: quoteFee is PURE (role→bps→floor),
// creditTreasury skims the combined fee to `treas`, onSelfTrade cancels the
// resting self-maker (as cancelSelfMaker does in main.mo) and reports its id.
func mkFeeCtx(acc : Accounts.AccountState, store : OB.OrderStore, onCancel : (Nat) -> ()) : MX.ProtectionCtx = {
  getMakerWindow   = func(_) { 0 };
  getMakerPending  = func(_) { 0 };
  availableBalance = func(p, t) { Accounts.getBalance(acc, p, t) };
  isNonTakeable    = func(_, _) { false };
  aggressorIsMaker = false;
  onUnfundedMaker  = func(_, _, _, _, _) {};
  isExpired        = func(_) { false };
  onPendingFill    = func(_, _, _, _, _, _, _) { null };
  quoteFee         = func(_p, gross, role) {
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000   // floor — == Fixed.mulDiv(gross, bps, 10_000, false)
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(acc, treas, QUOTE, fee) } };
  onSelfTrade      = func(id, _owner) { ignore OB.cancelOrder(store, id); onCancel(id) };
  beneficialOwner  = beneficial;   // pools → their owner; everyone else → themselves
  onTradeFees      = func(_, _, _) {};
};

// ── (1) BUY fill: taker=buyer pays TAKER(10 bps); maker=seller pays MAKER(5 bps).
//        Buyer funded with EXACTLY C+takerFee (zero headroom) — pins the
//        reservation/affordability gate. C=100 ICPUSD=10_000_000_000. ──
let sb_s = OB.emptyStore();
let sb_a = Accounts.emptyState();
Accounts.setBalance(sb_a, alice, base, 100_000_000);            // 1 BTC maker (seller)
Accounts.setBalance(sb_a, bob, QUOTE, 10_010_000_000);          // C + takerFee, ZERO headroom
ignore OB.createOrder(sb_s, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let sb_before = Accounts.getBalance(sb_a, alice, QUOTE) + Accounts.getBalance(sb_a, bob, QUOTE) + Accounts.getBalance(sb_a, treas, QUOTE);
let sb_r = MX.executeMarketOrderProtected(sb_s, sb_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 2, mkFeeCtx(sb_a, sb_s, func(_) {}), null);
eqN("buyfee: filled 1 BTC at zero headroom (gate holds)", sb_r.totalFilled, 100_000_000);
eqN("buyfee: buyer paid C+takerFee → 0", Accounts.getBalance(sb_a, bob, QUOTE), 0);
eqN("buyfee: buyer got 1 BTC", Accounts.getBalance(sb_a, bob, base), 100_000_000);
eqN("buyfee: seller got C-makerFee (9_995_000_000)", Accounts.getBalance(sb_a, alice, QUOTE), 9_995_000_000);
eqN("buyfee: treasury got takerFee+makerFee (15_000_000)", Accounts.getBalance(sb_a, treas, QUOTE), 15_000_000);
eqN("buyfee: Σ QUOTE conserved", Accounts.getBalance(sb_a, alice, QUOTE) + Accounts.getBalance(sb_a, bob, QUOTE) + Accounts.getBalance(sb_a, treas, QUOTE), sb_before);

// ── (2) SELL fill: rate keys off ROLE, NOT side. taker=seller pays TAKER(10);
//        maker=buyer pays MAKER(5). The maker-buyer's QUOTE debit is C+makerFee. ──
let fs_s = OB.emptyStore();
let fs_a = Accounts.emptyState();
Accounts.setBalance(fs_a, alice, QUOTE, 10_005_000_000);        // maker buyer: C + makerFee
Accounts.setBalance(fs_a, bob, base, 100_000_000);             // taker seller: 1 BTC
ignore OB.createOrder(fs_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1);
let fs_before = Accounts.getBalance(fs_a, alice, QUOTE) + Accounts.getBalance(fs_a, bob, QUOTE) + Accounts.getBalance(fs_a, treas, QUOTE);
let fs_r = MX.executeMarketOrderProtected(fs_s, fs_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, false, 3, mkFeeCtx(fs_a, fs_s, func(_) {}), null);
eqN("sellfee: filled 1 BTC", fs_r.totalFilled, 100_000_000);
eqN("sellfee: maker-buyer paid C+makerFee → 0", Accounts.getBalance(fs_a, alice, QUOTE), 0);
eqN("sellfee: maker-buyer got 1 BTC", Accounts.getBalance(fs_a, alice, base), 100_000_000);
eqN("sellfee: taker-seller got C-takerFee (9_990_000_000)", Accounts.getBalance(fs_a, bob, QUOTE), 9_990_000_000);
eqN("sellfee: treasury got makerFee+takerFee (15_000_000)", Accounts.getBalance(fs_a, treas, QUOTE), 15_000_000);
eqN("sellfee: Σ QUOTE conserved", Accounts.getBalance(fs_a, alice, QUOTE) + Accounts.getBalance(fs_a, bob, QUOTE) + Accounts.getBalance(fs_a, treas, QUOTE), fs_before);

// ── (3) Self-trade prevention: alice market-sells into her OWN resting bid →
//        no fill, the resting bid is cancelled, her balances are untouched. ──
let st_s = OB.emptyStore();
let st_a = Accounts.emptyState();
Accounts.setBalance(st_a, alice, QUOTE, 10_005_000_000);        // funds her resting bid
Accounts.setBalance(st_a, alice, base, 100_000_000);           // and the base she'd sell
let st_bid = OB.createOrder(st_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1);
var st_cancelled : Nat = 0;
let st_r = MX.executeMarketOrderProtected(st_s, st_a, mkt, base, alice, #sell, 100_000_000, 10_000_000, false, 4, mkFeeCtx(st_a, st_s, func(id) { st_cancelled := id }), null);
eqN("stp: no self-fill (totalFilled 0)", st_r.totalFilled, 0);
truth("stp: no trade recorded", st_r.trades.size() == 0);
eqN("stp: onSelfTrade cancelled the resting bid", st_cancelled, st_bid.id);
eqN("stp: alice QUOTE untouched", Accounts.getBalance(st_a, alice, QUOTE), 10_005_000_000);
eqN("stp: alice base untouched", Accounts.getBalance(st_a, alice, base), 100_000_000);

// ── (3b) STP on the BENEFICIAL owner — DIFFERENT principals, SAME owner.
//        carol's pool C2 market-sells into carol's pool C1's resting bid. The
//        raw principals differ, so a Principal.equal(taker, maker) check lets
//        this cross print; only the beneficialOwner comparison stops it. This
//        is the exact case beneficialOwner was introduced for (9e418f7) — a
//        margin pool is a sub-account, so a wallet crossing its own pool is one
//        party on both sides of the print. ──
let bp_s = OB.emptyStore();
let bp_a = Accounts.emptyState();
Accounts.setBalance(bp_a, poolC1, QUOTE, 10_005_000_000);      // funds C1's resting bid
Accounts.setBalance(bp_a, poolC2, base, 100_000_000);          // C2's base to sell
let bp_bid = OB.createOrder(bp_s, mkt, poolC1, #buy, #limit, 10_000_000_000, 100_000_000, 1);
var bp_cancelled : Nat = 0;
let bp_r = MX.executeMarketOrderProtected(bp_s, bp_a, mkt, base, poolC2, #sell, 100_000_000, 10_000_000, false, 2, mkFeeCtx(bp_a, bp_s, func(id) { bp_cancelled := id }), null);
truth("stp beneficial: the two sides really ARE different principals", not Principal.equal(poolC1, poolC2));
truth("stp beneficial: ...resolving to the SAME beneficiary", Principal.equal(beneficial(poolC1), beneficial(poolC2)));
eqN("stp beneficial: sibling-pool cross does not fill", bp_r.totalFilled, 0);
truth("stp beneficial: no trade recorded (no washed volume)", bp_r.trades.size() == 0);
eqN("stp beneficial: onSelfTrade cancelled the sibling's resting bid", bp_cancelled, bp_bid.id);
eqN("stp beneficial: C1 QUOTE untouched", Accounts.getBalance(bp_a, poolC1, QUOTE), 10_005_000_000);
eqN("stp beneficial: C2 base untouched", Accounts.getBalance(bp_a, poolC2, base), 100_000_000);

// ── (3c) Control for (3b): DIFFERENT beneficial owners still cross normally,
//        so (3b) cannot be passing because the resolver collapses every pool
//        onto one beneficiary. dave's pool D1 takes carol's pool C1's bid —
//        a genuine fill, fee'd exactly like the sellfee case (pools are
//        fee-bearing). ──
let bx_s = OB.emptyStore();
let bx_a = Accounts.emptyState();
Accounts.setBalance(bx_a, poolC1, QUOTE, 10_005_000_000);      // maker-buyer: C + makerFee
Accounts.setBalance(bx_a, poolD1, base, 100_000_000);          // taker-seller: 1 BTC
ignore OB.createOrder(bx_s, mkt, poolC1, #buy, #limit, 10_000_000_000, 100_000_000, 1);
var bx_cancelled : Nat = 0;
let bx_r = MX.executeMarketOrderProtected(bx_s, bx_a, mkt, base, poolD1, #sell, 100_000_000, 10_000_000, false, 2, mkFeeCtx(bx_a, bx_s, func(id) { bx_cancelled := id }), null);
truth("stp control: different owners → different beneficiaries", not Principal.equal(beneficial(poolC1), beneficial(poolD1)));
eqN("stp control: pools of DIFFERENT owners do cross", bx_r.totalFilled, 100_000_000);
eqN("stp control: onSelfTrade never fired", bx_cancelled, 0);
eqN("stp control: taker-seller got C-takerFee", Accounts.getBalance(bx_a, poolD1, QUOTE), 9_990_000_000);
eqN("stp control: maker-buyer paid C+makerFee → 0", Accounts.getBalance(bx_a, poolC1, QUOTE), 0);

// ── (3d) The FOK pre-check resolves beneficiaries too — simulateAvailableFill
//        is the SECOND beneficialOwner call site, and it must agree with the
//        live loop: a sibling pool's depth cannot count toward an
//        all-or-nothing fill, or FOK passes its pre-check and then partially
//        fills. The pre-check is a pure simulation and kills before the match
//        loop, so it never reaches onSelfTrade — the sibling's bid still rests. ──
let bk_s = OB.emptyStore();
let bk_a = Accounts.emptyState();
Accounts.setBalance(bk_a, poolC1, QUOTE, 100_000_000_000);
Accounts.setBalance(bk_a, poolC2, base, 100_000_000);
let bk_bid = OB.createOrder(bk_s, mkt, poolC1, #buy, #limit, 10_000_000_000, 100_000_000, 1);
let bk_r = MX.executeMarketOrderProtected(bk_s, bk_a, mkt, base, poolC2, #sell, 100_000_000, 10_000_000, true, 2, mkFeeCtx(bk_a, bk_s, func(_) {}), null);
eqN("stp FOK: sibling-pool depth is not fillable → kill", bk_r.totalFilled, 0);
truth("stp FOK: no trades", bk_r.trades.size() == 0);
eqN("stp FOK: taker base untouched", Accounts.getBalance(bk_a, poolC2, base), 100_000_000);
truth("stp FOK: killed in the pre-check — sibling's bid still rests",
  switch (OB.getOrder(bk_s, bk_bid.id)) { case (?o) { OB.isOpen(o) }; case null { false } });

// ── (4) EXEMPT counterparty (the pool-vs-AMM case): a fee-bearing taker buys from
//        an EXEMPT maker (AMM/insurance/treasury). Only the taker leg is fee'd — the
//        exempt seller keeps the FULL tradeCost, treasury gets just the taker fee.
//        This is what un-exempting margin pools relies on: a pool buying AMM
//        liquidity pays its fee while the AMM's economics are untouched. (Both-non-
//        exempt — pool-vs-user / pool-vs-pool — is the buyfee/sellfee case above.) ──
let ex_s = OB.emptyStore();
let ex_a = Accounts.emptyState();
let ammP = Principal.fromText("mxzaz-hqaaa-aaaar-qaada-cai");  // stand-in EXEMPT principal (AMM)
Accounts.setBalance(ex_a, ammP, base, 100_000_000);            // exempt maker (seller)
Accounts.setBalance(ex_a, bob, QUOTE, 10_010_000_000);         // taker (buyer): C + takerFee
ignore OB.createOrder(ex_s, mkt, ammP, #sell, #limit, 10_000_000_000, 100_000_000, 1);
let ex_ctx : MX.ProtectionCtx = {
  getMakerWindow   = func(_) { 0 };
  getMakerPending  = func(_) { 0 };
  availableBalance = func(p, t) { Accounts.getBalance(ex_a, p, t) };
  isNonTakeable    = func(_, _) { false };
  aggressorIsMaker = false;
  onUnfundedMaker  = func(_, _, _, _, _) {};
  isExpired        = func(_) { false };
  onPendingFill    = func(_, _, _, _, _, _, _) { null };
  quoteFee         = func(p, gross, role) {
    if (Principal.equal(p, ammP)) { return 0 };   // exempt party → no fee on its leg
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(ex_a, treas, QUOTE, fee) } };
  onSelfTrade      = func(_, _) {};
  beneficialOwner  = beneficial;
  onTradeFees      = func(_, _, _) {};
};
let ex_before = Accounts.getBalance(ex_a, ammP, QUOTE) + Accounts.getBalance(ex_a, bob, QUOTE) + Accounts.getBalance(ex_a, treas, QUOTE);
let ex_r = MX.executeMarketOrderProtected(ex_s, ex_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 5, ex_ctx, null);
eqN("exempt-cpty: filled 1 BTC", ex_r.totalFilled, 100_000_000);
eqN("exempt-cpty: taker paid C+takerFee → 0", Accounts.getBalance(ex_a, bob, QUOTE), 0);
eqN("exempt-cpty: AMM seller kept FULL tradeCost (no maker fee)", Accounts.getBalance(ex_a, ammP, QUOTE), 10_000_000_000);
eqN("exempt-cpty: treasury got ONLY the taker fee (10_000_000)", Accounts.getBalance(ex_a, treas, QUOTE), 10_000_000);
eqN("exempt-cpty: Σ QUOTE conserved", Accounts.getBalance(ex_a, ammP, QUOTE) + Accounts.getBalance(ex_a, bob, QUOTE) + Accounts.getBalance(ex_a, treas, QUOTE), ex_before);

// ── (5) Origin-type threading + IOC market releases (the Calm-Bear-91 bug):
//        a #market execution must (a) stamp takerOrderType = #market on its
//        trades, (b) return a #market order record covering ONLY the filled
//        portion (closed, never resting), and (c) leave NO remainder on the
//        book — the caller re-defers it. A dry #market cycle records nothing.
//        #limit keeps the resting behavior. ──
let io_s = OB.emptyStore();
let io_a = Accounts.emptyState();
Accounts.setBalance(io_a, alice, base, 50_000_000);              // maker: 0.5 BTC
Accounts.setBalance(io_a, bob, QUOTE, 100_000_000_000);          // taker: 1000 ICPUSD
ignore OB.createOrder(io_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1); // 0.5 @ 100
let (io_o, io_t, _, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #market, 11_000_000_000, 200_000_000, 2, 2, // MARKET buy 2, cap 110
  mkFeeCtx(io_a, io_s, func(_) {}), null
);
truth("IOC: trade stamped takerOrderType = #market", io_t.size() == 1 and io_t[0].takerOrderType == ?#market);
truth("IOC: returned order is #market", io_o.orderType == #market);
eqN("IOC: order records ONLY the filled portion", io_o.quantity, 50_000_000);
eqN("IOC: order.filled = filled portion (caller derives remainder)", io_o.filled, 50_000_000);
truth("IOC: order is CLOSED (#filled), never resting", io_o.status == #filled);
truth("IOC: NO remainder resting on the book (no bid appeared)",
  OB.findBestMatch(io_s, mkt, #sell) == null);   // a seller would match the best BID — none
eqN("IOC: single-fill price = the fill's price (VWAP), NOT the 110 cap", io_o.price, 10_000_000_000);

// Dry market cycle: nothing filled → synthetic id-0 record, store untouched.
let (dry_o, dry_t, _, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #market, 11_000_000_000, 100_000_000, 3, 3,
  mkFeeCtx(io_a, io_s, func(_) {}), null
);
truth("IOC dry: no trades", dry_t.size() == 0);
eqN("IOC dry: synthetic id 0 (never enters the store)", dry_o.id, 0);
truth("IOC dry: nothing recorded in the store", OB.getOrder(io_s, 0) == null);
// Zero-fill sentinel pinned EXACTLY (task 1787182538 rider 2): the synthetic
// keeps the cap as its price and #cancelled as its status, and — because it
// never enters the store — the reaper never seals a ClosedOrderRecord from it.
eqN("IOC dry: sentinel keeps the cap price (unchanged)", dry_o.price, 11_000_000_000);
truth("IOC dry: sentinel status #cancelled (unchanged)", dry_o.status == #cancelled);

// ── #market record price = VWAP of its fills, not the slippage cap
//    (task 1787182538, 2026-08-20). The record executeLimitOrderProtected's
//    #market branch creates is what the closed-order reaper later seals as
//    ClosedOrderRecord.price — stamp it with the volume-weighted execution
//    price of the immediate fills. Two-level walk, exact e8 arithmetic:
//    2 @ 100 + 0.5 @ 101, cap 110 → VWAP = (2×100 + 0.5×101)/2.5 = 100.2. ──
Debug.print("── #market record price = VWAP of fills, not the slippage cap ──");
let vw_s = OB.emptyStore();
let vw_a = Accounts.emptyState();
Accounts.setBalance(vw_a, alice, base, 250_000_000);             // maker: 2.5 BTC
Accounts.setBalance(vw_a, bob, QUOTE, 100_000_000_000);          // taker: 1000 ICPUSD
ignore OB.createOrder(vw_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
ignore OB.createOrder(vw_s, mkt, alice, #sell, #limit, 10_100_000_000,  50_000_000, 2); // 0.5 @ 101
let (vw_o, vw_t, _, _, _) = MX.executeLimitOrderProtected(
  vw_s, vw_a, mkt, base, bob, #buy, #market, 11_000_000_000, 250_000_000, 3, 3, // MARKET buy 2.5, cap 110
  mkFeeCtx(vw_a, vw_s, func(_) {}), null
);
truth("VWAP: two fills across two levels", vw_t.size() == 2);
eqN("VWAP: filled the full 2.5", vw_o.filled, 250_000_000);
eqN("VWAP: price = (2×100 + 0.5×101)/2.5 = 100.2, NOT the 110 cap", vw_o.price, 10_020_000_000);
truth("VWAP: the STORED record carries it too (the reaper seals o.price)",
  (switch (OB.getOrder(vw_s, vw_o.id)) { case (?o) { o.price == 10_020_000_000 }; case null { false } }));

// Control: a #limit execution with a remainder still RESTS (unchanged semantics).
let (lm_o, _, _, _, _) = MX.executeLimitOrderProtected(
  io_s, io_a, mkt, base, bob, #buy, #limit, 9_000_000_000, 100_000_000, 4, 4,  // passive bid @ 90
  mkFeeCtx(io_a, io_s, func(_) {}), null
);
truth("limit control: remainder rests open", lm_o.status == #open and lm_o.orderType == #limit);
truth("limit control: resting bid IS on the book",
  OB.findBestMatch(io_s, mkt, #sell) != null);

// ── Issue #42: a limit order that PARTIALLY fills on execution must record
//    its PLACED size, not the resting remainder. originalQuantity is pinned
//    at createOrder time and the closed-order reaper reports it as
//    ClosedOrderRecord.quantity ("original requested quantity", Types.mo) —
//    creating the record at remainingQty and up-adjusting afterwards left
//    originalQuantity = R, so the tape showed quantity = R with filled = F > R. ──
Debug.print("── partial fill records the placed size, not the remainder (#42) ──");
// Book: alice rests 0.5 BTC @ 100. bob limit-buys 2 @ 100 → F = 0.5 fills, R = 1.5 rests.
let pf_s = OB.emptyStore();
let pf_a = Accounts.emptyState();
Accounts.setBalance(pf_a, alice, base, 50_000_000);              // maker: 0.5 BTC
Accounts.setBalance(pf_a, bob, QUOTE, 100_000_000_000);          // taker: 1000 ICPUSD
ignore OB.createOrder(pf_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1);
let (pf_o, pf_t, _, _, _) = MX.executeLimitOrderProtected(
  pf_s, pf_a, mkt, base, bob, #buy, #limit, 10_000_000_000, 200_000_000, 2, 2, // limit buy 2 @ 100
  mkFeeCtx(pf_a, pf_s, func(_) {}), null
);
truth("partial #42: one immediate fill", pf_t.size() == 1);
eqN("partial #42: filled = F (0.5)", pf_o.filled, 50_000_000);
eqN("partial #42: quantity = R+F (2.0)", pf_o.quantity, 200_000_000);
eqN("partial #42: originalQuantity = PLACED size (R+F), not the remainder", pf_o.originalQuantity, 200_000_000);
truth("partial #42: filled <= originalQuantity (reaper reports it as quantity)", pf_o.filled <= pf_o.originalQuantity);
eqN("partial #42: remainder rests (R = 1.5)", OB.remaining(pf_o), 150_000_000);
// The reaper's pick — qty = originalQuantity when > 0, else quantity
// (main.mo reapClosedOrders) — must equal the placed size.
eqN("partial #42: reaper qty pick = placed size",
  (if (pf_o.originalQuantity > 0) pf_o.originalQuantity else pf_o.quantity), 200_000_000);

// W4-22 leg: the sweep's pre-reserved aggressor id (createOrderWithId) carried
// the same defect — same scenario under aggressorIsMaker = true.
let pw_s = OB.emptyStore();
let pw_a = Accounts.emptyState();
Accounts.setBalance(pw_a, alice, base, 50_000_000);
Accounts.setBalance(pw_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(pw_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1);
let pw_ctx : MX.ProtectionCtx = { mkFeeCtx(pw_a, pw_s, func(_) {}) with aggressorIsMaker = true };
let (pw_o, pw_t, _, _, _) = MX.executeLimitOrderProtected(
  pw_s, pw_a, mkt, base, bob, #buy, #limit, 10_000_000_000, 200_000_000, 2, 2, pw_ctx, null
);
truth("partial #42 (W4-22 leg): pre-reserved id materialized", pw_o.id != 0 and pw_t.size() == 1);
eqN("partial #42 (W4-22 leg): originalQuantity = placed size", pw_o.originalQuantity, 200_000_000);
eqN("partial #42 (W4-22 leg): filled = F", pw_o.filled, 50_000_000);
eqN("partial #42 (W4-22 leg): remainder rests (R)", OB.remaining(pw_o), 150_000_000);

// Fully-filled-at-execution control (case b): quantity == originalQuantity == filled.
let pz_s = OB.emptyStore();
let pz_a = Accounts.emptyState();
Accounts.setBalance(pz_a, alice, base, 50_000_000);
Accounts.setBalance(pz_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(pz_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1);
let (pz_o, _, _, _, _) = MX.executeLimitOrderProtected(
  pz_s, pz_a, mkt, base, bob, #buy, #limit, 10_000_000_000, 50_000_000, 2, 2, // exact-size buy
  mkFeeCtx(pz_a, pz_s, func(_) {}), null
);
truth("full-fill control: closed #filled", pz_o.status == #filled);
eqN("full-fill control: originalQuantity = placed size", pz_o.originalQuantity, 50_000_000);
eqN("full-fill control: quantity = placed size", pz_o.quantity, 50_000_000);
eqN("full-fill control: filled = placed size", pz_o.filled, 50_000_000);

// ── Two clocks: the order record keeps the SUBMISSION timestamp, the trades
//    it produces stamp at SETTLEMENT. This is the deferred-release contract —
//    a staged order releasing 15s after submission must not mint trades born
//    15s old (the Trades feed read permanently stale on users-only markets,
//    and fills landed in already-closed candle buckets). ──
let tc_s = OB.emptyStore();
let tc_a = Accounts.emptyState();
Accounts.setBalance(tc_a, alice, base, 50_000_000);
Accounts.setBalance(tc_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(tc_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 100);
let (tc_o, tc_t, _, _, _) = MX.executeLimitOrderProtected(
  tc_s, tc_a, mkt, base, bob, #buy, #limit, 10_000_000_000, 50_000_000,
  1_000, 16_000, // submitted at t=1000, SETTLES at t=16000 (a 15s users-only walk)
  mkFeeCtx(tc_a, tc_s, func(_) {}), null
);
truth("two clocks: trade stamped at SETTLEMENT time", tc_t.size() == 1 and tc_t[0].timestamp == 16_000);
truth("two clocks: order record keeps the SUBMISSION time", tc_o.timestamp == 1_000);
// Legacy wrapper: one clock in → both records agree (synchronous semantics).
let lw_s = OB.emptyStore();
let lw_a = Accounts.emptyState();
Accounts.setBalance(lw_a, alice, base, 50_000_000);
Accounts.setBalance(lw_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(lw_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 100);
let (lw_o, lw_t, _, _) = MX.executeLimitOrder(
  lw_s, lw_a, mkt, base, bob, #buy, 10_000_000_000, 50_000_000, 7_777
);
truth("legacy wrapper: one clock stamps both order and trade",
  lw_o.timestamp == 7_777 and lw_t.size() == 1 and lw_t[0].timestamp == 7_777);

// ════════════════════════════════════════════════════════════════════
// maxQuoteSpend — the #buy quote budget (task 1787204744). The caller sizes
// its quantity at the BEST price (max conversion on a flat book) and passes
// its whole proceeds as a cost+takerFee budget; the engine shrinks each
// slice to min(balance, remaining budget), so a walking book stops EXACTLY
// at the budget — no overspend past it, no band-fraction residual under it.
// Fee ctx: TAKER = 10 bps (mkFeeCtx). Book (unless noted): 2 BTC @ $100 +
// 2 BTC @ $110, 10% slippage (cap = $110, both levels in band).
// ════════════════════════════════════════════════════════════════════
Debug.print("── maxQuoteSpend budget ──");

func mkTwoLevelBook() : (OB.OrderStore, Accounts.AccountState) {
  let s = OB.emptyStore();
  let a = Accounts.emptyState();
  Accounts.setBalance(a, alice, base, 400_000_000);            // 4 BTC maker
  Accounts.setBalance(a, bob, QUOTE, 100_000_000_000);         // 1000 ICPUSD taker
  ignore OB.createOrder(s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
  ignore OB.createOrder(s, mkt, alice, #sell, #limit, 11_000_000_000, 200_000_000, 2); // 2 @ 110
  (s, a);
};

// ── (B1) Budget BETWEEN the level costs: level 1 (2@100 = $200.20 with fee)
//        fits, level 2 does not — the walk fills level 1 whole, then shrinks
//        the level-2 slice so the TOTAL spend lands within a rounding crumb
//        of the $300 budget, and stops. The taker's balance ($1000) must not
//        be touched past the budget. ──
let qb_budget : Nat = 30_000_000_000;                          // $300
let (qb_s, qb_a) = mkTwoLevelBook();
let qb_r = MX.executeMarketOrderProtected(qb_s, qb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qb_a, qb_s, func(_) {}), ?qb_budget);
let qb_spent = 100_000_000_000 - Accounts.getBalance(qb_a, bob, QUOTE) : Nat;
truth("budget between levels: spend ≤ budget", qb_spent <= qb_budget);
truth("budget between levels: spend within a crumb of the budget (≥ budget−100)", qb_budget - qb_spent < 100);
eqN("budget between levels: quoteSpent reports the debit exactly", qb_r.quoteSpent, qb_spent);
truth("budget between levels: level 1 swept + level 2 entered (2 trades)", qb_r.trades.size() == 2);
truth("budget between levels: filled past level 1, short of the sized qty",
  qb_r.totalFilled > 200_000_000 and qb_r.totalFilled < 300_000_000);
truth("budget between levels: remainder returned (budget stop, not book exhaustion)", qb_r.remainingQty > 0);
eqN("budget between levels: taker got exactly what it paid for",
  Accounts.getBalance(qb_a, bob, base), qb_r.totalFilled);

// ── (B2) Budget LARGER than the whole book cost: full fill, spend = book
//        cost + fee, budget never binds. ──
let (qf_s, qf_a) = mkTwoLevelBook();
let qf_r = MX.executeMarketOrderProtected(qf_s, qf_a, mkt, base, bob, #buy, 400_000_000, 10_000_000, false, 2, mkFeeCtx(qf_a, qf_s, func(_) {}), ?90_000_000_000);
eqN("budget above book: full fill (4 BTC)", qf_r.totalFilled, 400_000_000);
eqN("budget above book: nothing left", qf_r.remainingQty, 0);
// cost = 2×100 + 2×110 = 420; taker fee 10 bps = 0.42 → spend 420.42
eqN("budget above book: spent book cost + taker fee", qf_r.quoteSpent, 42_042_000_000);
eqN("budget above book: balance debit agrees", Accounts.getBalance(qf_a, bob, QUOTE), 100_000_000_000 - 42_042_000_000);

// ── (B3) Budget smaller than one full fill: the slice shrinks to the
//        affordable FLOOR quantity (cost+fee ≤ budget), fills it, stops. ──
let (qs_s, qs_a) = mkTwoLevelBook();
let qs_budget : Nat = 5_000_000_000;                           // $50 ≪ level-1's $200
let qs_r = MX.executeMarketOrderProtected(qs_s, qs_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qs_a, qs_s, func(_) {}), ?qs_budget);
truth("budget below one fill: partial floor fill (0 < qty < level size)",
  qs_r.totalFilled > 0 and qs_r.totalFilled < 200_000_000);
truth("budget below one fill: spend ≤ budget", qs_r.quoteSpent <= qs_budget);
truth("budget below one fill: spend within a crumb of the budget", qs_budget - qs_r.quoteSpent < 200);
truth("budget below one fill: single trade", qs_r.trades.size() == 1);

// Sub-unit budget: can't afford even ONE base unit at the best price →
// nothing fills, nothing moves.
let (qz_s, qz_a) = mkTwoLevelBook();
let qz_r = MX.executeMarketOrderProtected(qz_s, qz_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qz_a, qz_s, func(_) {}), ?50);
eqN("sub-unit budget: nothing filled", qz_r.totalFilled, 0);
eqN("sub-unit budget: quoteSpent 0", qz_r.quoteSpent, 0);
eqN("sub-unit budget: taker balance untouched", Accounts.getBalance(qz_a, bob, QUOTE), 100_000_000_000);

// ── (B4) null budget: legacy semantics unchanged — the same walk is bounded
//        only by the taker's whole available balance, so it walks the book
//        past where the $300 budget stopped. ──
let (qn_s, qn_a) = mkTwoLevelBook();
let qn_r = MX.executeMarketOrderProtected(qn_s, qn_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qn_a, qn_s, func(_) {}), null);
eqN("null budget: fills the full sized qty (3 BTC)", qn_r.totalFilled, 300_000_000);
// cost = 2×100 + 1×110 = 310; fee 10 bps = 0.31 → 310.31 — past the B1 budget.
eqN("null budget: spends past the B1 budget (whole balance is the only bound)", qn_r.quoteSpent, 31_031_000_000);

// ── (B5) FOK composes with the budget: the pre-check simulates with the
//        SAME budget clamp, so an all-or-nothing quantity the budget cannot
//        cover KILLS (never partial-fills at the budget stop)... ──
let (qk_s, qk_a) = mkTwoLevelBook();
let qk_r = MX.executeMarketOrderProtected(qk_s, qk_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2, mkFeeCtx(qk_a, qk_s, func(_) {}), ?30_000_000_000);
eqN("FOK + short budget: killed, nothing filled", qk_r.totalFilled, 0);
truth("FOK + short budget: no trades", qk_r.trades.size() == 0);
eqN("FOK + short budget: taker balance untouched", Accounts.getBalance(qk_a, bob, QUOTE), 100_000_000_000);

// ...while a budget that covers the full quantity passes and settles whole.
let (qp_s, qp_a) = mkTwoLevelBook();
let qp_r = MX.executeMarketOrderProtected(qp_s, qp_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2, mkFeeCtx(qp_a, qp_s, func(_) {}), ?35_000_000_000);
eqN("FOK + ample budget: fills in full", qp_r.totalFilled, 300_000_000);
eqN("FOK + ample budget: spent cost+fee (310.31)", qp_r.quoteSpent, 31_031_000_000);

// ════════════════════════════════════════════════════════════════════
// maxQuoteSpend on the LIMIT engine (task 1787209266) — the budget threaded
// through executeLimitOrderProtected for the STAGED direct-swap path
// (releaseDeferred, orderType = #market/IOC). Same contract as the market
// variant above; additionally the NULL path must stay byte-identical —
// including the legacy "unaffordable buyer BREAKS" semantics (no shrink) —
// and #limit callers (always null) are unaffected.
// ════════════════════════════════════════════════════════════════════
Debug.print("── maxQuoteSpend budget (limit engine / IOC release path) ──");

// ── (L1) Budget BETWEEN the level costs, IOC #market release: level 1
//        (2@100 = $200.20 with fee) fits, level 2 does not — level 1 sweeps
//        whole, the level-2 slice shrinks so the TOTAL spend lands within a
//        crumb of the $300 budget, and the walk stops. IOC: the remainder
//        never rests. ──
let lb_budget : Nat = 30_000_000_000;                          // $300
let (lb_s, lb_a) = mkTwoLevelBook();
let (lb_o, lb_t, _, _, lb_spent) = MX.executeLimitOrderProtected(
  lb_s, lb_a, mkt, base, bob, #buy, #market, 11_000_000_000, 300_000_000, 2, 2, // IOC buy 3, cap $110
  mkFeeCtx(lb_a, lb_s, func(_) {}), ?lb_budget
);
let lb_debit = 100_000_000_000 - Accounts.getBalance(lb_a, bob, QUOTE) : Nat;
truth("limit budget between levels: spend ≤ budget", lb_debit <= lb_budget);
truth("limit budget between levels: spend within a crumb of the budget", lb_budget - lb_debit < 100);
eqN("limit budget between levels: quoteSpent reports the debit exactly", lb_spent, lb_debit);
truth("limit budget between levels: level 1 swept + level 2 entered (2 trades)", lb_t.size() == 2);
truth("limit budget between levels: filled past level 1, short of the sized qty",
  lb_o.filled > 200_000_000 and lb_o.filled < 300_000_000);
eqN("limit budget between levels: taker got exactly what it paid for",
  Accounts.getBalance(lb_a, bob, base), lb_o.filled);
truth("limit budget between levels: IOC — remainder never rests",
  OB.findBestMatch(lb_s, mkt, #sell) == null);   // a seller would match a resting bid — none

// ── (L2) null budget, SAME call: legacy semantics — bounded only by the
//        taker's whole balance, walks the book past where $300 stopped. ──
let (ln_s, ln_a) = mkTwoLevelBook();
let (ln_o, _, _, _, ln_spent) = MX.executeLimitOrderProtected(
  ln_s, ln_a, mkt, base, bob, #buy, #market, 11_000_000_000, 300_000_000, 2, 2,
  mkFeeCtx(ln_a, ln_s, func(_) {}), null
);
eqN("limit null budget: fills the full sized qty (3 BTC)", ln_o.filled, 300_000_000);
// cost = 2×100 + 1×110 = 310; taker fee 10 bps = 0.31 → 310.31 — past the L1 budget.
eqN("limit null budget: quoteSpent = cost+fee (310.31)", ln_spent, 31_031_000_000);

// ── (L3) The shrink fires ONLY with a budget. An unaffordable buyer on the
//        null path keeps the legacy BREAK (fills nothing — the resting-#limit
//        flow's semantics); the same balance passed AS a budget shrinks the
//        slice and converts what fits. ──
let lu_s = OB.emptyStore();
let lu_a = Accounts.emptyState();
Accounts.setBalance(lu_a, alice, base, 400_000_000);
Accounts.setBalance(lu_a, bob, QUOTE, 15_000_000_000);          // $150 < level-1's $200.20
ignore OB.createOrder(lu_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1); // 2 @ 100
let (lu_o, lu_t, _, _, lu_spent) = MX.executeLimitOrderProtected(
  lu_s, lu_a, mkt, base, bob, #buy, #market, 11_000_000_000, 300_000_000, 2, 2,
  mkFeeCtx(lu_a, lu_s, func(_) {}), null
);
eqN("limit null unaffordable: legacy break — nothing fills", lu_o.filled, 0);
truth("limit null unaffordable: no trades", lu_t.size() == 0);
eqN("limit null unaffordable: quoteSpent 0", lu_spent, 0);
eqN("limit null unaffordable: balance untouched", Accounts.getBalance(lu_a, bob, QUOTE), 15_000_000_000);
let lv_s = OB.emptyStore();
let lv_a = Accounts.emptyState();
Accounts.setBalance(lv_a, alice, base, 400_000_000);
Accounts.setBalance(lv_a, bob, QUOTE, 15_000_000_000);
ignore OB.createOrder(lv_s, mkt, alice, #sell, #limit, 10_000_000_000, 200_000_000, 1);
let (lv_o, lv_t, _, _, lv_spent) = MX.executeLimitOrderProtected(
  lv_s, lv_a, mkt, base, bob, #buy, #market, 11_000_000_000, 300_000_000, 2, 2,
  mkFeeCtx(lv_a, lv_s, func(_) {}), ?15_000_000_000
);
truth("limit budget=balance: shrinks and converts (0 < filled < level)",
  lv_o.filled > 0 and lv_o.filled < 200_000_000);
truth("limit budget=balance: one trade", lv_t.size() == 1);
truth("limit budget=balance: spend ≤ budget", lv_spent <= 15_000_000_000);
truth("limit budget=balance: spend within a crumb of the budget", 15_000_000_000 - lv_spent < 200);

// ── (L4) #limit caller control: a crossing #limit (null budget — every
//        #limit caller passes null) keeps its resting semantics untouched:
//        fills what balance affords... and here, fully funded, it fills level
//        1 and RESTS the remainder at its limit price. ──
let (ll_s, ll_a) = mkTwoLevelBook();
let (ll_o, ll_t, _, _, _) = MX.executeLimitOrderProtected(
  ll_s, ll_a, mkt, base, bob, #buy, #limit, 10_500_000_000, 300_000_000, 2, 2, // limit $105: crosses level 1 only
  mkFeeCtx(ll_a, ll_s, func(_) {}), null
);
truth("limit control: level-1 fill", ll_t.size() == 1);
eqN("limit control: filled level 1 (2 BTC)", ll_o.filled, 200_000_000);
truth("limit control: remainder RESTS open (unchanged semantics)", OB.isOpen(ll_o));
eqN("limit control: rested remainder (1 BTC)", OB.remaining(ll_o), 100_000_000);

// ════════════════════════════════════════════════════════════════════
// PER-CALL ITERATION CAP. One matcher invocation spends at most
// MAX_MATCH_ITERATIONS_PER_CALL loop iterations, so a single message's
// matcher work is bounded no matter how many orders rest at one price
// (uncapped, a taker sweeping a stacked level was the O(K²) shape that
// trapped the instruction limit at ~3k same-price orders). Cap-out
// semantics: a #market taker returns the remainder (IOC), a #limit taker
// rests it. The FOK pre-check promises only FOK_SIM_MAKER_BUDGET (= half
// the cap) distinct makers, so a passed pre-check always completes — a
// bigger all-or-nothing job is killed cleanly, never partially filled.
// ════════════════════════════════════════════════════════════════════
Debug.print("── per-call iteration cap ──");
let CAP = MX.MAX_MATCH_ITERATIONS_PER_CALL;
let SIM = MX.FOK_SIM_MAKER_BUDGET;
let mq : Nat = 1_000_000;             // 0.01 BTC per maker → $1 per fill at $100
var i : Nat = 0;

// ── market taker over the cap: exactly CAP fills, remainder returned ──
let ic_s = OB.emptyStore();
let ic_a = Accounts.emptyState();
Accounts.setBalance(ic_a, alice, base, 300_000_000);      // 3 BTC backs all makers
Accounts.setBalance(ic_a, bob, QUOTE, 100_000_000_000);   // 1000 ICPUSD
i := 0;
while (i < CAP + 4) {
  ignore OB.createOrder(ic_s, mkt, alice, #sell, #limit, 10_000_000_000, mq, 1);
  i += 1;
};
let ic_r = MX.executeMarketOrder(ic_s, ic_a, mkt, base, bob, #buy, (CAP + 4) * mq, 10_000_000, false, 2);
eqN("cap market: exactly CAP makers filled", ic_r.totalFilled, CAP * mq);
eqN("cap market: remainder returned unfilled (IOC)", ic_r.remainingQty, 4 * mq);
eqN("cap market: one trade per maker", ic_r.trades.size(), CAP);
eqN("cap market: the uncapped makers still rest", OB.getLevelOrderCount(ic_s, mkt, #sell, 10_000_000_000), 4);
eqN("cap market: taker paid for exactly CAP fills",
  Accounts.getBalance(ic_a, bob, QUOTE), 100_000_000_000 - CAP * 100_000_000);

// ── limit taker over the cap: CAP fills, remainder RESTS at its limit ──
let cl_s = OB.emptyStore();
let cl_a = Accounts.emptyState();
Accounts.setBalance(cl_a, alice, base, 300_000_000);
Accounts.setBalance(cl_a, bob, QUOTE, 100_000_000_000);
i := 0;
while (i < CAP + 4) {
  ignore OB.createOrder(cl_s, mkt, alice, #sell, #limit, 10_000_000_000, mq, 1);
  i += 1;
};
let (cl_o, cl_t, _, _) = MX.executeLimitOrder(cl_s, cl_a, mkt, base, bob, #buy, 10_000_000_000, (CAP + 4) * mq, 2);
eqN("cap limit: CAP fills", cl_t.size(), CAP);
eqN("cap limit: filled quantity = CAP makers", cl_o.filled, CAP * mq);
truth("cap limit: remainder rests open", OB.isOpen(cl_o));
eqN("cap limit: rested remainder", OB.remaining(cl_o), 4 * mq);

// ── FOK over the sim budget: killed at the pre-check, book untouched ──
let fk_s = OB.emptyStore();
let fk_a = Accounts.emptyState();
Accounts.setBalance(fk_a, alice, base, 300_000_000);
Accounts.setBalance(fk_a, bob, QUOTE, 100_000_000_000);
i := 0;
while (i < SIM + 2) {
  ignore OB.createOrder(fk_s, mkt, alice, #sell, #limit, 10_000_000_000, mq, 1);
  i += 1;
};
let fk_r = MX.executeMarketOrder(fk_s, fk_a, mkt, base, bob, #buy, (SIM + 2) * mq, 10_000_000, true, 2);
eqN("FOK over budget: killed, nothing fills", fk_r.totalFilled, 0);
truth("FOK over budget: no trades", fk_r.trades.size() == 0);
eqN("FOK over budget: every maker still rests", OB.getLevelOrderCount(fk_s, mkt, #sell, 10_000_000_000), SIM + 2);
eqN("FOK over budget: taker balance untouched", Accounts.getBalance(fk_a, bob, QUOTE), 100_000_000_000);

// ── FOK within the sim budget: fills in full ──
let fw_s = OB.emptyStore();
let fw_a = Accounts.emptyState();
Accounts.setBalance(fw_a, alice, base, 300_000_000);
Accounts.setBalance(fw_a, bob, QUOTE, 100_000_000_000);
i := 0;
while (i < 100) {
  ignore OB.createOrder(fw_s, mkt, alice, #sell, #limit, 10_000_000_000, mq, 1);
  i += 1;
};
let fw_r = MX.executeMarketOrder(fw_s, fw_a, mkt, base, bob, #buy, 100 * mq, 10_000_000, true, 2);
eqN("FOK within budget: fills in full", fw_r.totalFilled, 100 * mq);
eqN("FOK within budget: nothing left", fw_r.remainingQty, 0);
eqN("FOK within budget: level swept clean", OB.getLevelOrderCount(fw_s, mkt, #sell, 10_000_000_000), 0);

Debug.print("── MatchingEngine.test PASSED ──");
