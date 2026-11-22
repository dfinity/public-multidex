// Pure-function unit tests for src/backend/lib/LiquidityManager.mo in integer
// base units (10^8) — validateNewOrder, the pre-trade risk gate. Pins: a valid
// order passes; buys are checked against SPENDABLE (available) cash, not raw
// balance; the minimum-order-value floor; the per-market 2.5× cap; and the
// sell-side asset/min checks. Prices ×10^8 ($100 = 10_000_000_000); qty ×10^8.

import LM "../src/backend/lib/LiquidityManager";
import OB "../src/backend/lib/OrderBook";
import ME "../src/backend/lib/MarginEngine";
import Accounts "../src/backend/lib/Accounts";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
func isOk(r : { #ok; #err : Text }) : Bool { switch (r) { case (#ok) { true }; case (#err(_)) { false } } };
let alice = Principal.fromText("2vxsx-fae");
let mkt = "BTC-ICPUSD";
func px(t : Types.TokenId) : ?Nat { switch (t) { case ("BTC") { ?10_000_000_000_000 }; case (_) { null } } }; // $100000

Debug.print("── LiquidityManager.test ──");

// alice: 1000 ICPUSD + 5 BTC. Full availability (no locks).
let acc = Accounts.emptyState();
Accounts.setBalance(acc, alice, Types.QUOTE_TOKEN, 100_000_000_000); // 1000 ICPUSD
Accounts.setBalance(acc, alice, "BTC", 500_000_000);                // 5 BTC
let mg = ME.emptyState();
func availFull(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(acc, u, t) };
func availHalf(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(acc, u, t) / 2 };
let store = OB.emptyStore();

// ── BUY ── (price $100 = 10_000_000_000)
// valid: value 400 ≤ 1000 cash, ≥ min, within caps
truth("buy: valid → ok", isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 400_000_000)));
// insufficient: value 1500 > 1000 cash
truth("buy: insufficient cash → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 1_500_000_000)));
// below min: value 0.5 < 1.0
truth("buy: below min → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000, 500_000_000)));
// gated by AVAILABLE, not raw balance: value 600 ≤ balance(1000) but > available(500)
truth("buy: uses spendable not balance", not isOk(LM.validateNewOrder(store, acc, mg, px, availHalf, alice, mkt, "BTC", #buy, 10_000_000_000, 600_000_000)));

// per-market 2.5× cap: pre-stack a 2400-value buy; +200 → 2600 > 1000×2.5
let capStore = OB.emptyStore();
ignore OB.createOrder(capStore, mkt, alice, #buy, #limit, 10_000_000_000, 2_400_000_000, 1);
truth("buy: per-market 2.5× cap → err", not isOk(LM.validateNewOrder(capStore, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 200_000_000)));
// (#50.3) The cap message speaks human: "2.5x", never the raw e8 constant
// "250000000x" — the number is FOR the person whose order was just refused.
truth("buy: cap message prints 2.5x, not the raw fixed-point constant",
  switch (LM.validateNewOrder(capStore, acc, mg, px, availFull, alice, mkt, "BTC", #buy, 10_000_000_000, 200_000_000)) {
    case (#err(m)) { Text.contains(m, #text "2.5x") and not Text.contains(m, #text "250000000") };
    case (#ok) { false };
  });

// ── SELL ──
// valid: 3 BTC ≤ 5, value 300 ≥ min
truth("sell: valid → ok", isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 300_000_000)));
// insufficient asset: 10 > 5
truth("sell: insufficient asset → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 1_000_000_000)));
// below min: 0.001 × 100 = 0.1 < 1.0
truth("sell: below min → err", not isOk(LM.validateNewOrder(store, acc, mg, px, availFull, alice, mkt, "BTC", #sell, 10_000_000_000, 100_000)));

// ── levelCapCheck (GHSA-97xp): aggregate per-(side,price) congestion cap ──
// The counter is aggregate across ALL owners at the level, side-scoped, and
// REJECTS new placements at the cap (never evicts). validateNewOrder runs it
// FIRST; main.mo's margin paths call it directly with a (possibly dev-hook
// lowered) cap.
let lvlStore = OB.emptyStore();
let bob = Principal.fromText("aaaaa-aa");
ignore OB.createOrder(lvlStore, mkt, alice, #buy, #limit, 10_000_000_000, 20_000_000, 1);
ignore OB.createOrder(lvlStore, mkt, bob,   #buy, #limit, 10_000_000_000, 20_000_000, 2);
truth("levelCap: under cap → null", LM.levelCapCheck(lvlStore, mkt, #buy, 10_000_000_000, 3) == null);
truth("levelCap: at cap → rejects (aggregate across owners, not per-owner)",
  LM.levelCapCheck(lvlStore, mkt, #buy, 10_000_000_000, 2) != null);
truth("levelCap: side-scoped — stacked bids never block a sell at the price",
  LM.levelCapCheck(lvlStore, mkt, #sell, 10_000_000_000, 2) == null);
truth("levelCap: other price levels stay free",
  LM.levelCapCheck(lvlStore, mkt, #buy, 10_000_000_001, 2) == null);
// validateNewOrder threads the production constant: a level holding
// MAX_ORDERS_PER_PRICE_LEVEL rejects even a fully funded order. (Drive it via
// the cheap direct check at cap 2 above; here pin only the wiring message.)
truth("levelCap: message names the price-level congestion bound",
  switch (LM.levelCapCheck(lvlStore, mkt, #buy, 10_000_000_000, 2)) {
    case (?e) { Text.contains(e, #text "Price level full") };
    case null { false };
  });

// ── adjustUserOrders: below-min cancel fallback must not underflow ──
// Regression (2026-07-09): the per-market shrink loop's below-MIN_ORDER
// fallback ran `excess -= orderValue` inside the branch where orderValue >
// excess is guaranteed — a certain Nat-underflow trap that rolled back the
// caller (the post-settlement sweep). Scenario: cap = 2.5 × $100 = $250;
// resting buys $85+$85+$73+$30 = $273 → excess $23; the newest ($30) order
// shrinks to $7 < $10 min → cancel path → excess must clamp to 0, not trap.
let adjAcc = Accounts.emptyState();
Accounts.setBalance(adjAcc, alice, Types.QUOTE_TOKEN, 10_000_000_000); // $100
let adjStore = OB.emptyStore();
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 1); // $85
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 2); // $85
ignore OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 73_000_000, 3); // $73
let newest = OB.createOrder(adjStore, mkt, alice, #buy, #limit, 10_000_000_000, 30_000_000, 4); // $30 — walked first
func availAdj(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(adjAcc, u, t) };
let adjs = LM.adjustUserOrders(adjStore, adjAcc, mg, px, availAdj, alice, [(mkt, "BTC")], 5);
truth("site adjustBuyOrders: below-min cancel fallback doesn't trap", adjs.size() > 0);
truth("site adjustBuyOrders: sub-min order cancelled", switch (OB.getOrder(adjStore, newest.id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
truth("site adjustBuyOrders: gross buy back under the 2.5x cap", OB.getUserMarketBuyTotal(adjStore, alice, mkt) <= 25_000_000_000);

// ── W5-13: the SAME below-min fix exists at three sites; pin the other two ──
// (#38.4) The 2026-07-09 `excess := 0` fix has three copies. The fixture
// above drives adjustBuyOrders' step-2 walk (site ~:351). The reporter
// showed reverting either OTHER copy leaves the suite green. These two
// fixtures drive each remaining branch specifically.

// SITE adjustSellOrders (~:428): per-market sell total over 2.5× the base
// holding, newest order's shrink lands under $10 min → whole-cancel path.
// balance 1.0 BTC → qty cap 2.5; sells 1.0 + 1.0 + 0.41 + 0.30 = 2.71 →
// excess 0.21; newest (0.30) > excess → post-shrink 0.09 @ $100 = $9 < $10
// → cancel + excess := 0. Reverting to `excess -= rem` is 0.21 − 0.30: trap.
let sellAcc = Accounts.emptyState();
Accounts.setBalance(sellAcc, alice, "BTC", 100_000_000);                 // 1.0 BTC
Accounts.setBalance(sellAcc, alice, Types.QUOTE_TOKEN, 0);
let sellStore = OB.emptyStore();
ignore OB.createOrder(sellStore, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1);
ignore OB.createOrder(sellStore, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 2);
ignore OB.createOrder(sellStore, mkt, alice, #sell, #limit, 10_000_000_000, 41_000_000, 3);
let sellNewest = OB.createOrder(sellStore, mkt, alice, #sell, #limit, 10_000_000_000, 30_000_000, 4);
func availSell(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(sellAcc, u, t) };
let sellAdjs = LM.adjustUserOrders(sellStore, sellAcc, mg, px, availSell, alice, [(mkt, "BTC")], 6);
truth("site adjustSellOrders: below-min cancel fallback doesn\'t trap", sellAdjs.size() > 0);
truth("site adjustSellOrders: sub-min shrink became a whole cancel",
  switch (OB.getOrder(sellStore, sellNewest.id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
truth("site adjustSellOrders: sell total back under 2.5× holdings",
  OB.getUserMarketSellTotal(sellStore, alice, mkt) <= 250_000_000);

// SITE enforceCrossMarketBidCap (~:231): each market under its own 2.5×cash
// cap, COMBINED gross over the 3.0×cash maxGross. The below-min branch here
// fires only when the SURVIVING orders land within $10 of the cap (the
// shrink fills exactly to it), so three markets: cash $100 → maxGross $300;
// m1 $245 + m3 $47 survive = $292, room $8 < $10 min. Walk newest-first:
// id6 $92 ≤ excess $179 → clean cancel (excess $87); id5 $95 > $87 →
// post-shrink 0.08 @ $100 = $8 < $10 → cancel + excess := 0.
// Reverting is $87 − $95: trap.
let xmAcc = Accounts.emptyState();
Accounts.setBalance(xmAcc, alice, Types.QUOTE_TOKEN, 10_000_000_000);    // $100
let xmStore = OB.emptyStore();
let mkt2 = "ETH-ICPUSD";
let mkt3 = "SOL-ICPUSD";
ignore OB.createOrder(xmStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 1);
ignore OB.createOrder(xmStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 2);
ignore OB.createOrder(xmStore, mkt, alice, #buy, #limit, 10_000_000_000, 75_000_000, 3);
let xmOld = OB.createOrder(xmStore, mkt3, alice, #buy, #limit, 10_000_000_000, 47_000_000, 4);
let xmShrunk = OB.createOrder(xmStore, mkt2, alice, #buy, #limit, 10_000_000_000, 95_000_000, 5);
let xmNewest = OB.createOrder(xmStore, mkt2, alice, #buy, #limit, 10_000_000_000, 92_000_000, 6);
func availXm(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(xmAcc, u, t) };
let xmAdjs = LM.adjustUserOrders(xmStore, xmAcc, mg, px, availXm, alice,
  [(mkt, "BTC"), (mkt2, "ETH"), (mkt3, "SOL")], 7);
truth("site enforceCrossMarketBidCap: below-min cancel fallback doesn\'t trap", xmAdjs.size() > 0);
truth("site enforceCrossMarketBidCap: newest cancelled outright (≤ excess)",
  switch (OB.getOrder(xmStore, xmNewest.id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
truth("site enforceCrossMarketBidCap: sub-min shrink became a whole cancel",
  switch (OB.getOrder(xmStore, xmShrunk.id)) { case (?o) { not OB.isOpen(o) }; case null { true } });
truth("site enforceCrossMarketBidCap: older small order survives (walk stopped at zero)",
  switch (OB.getOrder(xmStore, xmOld.id)) { case (?o) { OB.isOpen(o) }; case null { false } });
truth("site enforceCrossMarketBidCap: cross-market gross back under the cap",
  OB.getUserGrossBuyValue(xmStore, alice) <= 30_000_000_000);

// ── Adjustment reasons (task 1787199451, #50 follow-up): every record names
// the WALK that touched the order. Per-branch: the three fixtures above each
// drive exactly one walk, so their records must carry that walk's tag —
// including below-min escalation cancels, which keep the walk's reason
// (`cancelled` records the escalation itself). Two fresh fixtures drive the
// step-1 balance walks, which the cap fixtures never enter.
func allReason(rs : [Types.OrderAdjustment], want : Types.AdjustmentReason) : Bool {
  if (rs.size() == 0) { return false };
  for (a in rs.vals()) { if (a.reason != ?want) { return false } };
  true
};
truth("reason: per-market buy walk records #marketCapExceeded (cancel + below-min escalation included)",
  allReason(adjs, #marketCapExceeded));
truth("reason: per-market sell walk records #marketCapExceeded",
  allReason(sellAdjs, #marketCapExceeded));
truth("reason: cross-market walk records #crossMarketCapExceeded",
  allReason(xmAdjs, #crossMarketCapExceeded));

// step-1 BUY balance walk: cash $50 covers only part of an $85 resting bid →
// shrink to the $50 the balance still covers → #balanceShrank, not cancelled.
let bsAcc = Accounts.emptyState();
Accounts.setBalance(bsAcc, alice, Types.QUOTE_TOKEN, 5_000_000_000);        // $50
let bsStore = OB.emptyStore();
let bsOrder = OB.createOrder(bsStore, mkt, alice, #buy, #limit, 10_000_000_000, 85_000_000, 1); // $85
func availBs(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(bsAcc, u, t) };
let bsAdjs = LM.adjustUserOrders(bsStore, bsAcc, mg, px, availBs, alice, [(mkt, "BTC")], 8);
truth("reason: buy step-1 balance walk records #balanceShrank",
  allReason(bsAdjs, #balanceShrank));
truth("reason: buy step-1 record is a shrink, not a cancel",
  bsAdjs.size() == 1 and not bsAdjs[0].cancelled and bsAdjs[0].orderId == bsOrder.id);

// step-1 SELL balance walk: 0.5 BTC no longer covers a 1.0 BTC resting ask →
// shrink to the holding → #balanceShrank.
let ssAcc = Accounts.emptyState();
Accounts.setBalance(ssAcc, alice, "BTC", 50_000_000);                        // 0.5 BTC
let ssStore = OB.emptyStore();
ignore OB.createOrder(ssStore, mkt, alice, #sell, #limit, 10_000_000_000, 100_000_000, 1); // 1.0 BTC
func availSs(u : Principal, t : Types.TokenId) : Nat { Accounts.getBalance(ssAcc, u, t) };
let ssAdjs = LM.adjustUserOrders(ssStore, ssAcc, mg, px, availSs, alice, [(mkt, "BTC")], 9);
truth("reason: sell step-1 balance walk records #balanceShrank",
  allReason(ssAdjs, #balanceShrank));

Debug.print("── LiquidityManager.test PASSED ──");
