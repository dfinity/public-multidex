// Unit tests for PriceFeed.aggregateByQuote (W3-05) — the USD/USDT split.
//
// Pooling USD- and USDT-quoted venues into one median averaged a USDT depeg
// away: the blend moved, the (then USDT-quoted) anchor moved with it, and
// the dispersion gate saw agreement. Per-quote grouping makes the group
// divergence THE depeg signal, and the mark follows the USD group.
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
let SOURCES : [PriceFeed.Source] = [
  src("usd-a", #usd), src("usd-b", #usd),
  src("t-a", #usdt), src("t-b", #usdt), src("t-c", #usdt),
];
func rd(id : Text, price : Float) : PriceFeed.Reading {
  { sourceId = id; asset = "ICP"; price; fetchedAtNs = 1_000; ok = true; errMessage = null };
};

Debug.print("── PriceFeedQuotes.test ──");

// ── agreement: pooled, maximal sources, no signal ──
let agree = [rd("usd-a", 3.00), rd("usd-b", 3.01), rd("t-a", 3.00), rd("t-b", 3.01), rd("t-c", 2.99)];
let a = PriceFeed.aggregateByQuote("ICP", agree, SOURCES, 42, 100);
truth("agreement: not diverged", not a.diverged);
truth("agreement: pooled source count (5)", a.agg.sourceCount == 5);
truth("agreement: both groups counted", a.usdCount == 2 and a.usdtCount == 3);
truth("agreement: depeg ≈ 0", a.depegBps < 20);

// ── USDT depeg: groups split, the mark follows USD, signal reported ──
let depeg = [rd("usd-a", 3.00), rd("usd-b", 3.01), rd("t-a", 3.31), rd("t-b", 3.30), rd("t-c", 3.32)];
let d = PriceFeed.aggregateByQuote("ICP", depeg, SOURCES, 42, 100);
truth("depeg: DIVERGED", d.diverged);
truth("depeg: magnitude ≈ 1000bps", d.depegBps > 900 and d.depegBps < 1100);
truth("depeg: the mark is the USD median, not the blend",
  Float.abs(d.agg.price - 3.005) < 0.001);
truth("depeg: source count is the USD group's", d.agg.sourceCount == 2);
truth("depeg: full reading fleet kept for observability", d.agg.readings.size() == 5);
// dispersion is WITHIN the quote group: the USD pair is 33bps apart, while a
// pooled aggregate over the split groups would show the depeg as dispersion.
let pooled = PriceFeed.aggregate("ICP", depeg, 42);
truth("depeg: dispersion within the USD group is tight", d.agg.stddevBps < 100.0);
truth("depeg: (contrast) pooled dispersion would have carried the depeg", pooled.stddevBps > d.agg.stddevBps);

// ── one group empty: the other prices alone, no false signal ──
let usdtOnly = [rd("t-a", 3.00), rd("t-b", 3.02)];
let o = PriceFeed.aggregateByQuote("ICP", usdtOnly, SOURCES, 42, 100);
truth("usdt-only: not flagged as depeg", not o.diverged);
truth("usdt-only: prices from the available group", o.agg.sourceCount == 2);
let usdOnly = [rd("usd-a", 3.00)];
let u = PriceFeed.aggregateByQuote("ICP", usdOnly, SOURCES, 42, 100);
truth("usd-only: single source still prices", u.agg.sourceCount == 1 and not u.diverged);

// ── an unknown source id defaults to the mark's denomination ──
let unk = [rd("mystery", 3.00), rd("t-a", 3.35)];
let m = PriceFeed.aggregateByQuote("ICP", unk, SOURCES, 42, 100);
truth("unknown source treated as USD (diverges against USDT)", m.diverged);

Debug.print("PriceFeedQuotes.test: all green");
