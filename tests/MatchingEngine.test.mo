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
  availableBalance = func(p, t) { Accounts.getBalance(acc, p, t) };
  isNonTakeable    = func(_, _) { false };
  aggressorRole    = #taker;
  onUnfundedMaker  = func(_, _, _, _, _) {};
  isExpired        = func(_) { false };
  quoteFee         = func(_p, gross, role) {
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000   // floor — == Fixed.mulDiv(gross, bps, 10_000, false)
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(acc, treas, QUOTE, fee) } };
  onSelfTrade      = func(id, _owner) { ignore OB.cancelOrder(store, id); onCancel(id) };
  beneficialOwner  = beneficial;   // pools → their owner; everyone else → themselves
  onTradeFees      = func(_, _, _) {};
  fundForFill      = func(_, _, _, _, _) { true };
  fundableScorer   = func() { MX.cashScorer(func(p, t) { Accounts.getBalance(acc, p, t) }) };
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
let sb_r = MX.executeMarketOrderProtected(sb_s, sb_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 2, mkFeeCtx(sb_a, sb_s, func(_) {}), null, null);
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
let fs_r = MX.executeMarketOrderProtected(fs_s, fs_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, false, 3, mkFeeCtx(fs_a, fs_s, func(_) {}), null, null);
eqN("sellfee: filled 1 BTC", fs_r.totalFilled, 100_000_000);
eqN("sellfee: maker-buyer paid C+makerFee → 0", Accounts.getBalance(fs_a, alice, QUOTE), 0);
eqN("sellfee: maker-buyer got 1 BTC", Accounts.getBalance(fs_a, alice, base), 100_000_000);
eqN("sellfee: taker-seller got C-takerFee (9_990_000_000)", Accounts.getBalance(fs_a, bob, QUOTE), 9_990_000_000);
eqN("sellfee: treasury got makerFee+takerFee (15_000_000)", Accounts.getBalance(fs_a, treas, QUOTE), 15_000_000);
eqN("sellfee: Σ QUOTE conserved", Accounts.getBalance(fs_a, alice, QUOTE) + Accounts.getBalance(fs_a, bob, QUOTE) + Accounts.getBalance(fs_a, treas, QUOTE), fs_before);

