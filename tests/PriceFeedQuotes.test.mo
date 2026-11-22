// Unit tests for PriceFeed.aggregateByQuote (W3-05) — the USD/USDT split.
//
// Pooling USD- and USDT-quoted venues into one median averaged a USDT depeg
// away: the blend moved, the (then USDT-quoted) anchor moved with it, and
// the dispersion gate saw agreement. Per-quote grouping makes the group
// divergence THE depeg signal. The mark follows the USD group only when that
// group is ROBUST on its own (surviving count ≥ the caller's floor); a USD
// group below the floor cannot override the pooled trim — it could never pass
// the floor it was handing the mark to (issue #55 "oracle split": with two USD
// venues every divergence froze the mark on six healthy venues). Every
// fixture here composes the decision with the floor it is judged against.
// The integration side (real fetches) cannot inject a depeg; this drives the
// pure combine logic with synthetic readings.

import PriceFeed "../src/backend/lib/PriceFeed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Float "mo:core/Float";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

func src(id : Text, quote : PriceFeed.QuoteAsset) : PriceFeed.Source {
  { id; quote; urlTemplate = "https://example.invalid/{asset}"; kind = #binance; maxResponseBytes = 8_192 };
};
// Two USD venues + three USDT — the small fixture; and the shipped fleet's
// shape: two USD (coinbase, coingecko) + six USDT.
let SOURCES : [PriceFeed.Source] = [
  src("usd-a", #usd), src("usd-b", #usd), src("usd-c", #usd),
  src("t-a", #usdt), src("t-b", #usdt), src("t-c", #usdt),
  src("t-d", #usdt), src("t-e", #usdt), src("t-f", #usdt),
];
func rd(id : Text, price : Float) : PriceFeed.Reading {
  { sourceId = id; asset = "ICP"; price; fetchedAtNs = 1_000; ok = true; errMessage = null };
};
// The production floor: PRICE_MIN_SOURCES = MIN_ROBUST_SOURCES (3), and the
// dev override can only RAISE it (setTestMinSources refuses lower).
let FLOOR = PriceFeed.MIN_ROBUST_SOURCES;
let THRESHOLD = 100;   // USDT_DEPEG_ALARM_BPS

Debug.print("── PriceFeedQuotes.test ──");

// ── agreement: pooled, maximal sources, no signal ──
let agree = [rd("usd-a", 3.00), rd("usd-b", 3.01), rd("t-a", 3.00), rd("t-b", 3.01), rd("t-c", 2.99)];
let a = PriceFeed.aggregateByQuote("ICP", agree, SOURCES, 42, THRESHOLD, FLOOR);
truth("agreement: not diverged", not a.diverged);
truth("agreement: pooled source count (5)", a.agg.sourceCount == 5);
truth("agreement: both groups counted", a.usdCount == 2 and a.usdtCount == 3);
truth("agreement: depeg ≈ 0", a.depegBps < 20);
truth("agreement: mark basis is the pool", a.mark == #pooled);

// ── USDT depeg with a ROBUST USD group: the mark follows USD, signal reported ──
// Three USD venues reach the floor on their own, so the USD group may override
// the pool — this is the branch "the mark follows the USD group" and it is
// reachable at the real floor only with ≥ 3 USD venues.
let depeg3 = [rd("usd-a", 3.00), rd("usd-b", 3.01), rd("usd-c", 3.00),
              rd("t-a", 3.31), rd("t-b", 3.30), rd("t-c", 3.32)];
let d = PriceFeed.aggregateByQuote("ICP", depeg3, SOURCES, 42, THRESHOLD, FLOOR);
truth("depeg/robust USD: DIVERGED", d.diverged);
truth("depeg/robust USD: magnitude ≈ 1000bps", d.depegBps > 900 and d.depegBps < 1100);
truth("depeg/robust USD: mark basis is the USD group", d.mark == #usdGroup);
truth("depeg/robust USD: the mark is the USD median, not the blend",
  Float.abs(d.agg.price - 3.00) < 0.001);
truth("depeg/robust USD: source count is the USD group's (3 ≥ floor)", d.agg.sourceCount == 3 and d.agg.sourceCount >= FLOOR);
truth("depeg/robust USD: full reading fleet kept for observability", d.agg.readings.size() == 6);
// dispersion is WITHIN the quote group: the USD trio is 33bps apart, while a
// pooled aggregate over the split groups would show the depeg as dispersion.
let pooled = PriceFeed.aggregate("ICP", depeg3, 42);
truth("depeg/robust USD: dispersion within the USD group is tight", d.agg.stddevBps < 100.0);
truth("depeg/robust USD: (contrast) pooled dispersion would have carried the depeg", pooled.stddevBps > d.agg.stddevBps);

// ── the same split with only TWO USD venues: below the floor, the pool keeps the mark ──
// The pre-#55 behaviour handed the mark to the USD pair (sourceCount 2), which
// the caller's floor (3) then refused — a frozen mark on every divergence.
let depeg2 = [rd("usd-a", 3.00), rd("usd-b", 3.01), rd("t-a", 3.31), rd("t-b", 3.30), rd("t-c", 3.32)];
let d2 = PriceFeed.aggregateByQuote("ICP", depeg2, SOURCES, 42, THRESHOLD, FLOOR);
truth("depeg/2 USD: still DIVERGED (the signal is not suppressed)", d2.diverged);
truth("depeg/2 USD: magnitude ≈ 1000bps", d2.depegBps > 900 and d2.depegBps < 1100);
truth("depeg/2 USD: mark basis is the pool", d2.mark == #pooled);
truth("depeg/2 USD: the primary passes the floor", d2.agg.sourceCount >= FLOOR);
truth("depeg/2 USD: group counts still reported (2 USD, 3 USDT)", d2.usdCount == 2 and d2.usdtCount == 3);
// ...and a floor of 2 (hypothetical — the module takes the caller's floor)
// would let the pair override: the decision is the floor composed with the
// group count, not a fixed constant.
let d2lo = PriceFeed.aggregateByQuote("ICP", depeg2, SOURCES, 42, THRESHOLD, 2);
truth("depeg/2 USD, floor 2: the USD pair may override the pool", d2lo.mark == #usdGroup and d2lo.agg.sourceCount == 2);

// ── (a) the reporter's eight-reading fixture (issue #55 "oracle split") ──
// coinbase 100, coingecko 97.5 (a lagging USD venue), six USDT at 100±0.1.
// The USD pair medians to 98.75 → 126bps from the USDT group → "diverged" —
// and pre-fix the mark went to the pair, which the floor refused: frozen.
let lagging = [rd("usd-a", 100.0), rd("usd-b", 97.5),
               rd("t-a", 99.9), rd("t-b", 100.0), rd("t-c", 100.1),
               rd("t-d", 99.9), rd("t-e", 100.0), rd("t-f", 100.1)];
let l = PriceFeed.aggregateByQuote("ICP", lagging, SOURCES, 42, THRESHOLD, FLOOR);
truth("lagging USD venue: reported as diverged (signal kept)", l.diverged and l.depegBps > THRESHOLD);
truth("lagging USD venue: USD group is below the floor", l.usdCount < FLOOR);
truth("lagging USD venue: mark basis is the pool", l.mark == #pooled);
truth("lagging USD venue: a USABLE aggregate — sourceCount ≥ 3", l.agg.sourceCount >= 3);
truth("lagging USD venue: the pooled trim drops the lagging venue (7 kept)", l.agg.sourceCount == 7);
truth("lagging USD venue: the mark sits on the cluster (≈100)", Float.abs(l.agg.price - 100.0) < 0.2);
truth("lagging USD venue: dispersion within the caller's 50bps gate", l.agg.stddevBps <= 50.0);

// ── (b) a REAL depeg with the shipped fleet: USD 110, USDT 100 ──
// The divergence is reported; the USD pair still cannot pass the floor, so
// the primary is the pooled trim (USDT-dominated — the USD-quoted XRC anchor's
// divergence cross-check is the backstop on that side). What matters here is
// that the primary is DEFINED and passes the floor, not frozen.
let real = [rd("usd-a", 110.0), rd("usd-b", 110.2),
            rd("t-a", 99.9), rd("t-b", 100.0), rd("t-c", 100.1),
            rd("t-d", 99.9), rd("t-e", 100.0), rd("t-f", 100.1)];
let r = PriceFeed.aggregateByQuote("ICP", real, SOURCES, 42, THRESHOLD, FLOOR);
truth("real depeg: DIVERGED", r.diverged);
truth("real depeg: magnitude ≈ 900bps (|110.1−100|/110.1)", r.depegBps > 850 and r.depegBps < 950);
truth("real depeg: mark basis is the pool (USD pair below the floor)", r.mark == #pooled);
truth("real depeg: a DEFINED primary that passes the floor", r.agg.price > 0.0 and r.agg.sourceCount >= FLOOR);
truth("real depeg: the primary is the six-venue cluster", r.agg.sourceCount == 6 and Float.abs(r.agg.price - 100.0) < 0.2);
truth("real depeg: full reading fleet kept for observability", r.agg.readings.size() == 8);

// ── (c) a ~1e-302 USD reading: no trap, reported as diverged ──
// parseLeadingFloat has no lower bound, so a hostile USD body parsing to
// 1e-302 passes `> 0.0` and makes the divergence quotient infinite (or, for a
// small mark, absurdly large but finite). Float.toInt traps on inf/NaN; the
// finiteness gate saturates instead — never zeroes — so the tick continues.
let tinyInf = [rd("usd-a", 1.0e-302),
               rd("t-a", 60_000.0), rd("t-b", 60_010.0), rd("t-c", 59_990.0),
               rd("t-d", 60_000.0), rd("t-e", 60_005.0), rd("t-f", 59_995.0)];
let ti = PriceFeed.aggregateByQuote("ICP", tinyInf, SOURCES, 42, THRESHOLD, FLOOR);
truth("1e-302 USD (infinite quotient): did not trap and is DIVERGED", ti.diverged);
truth("1e-302 USD (infinite quotient): depeg saturated, not zeroed", ti.depegBps == PriceFeed.DEPEG_BPS_SATURATED);
truth("1e-302 USD (infinite quotient): mark basis is the pool", ti.mark == #pooled);
truth("1e-302 USD (infinite quotient): the pooled trim drops the rogue reading", ti.agg.sourceCount == 6 and ti.agg.price > 59_000.0);
let tinyBig = [rd("usd-a", 1.0e-302),
               rd("t-a", 3.00), rd("t-b", 3.01), rd("t-c", 2.99),
               rd("t-d", 3.00), rd("t-e", 3.01), rd("t-f", 2.99)];
let tb = PriceFeed.aggregateByQuote("ICP", tinyBig, SOURCES, 42, THRESHOLD, FLOOR);
truth("1e-302 USD (huge finite quotient): did not trap and is DIVERGED", tb.diverged);
truth("1e-302 USD (huge finite quotient): depeg saturated past the 1e15 gate", tb.depegBps == PriceFeed.DEPEG_BPS_SATURATED);
truth("1e-302 USD (huge finite quotient): the pooled trim still prices", tb.agg.sourceCount == 6 and Float.abs(tb.agg.price - 3.0) < 0.05);

// ── one group empty: the other prices alone, no false signal ──
let usdtOnly = [rd("t-a", 3.00), rd("t-b", 3.02)];
let o = PriceFeed.aggregateByQuote("ICP", usdtOnly, SOURCES, 42, THRESHOLD, FLOOR);
truth("usdt-only: not flagged as depeg", not o.diverged);
truth("usdt-only: prices from the available group", o.agg.sourceCount == 2);
let usdOnly = [rd("usd-a", 3.00)];
let u = PriceFeed.aggregateByQuote("ICP", usdOnly, SOURCES, 42, THRESHOLD, FLOOR);
truth("usd-only: single source still prices", u.agg.sourceCount == 1 and not u.diverged);

// ── an unknown source id defaults to the mark's denomination ──
let unk = [rd("mystery", 3.00), rd("t-a", 3.35)];
let m = PriceFeed.aggregateByQuote("ICP", unk, SOURCES, 42, THRESHOLD, FLOOR);
truth("unknown source treated as USD (diverges against USDT)", m.diverged);

Debug.print("PriceFeedQuotes.test: all green");