// ── (2b) 1788661917: the maker-buy gates round like the DEBIT. A non-integral
//        cost — 33.33333333 BTC @ 9.99 = 33,299,999,996.67 quote units —
//        settles at the FLOOR (33_299_999_996) + the 5 bps maker fee on it
//        (16_649_999) = 33_316_649_995. The market variant's early makerNeeds
//        pre-gate and the FOK pre-check (simulateAvailableFill) ceiled the
//        cost — one unit above their own debit — and refused a maker funded
//        to the unit; both floor now. The one-short twin is refused by the
//        FOK pre-check (nothing fills, the bid stays open) and, without FOK,
//        cancelled by the pre-gate as unfunded. ──
let rd_s = OB.emptyStore();
let rd_a = Accounts.emptyState();
Accounts.setBalance(rd_a, alice, QUOTE, 33_316_649_995);        // maker buyer: ⌊C⌋ + makerFee(⌊C⌋), to the unit
Accounts.setBalance(rd_a, bob, base, 3_333_333_333);
let rd_id = OB.createOrder(rd_s, mkt, alice, #buy, #limit, 999_000_000, 3_333_333_333, 1).id;
let rd_before = Accounts.getBalance(rd_a, alice, QUOTE) + Accounts.getBalance(rd_a, bob, QUOTE) + Accounts.getBalance(rd_a, treas, QUOTE);
let rd_r = MX.executeMarketOrderProtected(rd_s, rd_a, mkt, base, bob, #sell, 3_333_333_333, 10_000_000, true, 3, mkFeeCtx(rd_a, rd_s, func(_) {}), null, null);
eqN("floor gate: a FOK sell fills WHOLE against a maker funded to ⌊C⌋ + fee (the ceil refused it)", rd_r.totalFilled, 3_333_333_333);
eqN("floor gate: the maker's debit is exactly its balance (residue 0)", Accounts.getBalance(rd_a, alice, QUOTE), 0);
eqN("floor gate: the maker got the whole 33.33333333 BTC", Accounts.getBalance(rd_a, alice, base), 3_333_333_333);
eqN("floor gate: the seller is credited on the SAME floored cost − takerFee (33_266_699_997)", Accounts.getBalance(rd_a, bob, QUOTE), 33_266_699_997);
eqN("floor gate: treasury got makerFee + takerFee on the floored cost (49_949_998)", Accounts.getBalance(rd_a, treas, QUOTE), 49_949_998);
eqN("floor gate: Σ QUOTE conserved", Accounts.getBalance(rd_a, alice, QUOTE) + Accounts.getBalance(rd_a, bob, QUOTE) + Accounts.getBalance(rd_a, treas, QUOTE), rd_before);
truth("floor gate: the bid is consumed", switch (OB.getOrder(rd_s, rd_id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
// One quote unit short: the FOK pre-check counts the maker ZERO and refuses
// the whole order — nothing settles and the bid stays OPEN (a probe cancels
// nothing) — exactly the walker's verdict on the same maker.
let rs_s = OB.emptyStore();
let rs_a = Accounts.emptyState();
Accounts.setBalance(rs_a, alice, QUOTE, 33_316_649_994);
Accounts.setBalance(rs_a, bob, base, 3_333_333_333);
let rs_id = OB.createOrder(rs_s, mkt, alice, #buy, #limit, 999_000_000, 3_333_333_333, 1).id;
let rs_r = MX.executeMarketOrderProtected(rs_s, rs_a, mkt, base, bob, #sell, 3_333_333_333, 10_000_000, true, 3, mkFeeCtx(rs_a, rs_s, func(_) {}), null, null);
eqN("floor gate, one short: the FOK pre-check refuses the whole order", rs_r.totalFilled, 0);
eqN("floor gate, one short: nothing settled (seller keeps its base)", Accounts.getBalance(rs_a, bob, base), 3_333_333_333);
truth("floor gate, one short: the bid stays open (the pre-check is a probe)", switch (OB.getOrder(rs_s, rs_id)) { case (?o) { OB.isOpen(o) }; case null { false } });
// ...and without FOK the pre-gate cancels it as unfunded (the mid-match
// notice fires once), taking nothing — the same one-unit line, from the
// live loop.
var ru_cancelled : Nat = 0;
let ru_s = OB.emptyStore();
let ru_a = Accounts.emptyState();
Accounts.setBalance(ru_a, alice, QUOTE, 33_316_649_994);
Accounts.setBalance(ru_a, bob, base, 3_333_333_333);
let ru_id = OB.createOrder(ru_s, mkt, alice, #buy, #limit, 999_000_000, 3_333_333_333, 1).id;
let ru_ctx : MX.ProtectionCtx = { mkFeeCtx(ru_a, ru_s, func(_) {}) with onUnfundedMaker = func(_, _, _, _, _) { ru_cancelled += 1 } };
let ru_r = MX.executeMarketOrderProtected(ru_s, ru_a, mkt, base, bob, #sell, 3_333_333_333, 10_000_000, false, 3, ru_ctx, null, null);
eqN("floor gate, one short, no FOK: the pre-gate takes nothing", ru_r.totalFilled, 0);
eqN("floor gate, one short, no FOK: ONE unfunded-maker notice", ru_cancelled, 1);
truth("floor gate, one short, no FOK: the bid is cancelled", switch (OB.getOrder(ru_s, ru_id)) { case (?o) { not OB.isOpen(o) }; case null { true } });

// ── (3) Self-trade prevention: alice market-sells into her OWN resting bid →
//        no fill, the resting bid is cancelled, her balances are untouched. ──
let st_s = OB.emptyStore();
let st_a = Accounts.emptyState();
Accounts.setBalance(st_a, alice, QUOTE, 10_005_000_000);        // funds her resting bid
Accounts.setBalance(st_a, alice, base, 100_000_000);           // and the base she'd sell
let st_bid = OB.createOrder(st_s, mkt, alice, #buy, #limit, 10_000_000_000, 100_000_000, 1);
var st_cancelled : Nat = 0;
let st_r = MX.executeMarketOrderProtected(st_s, st_a, mkt, base, alice, #sell, 100_000_000, 10_000_000, false, 4, mkFeeCtx(st_a, st_s, func(id) { st_cancelled := id }), null, null);
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
let bp_r = MX.executeMarketOrderProtected(bp_s, bp_a, mkt, base, poolC2, #sell, 100_000_000, 10_000_000, false, 2, mkFeeCtx(bp_a, bp_s, func(id) { bp_cancelled := id }), null, null);
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
let bx_r = MX.executeMarketOrderProtected(bx_s, bx_a, mkt, base, poolD1, #sell, 100_000_000, 10_000_000, false, 2, mkFeeCtx(bx_a, bx_s, func(id) { bx_cancelled := id }), null, null);
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
let bk_r = MX.executeMarketOrderProtected(bk_s, bk_a, mkt, base, poolC2, #sell, 100_000_000, 10_000_000, true, 2, mkFeeCtx(bk_a, bk_s, func(_) {}), null, null);
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
  availableBalance = func(p, t) { Accounts.getBalance(ex_a, p, t) };
  isNonTakeable    = func(_, _) { false };
  aggressorRole    = #taker;
  onUnfundedMaker  = func(_, _, _, _, _) {};
  isExpired        = func(_) { false };
  quoteFee         = func(p, gross, role) {
    if (Principal.equal(p, ammP)) { return 0 };   // exempt party → no fee on its leg
    let bps = switch (role) { case (#takerDebit or #takerCredit) { 10 }; case (#makerDebit or #makerCredit) { 5 } };
    (gross * bps) / 10_000
  };
  creditTreasury   = func(fee) { if (fee > 0) { Accounts.addBalance(ex_a, treas, QUOTE, fee) } };
  onSelfTrade      = func(_, _) {};
  beneficialOwner  = beneficial;
  onTradeFees      = func(_, _, _) {};
  fundForFill      = func(_, _, _, _, _) { true };
  fundableScorer   = func() { MX.cashScorer(func(p, t) { Accounts.getBalance(ex_a, p, t) }) };
};
let ex_before = Accounts.getBalance(ex_a, ammP, QUOTE) + Accounts.getBalance(ex_a, bob, QUOTE) + Accounts.getBalance(ex_a, treas, QUOTE);
let ex_r = MX.executeMarketOrderProtected(ex_s, ex_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 5, ex_ctx, null, null);
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
// the same defect — same scenario under the #swept aggressor role.
let pw_s = OB.emptyStore();
let pw_a = Accounts.emptyState();
Accounts.setBalance(pw_a, alice, base, 50_000_000);
Accounts.setBalance(pw_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(pw_s, mkt, alice, #sell, #limit, 10_000_000_000, 50_000_000, 1);
let pw_ctx : MX.ProtectionCtx = { mkFeeCtx(pw_a, pw_s, func(_) {}) with aggressorRole = #swept({ makerVs = func(_) { true } }) };
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

// ── H-24 (F25, D1): the swept aggressor's role is decided PER COUNTERPARTY ──
// A re-homed resting order (#swept) walking a book that holds BOTH an "AMM"
// ask (srAmm plays the AMM: makerVs = srAmm) and a plain user's ask (alice):
// the slice against carol is maker-rated (5 bps) and carries the pre-reserved
// aggressor id; the slice against alice is a TAKER leg (10 bps) and carries the
// id-0 sentinel — a user-vs-user sweep fill never settles maker/maker.
// Pre-H-24 the flat Bool rated both slices maker and stamped the id on both.
let srAmm = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");   // plays the AMM
let sr_s = OB.emptyStore();
let sr_a = Accounts.emptyState();
Accounts.setBalance(sr_a, srAmm, base, 50_000_000);   // "AMM" ask 0.5 @ 100
Accounts.setBalance(sr_a, alice, base, 50_000_000);   // user ask 0.5 @ 101
Accounts.setBalance(sr_a, bob, QUOTE, 100_000_000_000);
let sr_amm  = OB.createOrder(sr_s, mkt, srAmm, #sell, #limit, 10_000_000_000, 50_000_000, 1);
let sr_user = OB.createOrder(sr_s, mkt, alice, #sell, #limit, 10_100_000_000, 50_000_000, 1);
let sr_ctx : MX.ProtectionCtx = { mkFeeCtx(sr_a, sr_s, func(_) {}) with
  aggressorRole = #swept({ makerVs = func(p) { Principal.equal(p, srAmm) } }) };
let (sr_o, sr_t, _, _, _) = MX.executeLimitOrderProtected(
  sr_s, sr_a, mkt, base, bob, #buy, #limit, 10_100_000_000, 100_000_000, 2, 2, sr_ctx, null
);
eqN("H-24 roles: two slices settled", sr_t.size(), 2);
truth("H-24 roles: re-homed order materialised under its pre-reserved id", sr_o.id != 0 and sr_o.status == #filled);
if (sr_t.size() == 2) {
  let vsAmm  = sr_t[0]; let vsUser = sr_t[1];
  truth("H-24 roles: first slice took the AMM ask", vsAmm.sellOrderId == sr_amm.id and vsAmm.price == 10_000_000_000);
  truth("H-24 roles: second slice took the USER ask", vsUser.sellOrderId == sr_user.id and vsUser.price == 10_100_000_000);
  eqN("H-24 roles: vs the AMM the swept side carries its own id (maker attribution)", vsAmm.buyOrderId, sr_o.id);
  eqN("H-24 roles: vs a user the swept side carries 0 (taker attribution)", vsUser.buyOrderId, 0);
};
// Fees: cost 5_000_000_000 per slice (0.5 × 100 / 0.5 × 101 → 5_000_000_000 / 5_050_000_000).
// Maker 5 bps on the AMM slice = 2_500_000; TAKER 10 bps on the user slice = 5_050_000.
// bob's quote outlay = 5_000_000_000 + 2_500_000 + 5_050_000_000 + 5_050_000.
eqN("H-24 roles: aggressor paid MAKER vs the AMM and TAKER vs the user",
  100_000_000_000 - Accounts.getBalance(sr_a, bob, QUOTE), 5_000_000_000 + 2_500_000 + 5_050_000_000 + 5_050_000);
// Resting legs keep their own (maker) role: alice nets cost − 5 bps.
eqN("H-24 roles: the user maker still nets the maker rate", Accounts.getBalance(sr_a, alice, QUOTE), 5_050_000_000 - 2_525_000);

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
let (lw_o, lw_t, _) = MX.executeLimitOrder(
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
let qb_r = MX.executeMarketOrderProtected(qb_s, qb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qb_a, qb_s, func(_) {}), ?qb_budget, null);
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
let qf_r = MX.executeMarketOrderProtected(qf_s, qf_a, mkt, base, bob, #buy, 400_000_000, 10_000_000, false, 2, mkFeeCtx(qf_a, qf_s, func(_) {}), ?90_000_000_000, null);
eqN("budget above book: full fill (4 BTC)", qf_r.totalFilled, 400_000_000);
eqN("budget above book: nothing left", qf_r.remainingQty, 0);
// cost = 2×100 + 2×110 = 420; taker fee 10 bps = 0.42 → spend 420.42
eqN("budget above book: spent book cost + taker fee", qf_r.quoteSpent, 42_042_000_000);
eqN("budget above book: balance debit agrees", Accounts.getBalance(qf_a, bob, QUOTE), 100_000_000_000 - 42_042_000_000);

// ── (B3) Budget smaller than one full fill: the slice shrinks to the
//        affordable FLOOR quantity (cost+fee ≤ budget), fills it, stops. ──
let (qs_s, qs_a) = mkTwoLevelBook();
let qs_budget : Nat = 5_000_000_000;                           // $50 ≪ level-1's $200
let qs_r = MX.executeMarketOrderProtected(qs_s, qs_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qs_a, qs_s, func(_) {}), ?qs_budget, null);
truth("budget below one fill: partial floor fill (0 < qty < level size)",
  qs_r.totalFilled > 0 and qs_r.totalFilled < 200_000_000);
truth("budget below one fill: spend ≤ budget", qs_r.quoteSpent <= qs_budget);
truth("budget below one fill: spend within a crumb of the budget", qs_budget - qs_r.quoteSpent < 200);
truth("budget below one fill: single trade", qs_r.trades.size() == 1);

// Sub-unit budget: can't afford even ONE base unit at the best price →
// nothing fills, nothing moves.
let (qz_s, qz_a) = mkTwoLevelBook();
let qz_r = MX.executeMarketOrderProtected(qz_s, qz_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qz_a, qz_s, func(_) {}), ?50, null);
eqN("sub-unit budget: nothing filled", qz_r.totalFilled, 0);
eqN("sub-unit budget: quoteSpent 0", qz_r.quoteSpent, 0);
eqN("sub-unit budget: taker balance untouched", Accounts.getBalance(qz_a, bob, QUOTE), 100_000_000_000);

// ── (B4) null budget: legacy semantics unchanged — the same walk is bounded
//        only by the taker's whole available balance, so it walks the book
//        past where the $300 budget stopped. ──
let (qn_s, qn_a) = mkTwoLevelBook();
let qn_r = MX.executeMarketOrderProtected(qn_s, qn_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(qn_a, qn_s, func(_) {}), null, null);
eqN("null budget: fills the full sized qty (3 BTC)", qn_r.totalFilled, 300_000_000);
// cost = 2×100 + 1×110 = 310; fee 10 bps = 0.31 → 310.31 — past the B1 budget.
eqN("null budget: spends past the B1 budget (whole balance is the only bound)", qn_r.quoteSpent, 31_031_000_000);

// ── (B5) FOK composes with the budget: the pre-check simulates with the
//        SAME budget clamp, so an all-or-nothing quantity the budget cannot
//        cover KILLS (never partial-fills at the budget stop)... ──
let (qk_s, qk_a) = mkTwoLevelBook();
let qk_r = MX.executeMarketOrderProtected(qk_s, qk_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2, mkFeeCtx(qk_a, qk_s, func(_) {}), ?30_000_000_000, null);
eqN("FOK + short budget: killed, nothing filled", qk_r.totalFilled, 0);
truth("FOK + short budget: no trades", qk_r.trades.size() == 0);
eqN("FOK + short budget: taker balance untouched", Accounts.getBalance(qk_a, bob, QUOTE), 100_000_000_000);

// ...while a budget that covers the full quantity passes and settles whole.
let (qp_s, qp_a) = mkTwoLevelBook();
let qp_r = MX.executeMarketOrderProtected(qp_s, qp_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, true, 2, mkFeeCtx(qp_a, qp_s, func(_) {}), ?35_000_000_000, null);
eqN("FOK + ample budget: fills in full", qp_r.totalFilled, 300_000_000);
eqN("FOK + ample budget: spent cost+fee (310.31)", qp_r.quoteSpent, 31_031_000_000);

// ── (B6) Budget shrink BEFORE the maker gate (task 1788662146). Level 2's
//        maker is a DIFFERENT wallet (carol) funded for LESS than its 2 BTC
//        ask but MORE than the budget-affordable slice: after level 1
//        ($200.20) the $300 budget leaves $99.80 → 0.90636636 BTC @ $110;
//        the unshrunk slice is min(3−2, 2) = 1 BTC. Carol holds 0.95 BTC.
//        The engine must shrink to 0.90636636 FIRST and gate carol on THAT
//        (the limit variant's and walkFillable's ordering) — she fills her
//        slice. Pre-fix the gate ran on the unshrunk 1 BTC, cancelled her
//        (the mid-match notice) and the walk stopped at 2 BTC: the FOK
//        cross-swap gate, which trims before it credits, passed a buy leg
//        the engine then came up one maker short on. ──
let (q6_s, q6_a) = mkTwoLevelBook();
// Swap level 2's maker for carol: cancel alice's 2 @ 110, rest carol's.
ignore OB.cancelOrder(q6_s, 2);
let q6_o = OB.createOrder(q6_s, mkt, carol, #sell, #limit, 11_000_000_000, 200_000_000, 3); // 2 @ 110
Accounts.setBalance(q6_a, carol, base, 95_000_000);              // 0.95 BTC: < 1 BTC slice, > 0.906 shrunk slice
var q6_unfunded : Nat = 0;
let q6_ctx : MX.ProtectionCtx = { mkFeeCtx(q6_a, q6_s, func(_) {}) with onUnfundedMaker = func(_, _, _, _, _) { q6_unfunded += 1 } };
let q6_r = MX.executeMarketOrderProtected(q6_s, q6_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 4, q6_ctx, ?qb_budget, null);
eqN("shrink-then-gate: level 1 whole + carol's budget-shrunk slice (2.90636636 BTC)", q6_r.totalFilled, 290_636_636);
truth("shrink-then-gate: two trades (carol filled, not cancelled)", q6_r.trades.size() == 2);
eqN("shrink-then-gate: no unfunded-maker notice", q6_unfunded, 0);
truth("shrink-then-gate: carol's ask still rests with its unfilled remainder",
  (switch (OB.getOrder(q6_s, q6_o.id)) { case (?o) { OB.isOpen(o) and OB.remaining(o) == 200_000_000 - 90_636_636 }; case null { false } }));
eqN("shrink-then-gate: carol delivered exactly the shrunk slice", Accounts.getBalance(q6_a, carol, base), 95_000_000 - 90_636_636);
truth("shrink-then-gate: spend ≤ budget", q6_r.quoteSpent <= qb_budget);
truth("shrink-then-gate: spend within a crumb of the budget", qb_budget - q6_r.quoteSpent < 200);
eqN("shrink-then-gate: taker got exactly what it paid for", Accounts.getBalance(q6_a, bob, base), q6_r.totalFilled);

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
let (lb_o, lb_t, _, lb_spent, lb_stop) = MX.executeLimitOrderProtected(
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
let (ln_o, _, _, ln_spent, ln_stop) = MX.executeLimitOrderProtected(
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
let (lu_o, lu_t, _, lu_spent, lu_stop) = MX.executeLimitOrderProtected(
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
let (lv_o, lv_t, _, lv_spent, lv_stop) = MX.executeLimitOrderProtected(
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
let (ll_o, ll_t, _, _, ll_stop) = MX.executeLimitOrderProtected(
  ll_s, ll_a, mkt, base, bob, #buy, #limit, 10_500_000_000, 300_000_000, 2, 2, // limit $105: crosses level 1 only
  mkFeeCtx(ll_a, ll_s, func(_) {}), null
);
truth("limit control: level-1 fill", ll_t.size() == 1);
eqN("limit control: filled level 1 (2 BTC)", ll_o.filled, 200_000_000);
truth("limit control: remainder RESTS open (unchanged semantics)", OB.isOpen(ll_o));
eqN("limit control: rested remainder (1 BTC)", OB.remaining(ll_o), 100_000_000);

// ════════════════════════════════════════════════════════════════════
// STOP REASON (task 1788465056, #55 silent "complete"). The 6th tuple
// element / MatchResult.stopReason says WHY the walk stopped, so a caller
// no longer guesses "budget spent" from a 1 bps crumb: #budgetExhausted is
// the engine's own verdict that not one more base unit fits under the
// budget; #filled / #bookExhausted / #slippage / #unfunded are the other
// stops, each distinguishable from a stop one unit further out.
// ════════════════════════════════════════════════════════════════════
Debug.print("── stop reason ──");
truth("stop: budget between levels → #budgetExhausted", lb_stop == #budgetExhausted);
truth("stop: null budget, book covers the qty → #filled", ln_stop == #filled);
truth("stop: null budget, unaffordable buyer (legacy break) → #unfunded", lu_stop == #unfunded);
truth("stop: budget == balance shrink-and-stop → #budgetExhausted (the budget is the tighter cap)", lv_stop == #budgetExhausted);
truth("stop: crossing #limit past its price → #slippage (the limit bounds the walk)", ll_stop == #slippage);
// Book exhausted: IOC #market for MORE than the two levels hold (4 BTC), no
// budget, ample balance ($1000 covers the $420 book) — the walk runs out of
// makers, not budget or balance.
let (lx_s, lx_a) = mkTwoLevelBook();
let (lx_o, lx_t, _, _, lx_stop) = MX.executeLimitOrderProtected(
  lx_s, lx_a, mkt, base, bob, #buy, #market, 11_000_000_000, 500_000_000, 2, 2,   // IOC buy 5 of a 4-deep book
  mkFeeCtx(lx_a, lx_s, func(_) {}), null
);
eqN("stop: book exhausted — filled the whole book (4 BTC)", lx_o.filled, 400_000_000);
truth("stop: book exhausted — two trades", lx_t.size() == 2);
truth("stop: book exhausted → #bookExhausted, not #filled", lx_stop == #bookExhausted);
// Market variant carries the same field: FOK + ample budget above filled fully.
truth("stop (market variant): full fill → #filled", qp_r.stopReason == #filled);
// Market variant, book-bound: no maker at all → #bookExhausted from the early return.
let lz_s = OB.emptyStore();
let lz_a = Accounts.emptyState();
Accounts.setBalance(lz_a, bob, QUOTE, 100_000_000_000);
let lz_r = MX.executeMarketOrderProtected(lz_s, lz_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 2, mkFeeCtx(lz_a, lz_s, func(_) {}), null, null);
truth("stop (market variant): empty book → #bookExhausted", lz_r.stopReason == #bookExhausted);

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
let (cl_o, cl_t, _) = MX.executeLimitOrder(cl_s, cl_a, mkt, base, bob, #buy, 10_000_000_000, (CAP + 4) * mq, 2);
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

// ════════════════════════════════════════════════════════════════════
// ZERO-COST SLICE (issue #54, task 1788465050 — latent below 1.0 quote).
// With a spend budget below one base unit's cost the affordability shrink
// floors fillQty to the affordable quantity, and at a price below 1.0 quote
// fillQty·price can floor to 0 quote (price 0.3: budget 2 base units → fee
// carve 1 → affordableQty = ⌊1e8/0.3e8⌋ = 3 → cost ⌊3×0.3⌋ = 0). Pre-fix
// the engine SETTLED that slice — base moved for zero quote, the budget
// never drew down, and the walk repeated it to the iteration cap (256
// zero-cost trades per call). Pinned: a zero-cost slice STOPS the walk at
// both engines (market + limit/IOC release) with nothing filled, nothing
// moved, and a truthful stop: the budget's own discriminator when the
// budget bound the slice (#budgetExhausted), the balance's (#unfunded)
// when the taker's balance did. All four live markets quote above 1.0
// ICPUSD today; this is the fence for the day a base trades below $1.
// ════════════════════════════════════════════════════════════════════
Debug.print("── zero-cost slice (#54) ──");

let subPrice : Nat = 30_000_000;                                 // $0.30 (×10^8)
func mkSubDollarBook() : (OB.OrderStore, Accounts.AccountState) {
  let s = OB.emptyStore();
  let a = Accounts.emptyState();
  Accounts.setBalance(a, alice, base, 100_000_000);             // 1 BTC maker
  Accounts.setBalance(a, bob, QUOTE, 100_000_000_000);          // 1000 ICPUSD taker
  ignore OB.createOrder(s, mkt, alice, #sell, #limit, subPrice, 100_000_000, 1); // 1 @ 0.30
  (s, a);
};

// (Z1) Market engine, budget of 2 base units (< one unit's cost after the
//      fee carve rounds it to 1 affordable quote unit): zero trades.
let (zm_s, zm_a) = mkSubDollarBook();
let zm_r = MX.executeMarketOrderProtected(zm_s, zm_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(zm_a, zm_s, func(_) {}), ?2, null);
eqN("zero-cost market: no trades settle (pre-fix: one per iteration to the 256 cap)", zm_r.trades.size(), 0);
eqN("zero-cost market: nothing filled", zm_r.totalFilled, 0);
eqN("zero-cost market: quoteSpent 0", zm_r.quoteSpent, 0);
eqN("zero-cost market: taker received no base", Accounts.getBalance(zm_a, bob, base), 0);
eqN("zero-cost market: maker kept its base", Accounts.getBalance(zm_a, alice, base), 100_000_000);
eqN("zero-cost market: maker still rests whole", OB.getLevelOrderCount(zm_s, mkt, #sell, subPrice), 1);
truth("zero-cost market: budget bound the slice → #budgetExhausted", zm_r.stopReason == #budgetExhausted);

// (Z2) Market engine, NULL budget, taker balance of 2 base units: the same
//      shrink fires off the balance → same stop, reported as #unfunded.
let (zb_s, zb_a) = mkSubDollarBook();
Accounts.setBalance(zb_a, bob, QUOTE, 2);
let zb_r = MX.executeMarketOrderProtected(zb_s, zb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(zb_a, zb_s, func(_) {}), null, null);
eqN("zero-cost market (balance-bound): no trades settle", zb_r.trades.size(), 0);
eqN("zero-cost market (balance-bound): taker received no base", Accounts.getBalance(zb_a, bob, base), 0);
truth("zero-cost market (balance-bound): balance bound the slice → #unfunded", zb_r.stopReason == #unfunded);

// (Z3) Limit engine, IOC #market release with the same 2-unit budget (the
//      staged direct-swap path): zero trades, nothing rests, nothing moves.
let (zl_s, zl_a) = mkSubDollarBook();
let (zl_o, zl_t, _, zl_spent, zl_stop) = MX.executeLimitOrderProtected(
  zl_s, zl_a, mkt, base, bob, #buy, #market, 33_000_000, 300_000_000, 2, 2,  // IOC buy 3, cap $0.33
  mkFeeCtx(zl_a, zl_s, func(_) {}), ?2
);
eqN("zero-cost limit/IOC: no trades settle (pre-fix: one per iteration to the 256 cap)", zl_t.size(), 0);
eqN("zero-cost limit/IOC: order filled 0", zl_o.filled, 0);
eqN("zero-cost limit/IOC: quoteSpent 0", zl_spent, 0);
eqN("zero-cost limit/IOC: taker received no base", Accounts.getBalance(zl_a, bob, base), 0);
eqN("zero-cost limit/IOC: maker kept its base", Accounts.getBalance(zl_a, alice, base), 100_000_000);
eqN("zero-cost limit/IOC: maker still rests whole", OB.getLevelOrderCount(zl_s, mkt, #sell, subPrice), 1);
truth("zero-cost limit/IOC: IOC — nothing rests", OB.findBestMatch(zl_s, mkt, #sell) == null);
truth("zero-cost limit/IOC: budget bound the slice → #budgetExhausted", zl_stop == #budgetExhausted);

// (Z4) Control: the same sub-dollar book with a budget that DOES cover whole
//      units converts normally — the fence is on zero-cost slices only.
let (zc_s, zc_a) = mkSubDollarBook();
let zc_r = MX.executeMarketOrderProtected(zc_s, zc_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 2, mkFeeCtx(zc_a, zc_s, func(_) {}), ?15_015_000_000, null); // $150.15 buys 500 BTC @ 0.30 — clamps to the 1 BTC maker
eqN("sub-dollar control: the whole 1 BTC maker fills", zc_r.totalFilled, 100_000_000);
eqN("sub-dollar control: cost 0.30 + 10 bps fee", zc_r.quoteSpent, 30_000_000 + 30_000);
truth("sub-dollar control: book exhausted, not a zero-cost stop", zc_r.stopReason == #bookExhausted);

// ════════════════════════════════════════════════════════════════════
// SUB-UNIT MAKER RESIDUE (task 1788497411, the #54 follow-up — latent below
// 1.0 quote). The #54 fence above breaks on EVERY zero-cost slice, but a
// slice is also zero-cost when the MAKER's available remaining is the dust:
// a budget-shrunk partial fill leaves e.g. 1 base unit resting at $0.30
// (placement is MIN_ORDER-gated, so only a partial fill can leave it).
// Pre-#54 that residue settled for zero quote and cleared itself (wrongly);
// with the break alone it sits at the top of the level and jams every
// taker on the side until its owner cancels. Pinned: when the taker's cap
// did NOT bind the slice (fillQty == availableForFill) the residue is
// treated like an unfunded maker — noticed, cancelled, walked past — at
// both engines; the taker-bound break (Z1-Z3) stays intact; a residue a
// pending match still holds is skipped, not cancelled.
// ════════════════════════════════════════════════════════════════════
Debug.print("── sub-unit maker residue (#54 follow-up) ──");

// alice rests 1 base UNIT @ 0.30 (the residue, first in time) ahead of a
// whole 1 BTC @ 0.30. Returns the residue's order id.
func mkResidueBook() : (OB.OrderStore, Accounts.AccountState, Nat) {
  let s = OB.emptyStore();
  let a = Accounts.emptyState();
  Accounts.setBalance(a, alice, base, 200_000_000);             // 2 BTC maker
  Accounts.setBalance(a, bob, QUOTE, 100_000_000_000);          // 1000 ICPUSD taker
  let dust = OB.createOrder(s, mkt, alice, #sell, #limit, subPrice, 1, 1);           // 1 unit @ 0.30
  ignore OB.createOrder(s, mkt, alice, #sell, #limit, subPrice, 100_000_000, 2);     // 1 BTC @ 0.30
  (s, a, dust.id);
};
func orderStatus(s : OB.OrderStore, id : Nat) : Types.OrderStatus {
  switch (OB.getOrder(s, id)) { case (?o) { o.status }; case null { Runtime.trap("order " # debug_show id # " missing") } };
};

// (R1) Market engine, ample budget: the residue is cancelled (one notice),
//      the whole-unit maker behind it fills, nothing moved for the dust.
let (rm_s, rm_a, rm_dust) = mkResidueBook();
var rm_notices : Nat = 0;
let rm_ctx : MX.ProtectionCtx = { mkFeeCtx(rm_a, rm_s, func(_) {}) with onUnfundedMaker = func(_, _, _, _, _) { rm_notices += 1 } };
let rm_r = MX.executeMarketOrderProtected(rm_s, rm_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 3, rm_ctx, ?15_015_000_000, null);
eqN("residue/market: one trade — the whole-unit maker behind the residue (pre-fix: 0, the residue jams)", rm_r.trades.size(), 1);
eqN("residue/market: filled 1 BTC", rm_r.totalFilled, 100_000_000);
eqN("residue/market: cost 0.30 + 10 bps fee", rm_r.quoteSpent, 30_000_000 + 30_000);
eqN("residue/market: taker got exactly 1 BTC (the dust unit never moved)", Accounts.getBalance(rm_a, bob, base), 100_000_000);
eqN("residue/market: maker kept the dust unit's base", Accounts.getBalance(rm_a, alice, base), 100_000_000);
truth("residue/market: the residue is #cancelled", orderStatus(rm_s, rm_dust) == #cancelled);
eqN("residue/market: owner noticed once (the residue, not the whole-unit maker)", rm_notices, 1);
eqN("residue/market: level clear (residue cancelled + maker filled)", OB.getLevelOrderCount(rm_s, mkt, #sell, subPrice), 0);
truth("residue/market: taker filled, not a zero-cost stop", rm_r.stopReason == #filled);

// (R2) Market engine, NULL budget (the balance-bound path): same outcome.
let (rn_s, rn_a, rn_dust) = mkResidueBook();
let rn_r = MX.executeMarketOrderProtected(rn_s, rn_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 3, mkFeeCtx(rn_a, rn_s, func(_) {}), null, null);
eqN("residue/market null budget: one trade", rn_r.trades.size(), 1);
eqN("residue/market null budget: filled 1 BTC", rn_r.totalFilled, 100_000_000);
truth("residue/market null budget: the residue is #cancelled", orderStatus(rn_s, rn_dust) == #cancelled);
truth("residue/market null budget: taker filled", rn_r.stopReason == #filled);

// (R3) Limit engine, resting #limit buy 1 BTC @ 0.33, null budget (the
//      byte-identical legacy path): the residue is cancelled, the maker fills.
let (rl_s, rl_a, rl_dust) = mkResidueBook();
var rl_notices : Nat = 0;
let rl_ctx : MX.ProtectionCtx = { mkFeeCtx(rl_a, rl_s, func(_) {}) with onUnfundedMaker = func(_, _, _, _, _) { rl_notices += 1 } };
let (rl_o, rl_t, _, rl_spent, rl_stop) = MX.executeLimitOrderProtected(
  rl_s, rl_a, mkt, base, bob, #buy, #limit, 33_000_000, 100_000_000, 3, 3, rl_ctx, null
);
eqN("residue/limit: one trade (pre-fix: 0, the residue jams)", rl_t.size(), 1);
eqN("residue/limit: order filled 1 BTC", rl_o.filled, 100_000_000);
truth("residue/limit: order #filled", rl_o.status == #filled);
eqN("residue/limit: cost 0.30 + 10 bps fee", rl_spent, 30_000_000 + 30_000);
eqN("residue/limit: maker kept the dust unit's base", Accounts.getBalance(rl_a, alice, base), 100_000_000);
truth("residue/limit: the residue is #cancelled", orderStatus(rl_s, rl_dust) == #cancelled);
eqN("residue/limit: owner noticed once", rl_notices, 1);
eqN("residue/limit: level clear", OB.getLevelOrderCount(rl_s, mkt, #sell, subPrice), 0);
truth("residue/limit: taker filled", rl_stop == #filled);

// (R4) Residue ahead AND a dust budget (2 quote units): the residue is still
//      cleared, then the taker-bound break fires at the whole-unit maker —
//      nothing settles, #budgetExhausted, the #54 break intact.
let (rb_s, rb_a, rb_dust) = mkResidueBook();
let rb_r = MX.executeMarketOrderProtected(rb_s, rb_a, mkt, base, bob, #buy, 300_000_000, 10_000_000, false, 3, mkFeeCtx(rb_a, rb_s, func(_) {}), ?2, null);
eqN("residue + dust budget: no trades settle", rb_r.trades.size(), 0);
eqN("residue + dust budget: taker received no base", Accounts.getBalance(rb_a, bob, base), 0);
truth("residue + dust budget: the residue is still cleared", orderStatus(rb_s, rb_dust) == #cancelled);
eqN("residue + dust budget: the whole-unit maker still rests", OB.getLevelOrderCount(rb_s, mkt, #sell, subPrice), 1);
truth("residue + dust budget: budget bound the next slice → #budgetExhausted", rb_r.stopReason == #budgetExhausted);

// (R5 — RETIRED with the PendingMatch machinery, task 1788516198.) It pinned
//      "a residue a PENDING match still holds is skipped, never cancelled";
//      with getMakerPending gone the engine has no pending lock to honour,
//      so a maker-bound zero-cost residue is always cleared (R1-R4 above).

// ════════════════════════════════════════════════════════════════════
// H-10 (F13) — a SWEPT resting order (#swept aggressor role) whose owner cannot
// fund a slice is treated as an unfunded maker: ONE notice, the unfundable
// remainder CANCELLED (never re-rested), fills that ARE funded still settle.
// Pre-fix the engine broke silently and re-created the full quantity under
// a fresh id (the "re-homed every 2 s" loop). Book: alice rests the
// opposite side, 1 BTC @ 100; bob is the swept order re-submitted as the
// aggressor at 100 for 1 BTC.
// ════════════════════════════════════════════════════════════════════
Debug.print("── H-10: unfunded swept aggressor ──");
let hPrice : Nat = 10_000_000_000;   // $100
let hQty   : Nat = 100_000_000;      // 1 BTC
func mkSweepBook(makerSide : Types.Side) : (OB.OrderStore, Accounts.AccountState, Types.Order) {
  let st = OB.emptyStore();
  let ac = Accounts.emptyState();
  switch (makerSide) {
    case (#sell) { Accounts.setBalance(ac, alice, base, hQty) };
    case (#buy)  { Accounts.setBalance(ac, alice, QUOTE, 2 * hPrice) };   // plenty for cost + maker fee
  };
  (st, ac, OB.createOrder(st, mkt, alice, makerSide, #limit, hPrice, hQty, 1));
};
type Notice = { owner : Principal; side : Types.Side; qty : Nat };
func mkSweepCtx(ac : Accounts.AccountState, st : OB.OrderStore, log : [var ?Notice], n : [var Nat]) : MX.ProtectionCtx = {
  mkFeeCtx(ac, st, func(_) {}) with
  aggressorRole    = #swept({ makerVs = func(_) { true } });   // every maker here plays the AMM
  onUnfundedMaker  = func(_, owner, side, _, qty) { log[0] := ?{ owner; side; qty }; n[0] += 1 };
};

// (H1) Swept BID, owner has NOTHING (balance moved out): no trade, nothing
//      re-rests (id 0, #cancelled), exactly one notice naming the owner and
//      the whole quantity, the maker untouched.
let (h1_s, h1_a, h1_mk) = mkSweepBook(#sell);
let h1_log : [var ?Notice] = [var null]; let h1_n : [var Nat] = [var 0];
let (h1_o, h1_t, _, _, h1_stop) = MX.executeLimitOrderProtected(
  h1_s, h1_a, mkt, base, bob, #buy, #limit, hPrice, hQty, 1, 5, mkSweepCtx(h1_a, h1_s, h1_log, h1_n),
  ?Accounts.getBalance(h1_a, bob, QUOTE));   // the sweep passes the owner's available quote as the budget
eqN("H1 unfunded swept bid: no trades", h1_t.size(), 0);
eqN("H1 unfunded swept bid: nothing re-rested (id 0)", h1_o.id, 0);
truth("H1 unfunded swept bid: result is #cancelled", h1_o.status == #cancelled);
eqN("H1 unfunded swept bid: owner has no open order", OB.getUserOpenOrders(h1_s, bob).size(), 0);
eqN("H1 unfunded swept bid: exactly ONE notice", h1_n[0], 1);
switch (h1_log[0]) {
  case (?nt) {
    truth("H1 notice names the swept OWNER", Principal.equal(nt.owner, bob));
    truth("H1 notice carries the swept side (#buy)", nt.side == #buy);
    eqN("H1 notice reports the whole dropped quantity", nt.qty, hQty);
  };
  case null { Runtime.trap("FAIL: H1 — no notice recorded") };
};
truth("H1 unfunded swept bid: the maker still rests, untouched", orderStatus(h1_s, h1_mk.id) == #open);
truth("H1 unfunded swept bid: stop = #budgetExhausted/#unfunded (budget == balance)", h1_stop == #budgetExhausted or h1_stop == #unfunded);

// (H2) Swept BID, owner can fund HALF (cost 50 + 5 bps maker fee, zero
//      headroom): the funded half settles at the maker's price, the
//      unfundable half is CANCELLED (record #cancelled, filled 0.5 of 1.0,
//      under the pre-reserved id the trade references), one notice for the
//      0.5 dropped, the maker keeps its other half resting.
let (h2_s, h2_a, h2_mk) = mkSweepBook(#sell);
let h2_half : Nat = 5_000_000_000;                // 0.5 BTC × $100
Accounts.setBalance(h2_a, bob, QUOTE, h2_half + (h2_half * 5) / 10_000);
let h2_log : [var ?Notice] = [var null]; let h2_n : [var Nat] = [var 0];
let (h2_o, h2_t, _, _, _) = MX.executeLimitOrderProtected(
  h2_s, h2_a, mkt, base, bob, #buy, #limit, hPrice, hQty, 1, 5, mkSweepCtx(h2_a, h2_s, h2_log, h2_n),
  ?Accounts.getBalance(h2_a, bob, QUOTE));
eqN("H2 half-funded swept bid: one trade", h2_t.size(), 1);
eqN("H2 half-funded swept bid: filled the funded 0.5", h2_o.filled, hQty / 2);
eqN("H2 half-funded swept bid: record keeps the requested 1.0", h2_o.quantity, hQty);
truth("H2 half-funded swept bid: record is #cancelled (partial, then dropped)", h2_o.status == #cancelled);
truth("H2 half-funded swept bid: record carries the pre-reserved id the trade references", h2_o.id != 0 and h2_t[0].buyOrderId == h2_o.id);
truth("H2 half-funded swept bid: stored under that id, closed", orderStatus(h2_s, h2_o.id) == #cancelled);
eqN("H2 half-funded swept bid: owner has no open order (nothing re-rested)", OB.getUserOpenOrders(h2_s, bob).size(), 0);
eqN("H2 half-funded swept bid: owner received 0.5 BTC", Accounts.getBalance(h2_a, bob, base), hQty / 2);
eqN("H2 half-funded swept bid: owner's quote fully spent (cost + maker fee)", Accounts.getBalance(h2_a, bob, QUOTE), 0);
eqN("H2 half-funded swept bid: exactly ONE notice", h2_n[0], 1);
switch (h2_log[0]) { case (?nt) { eqN("H2 notice reports the DROPPED remainder (0.5)", nt.qty, hQty / 2) }; case null { Runtime.trap("FAIL: H2 — no notice") } };
truth("H2 half-funded swept bid: the maker keeps its other half resting", orderStatus(h2_s, h2_mk.id) == #partiallyFilled);

// (H3) Swept ASK, owner has NO base: no trade, id 0, #cancelled, one notice.
let (h3_s, h3_a, h3_mk) = mkSweepBook(#buy);
let h3_log : [var ?Notice] = [var null]; let h3_n : [var Nat] = [var 0];
let (h3_o, h3_t, _, _, _) = MX.executeLimitOrderProtected(
  h3_s, h3_a, mkt, base, bob, #sell, #limit, hPrice, hQty, 1, 5, mkSweepCtx(h3_a, h3_s, h3_log, h3_n), null);
eqN("H3 unfunded swept ask: no trades", h3_t.size(), 0);
eqN("H3 unfunded swept ask: nothing re-rested (id 0)", h3_o.id, 0);
truth("H3 unfunded swept ask: #cancelled", h3_o.status == #cancelled);
eqN("H3 unfunded swept ask: owner has no open order", OB.getUserOpenOrders(h3_s, bob).size(), 0);
eqN("H3 unfunded swept ask: exactly ONE notice", h3_n[0], 1);
switch (h3_log[0]) { case (?nt) { truth("H3 notice side is #sell", nt.side == #sell); eqN("H3 notice qty = whole", nt.qty, hQty) }; case null { Runtime.trap("FAIL: H3 — no notice") } };
truth("H3 unfunded swept ask: the maker still rests", orderStatus(h3_s, h3_mk.id) == #open);

// (H4) Swept ASK, owner holds 0.4 BTC of the 1.0: 0.4 settles (the base-side
//      shrink), the 0.6 is cancelled with one notice.
let (h4_s, h4_a, _) = mkSweepBook(#buy);
Accounts.setBalance(h4_a, bob, base, 40_000_000);
let h4_log : [var ?Notice] = [var null]; let h4_n : [var Nat] = [var 0];
let (h4_o, h4_t, _, _, _) = MX.executeLimitOrderProtected(
  h4_s, h4_a, mkt, base, bob, #sell, #limit, hPrice, hQty, 1, 5, mkSweepCtx(h4_a, h4_s, h4_log, h4_n), null);
eqN("H4 part-funded swept ask: one trade", h4_t.size(), 1);
eqN("H4 part-funded swept ask: filled the deliverable 0.4", h4_o.filled, 40_000_000);
truth("H4 part-funded swept ask: #cancelled after the partial", h4_o.status == #cancelled);
eqN("H4 part-funded swept ask: owner delivered all 0.4", Accounts.getBalance(h4_a, bob, base), 0);
eqN("H4 part-funded swept ask: owner has no open order", OB.getUserOpenOrders(h4_s, bob).size(), 0);
eqN("H4 part-funded swept ask: exactly ONE notice", h4_n[0], 1);
switch (h4_log[0]) { case (?nt) { eqN("H4 notice reports the dropped 0.6", nt.qty, 60_000_000) }; case null { Runtime.trap("FAIL: H4 — no notice") } };

// (H5) Scope pin — a plain TAKER (aggressorRole = #taker) that cannot fund
//      its slice keeps the LEGACY contract: no notice, remainder RESTS at the
//      full quantity under a fresh id. H-10 changes the sweep only.
let (h5_s, h5_a, h5_mk) = mkSweepBook(#sell);
var h5_n : Nat = 0;
let h5_ctx : MX.ProtectionCtx = { mkFeeCtx(h5_a, h5_s, func(_) {}) with onUnfundedMaker = func(_, _, _, _, _) { h5_n += 1 } };
let (h5_o, h5_t, _, _, _) = MX.executeLimitOrderProtected(h5_s, h5_a, mkt, base, bob, #buy, #limit, hPrice, hQty, 1, 5, h5_ctx, null);
eqN("H5 legacy taker: no trades", h5_t.size(), 0);
truth("H5 legacy taker: remainder RESTS (fresh id, #open, full qty)", h5_o.id != 0 and h5_o.status == #open and OB.remaining(h5_o) == hQty);
eqN("H5 legacy taker: no notice", h5_n, 0);
truth("H5 legacy taker: maker untouched", orderStatus(h5_s, h5_mk.id) == #open);

// (H6) A FUNDED sweep is unchanged: fills in full, #filled under the
//      pre-reserved id, no notice.
let (h6_s, h6_a, _) = mkSweepBook(#sell);
Accounts.setBalance(h6_a, bob, QUOTE, 2 * hPrice);
let h6_log : [var ?Notice] = [var null]; let h6_n : [var Nat] = [var 0];
let (h6_o, h6_t, _, _, h6_stop) = MX.executeLimitOrderProtected(
  h6_s, h6_a, mkt, base, bob, #buy, #limit, hPrice, hQty, 1, 5, mkSweepCtx(h6_a, h6_s, h6_log, h6_n),
  ?Accounts.getBalance(h6_a, bob, QUOTE));
eqN("H6 funded sweep: one trade", h6_t.size(), 1);
truth("H6 funded sweep: #filled under the pre-reserved id", h6_o.id != 0 and h6_o.status == #filled and h6_t[0].buyOrderId == h6_o.id);
eqN("H6 funded sweep: no notice", h6_n[0], 0);
truth("H6 funded sweep: stop = #filled", h6_stop == #filled);

// ════════════════════════════════════════════════════════════════════
// H-20 (F14): the absolute priceCap intersects the slippage band. The band's
// reference is the book's best crossable maker — a lowball bid resting alone
// is that reference, and a band anchored to it admits the lowball itself. A
// caller passing a mid-anchored cap gets a walk that never prints past it,
// on the live walk and on the FOK pre-check alike; a cap OUTSIDE the band is
// a no-op (the band only ever tightens).
// ════════════════════════════════════════════════════════════════════
Debug.print("── H-20 priceCap ──");
// Sell taker, lone lowball bid at 70 (mid 100). Band alone (10%): floor 63 →
// the lowball fills. Cap = mid×0.8 = 80 → floor 80 → nothing fills, #slippage.
let pc_s = OB.emptyStore();
let pc_a = Accounts.emptyState();
Accounts.setBalance(pc_a, alice, QUOTE, 100_000_000_000);   // lowball bidder, funded
Accounts.setBalance(pc_a, bob, base, 500_000_000);          // seller holds 5 BTC
ignore OB.createOrder(pc_s, mkt, alice, #buy, #limit, 7_000_000_000, 100_000_000, 1); // bid 1 @ 70
let pc_r0 = MX.executeMarketOrderProtected(pc_s, pc_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, false, 2, mkFeeCtx(pc_a, pc_s, func(_) {}), null, ?8_000_000_000);
eqN("priceCap sell: lowball 70 below the 80 floor — nothing filled", pc_r0.totalFilled, 0);
truth("priceCap sell: stop = #slippage (the bid sits past the floor)", pc_r0.stopReason == #slippage);
eqN("priceCap sell: seller base untouched", Accounts.getBalance(pc_a, bob, base), 500_000_000);
// FOK pre-check honours the cap too.
let pc_r1 = MX.executeMarketOrderProtected(pc_s, pc_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, true, 3, mkFeeCtx(pc_a, pc_s, func(_) {}), null, ?8_000_000_000);
eqN("priceCap FOK sell: killed at the cap (nothing filled)", pc_r1.totalFilled, 0);
// A floor BELOW the band's own floor is a no-op: cap 50 → floor stays 63 → the
// lowball at 70 fills as before.
let pc_r2 = MX.executeMarketOrderProtected(pc_s, pc_a, mkt, base, bob, #sell, 100_000_000, 10_000_000, false, 4, mkFeeCtx(pc_a, pc_s, func(_) {}), null, ?5_000_000_000);
eqN("priceCap sell: a cap outside the band is a no-op — the 70 bid fills", pc_r2.totalFilled, 100_000_000);
// Buy mirror: lone far ask at 130 (mid 100). Band (10%) off 130 → ceiling 143
// admits it; cap = mid×1.2 = 120 → nothing fills.
let pb_s = OB.emptyStore();
let pb_a = Accounts.emptyState();
Accounts.setBalance(pb_a, alice, base, 100_000_000);
Accounts.setBalance(pb_a, bob, QUOTE, 100_000_000_000);
ignore OB.createOrder(pb_s, mkt, alice, #sell, #limit, 13_000_000_000, 100_000_000, 1); // ask 1 @ 130
let pb_r0 = MX.executeMarketOrderProtected(pb_s, pb_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 2, mkFeeCtx(pb_a, pb_s, func(_) {}), null, ?12_000_000_000);
eqN("priceCap buy: far ask 130 above the 120 ceiling — nothing filled", pb_r0.totalFilled, 0);
truth("priceCap buy: stop = #slippage", pb_r0.stopReason == #slippage);
let pb_r1 = MX.executeMarketOrderProtected(pb_s, pb_a, mkt, base, bob, #buy, 100_000_000, 10_000_000, false, 3, mkFeeCtx(pb_a, pb_s, func(_) {}), null, null);
eqN("priceCap buy: null cap keeps the legacy band — the 130 ask fills", pb_r1.totalFilled, 100_000_000);

Debug.print("── MatchingEngine.test PASSED ──");
