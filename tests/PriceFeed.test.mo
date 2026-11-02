// Pure-function tests for PriceFeed. Exercises the body parsers
// (the bit that's fragile to upstream JSON changes) and the
// statistical aggregation (median, robustMedian) that drives oracle
// pricing decisions.

import PriceFeed "../src/backend/lib/PriceFeed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Float "mo:core/Float";
import Text "mo:core/Text";

func close(name : Text, actual : Float, expected : Float, tol : Float) {
  if (Float.abs(actual - expected) > tol) {
    Runtime.trap("FAIL: " # name # " — expected " # debug_show expected # " got " # debug_show actual);
  };
  Debug.print("  ✓ " # name);
};

func optClose(name : Text, actual : ?Float, expected : Float, tol : Float) {
  switch (actual) {
    case null { Runtime.trap("FAIL: " # name # " — got null") };
    case (?v) { close(name, v, expected, tol) };
  };
};

func optNull(name : Text, actual : ?Float) {
  switch (actual) {
    case null { Debug.print("  ✓ " # name) };
    case (?v) { Runtime.trap("FAIL: " # name # " — expected null, got " # debug_show v) };
  };
};

func eqBool(name : Text, actual : Bool, expected : Bool) {
  if (actual != expected) {
    Runtime.trap("FAIL: " # name # " — expected " # debug_show expected # " got " # debug_show actual);
  };
  Debug.print("  ✓ " # name);
};

Debug.print("── PriceFeed.test ──");

// ── parseLeadingFloat ────────────────────────────────────────────
// Takes a Text and parses the first decimal number. Skips leading
// whitespace, accepts optional `-`, integer + fractional parts.

optClose("parses simple int",       PriceFeed.parseLeadingFloat("75000"),       75000.0, 0.0001);
optClose("parses with decimal",     PriceFeed.parseLeadingFloat("75000.5"),     75000.5, 0.0001);
optClose("parses negative",         PriceFeed.parseLeadingFloat("-3.14"),       -3.14,   0.0001);
optClose("parses with leading WS",  PriceFeed.parseLeadingFloat("   75000"),    75000.0, 0.0001);
optClose("stops at non-digit",      PriceFeed.parseLeadingFloat("75000.5xyz"),  75000.5, 0.0001);
optClose("stops at comma",          PriceFeed.parseLeadingFloat("123,456"),     123.0,   0.0001);
optClose("zero",                    PriceFeed.parseLeadingFloat("0.0"),         0.0,     0.0001);

// Failure modes
optNull("rejects empty",            PriceFeed.parseLeadingFloat(""));
optNull("rejects all whitespace",   PriceFeed.parseLeadingFloat("    "));
optNull("rejects letters only",     PriceFeed.parseLeadingFloat("abc"));

// ── Scientific notation must be REFUSED, never truncated ─────────
// A "stop at the first non-numeric character" loop treats `e` as a terminator
// and returns the MANTISSA: "1.5e3" → 1.5 for a true 1500 (1000× low),
// "1.2e-8" → 1.2 (10^8 high). That value is the oracle mark behind
// liquidations and collateral valuation, and nothing downstream can tell a
// plausible wrong price from a right one — whereas a MISSING reading is
// something the aggregator already handles (the source drops out of the
// sample). So these must be null, not a mantissa.
optNull("refuses 1.5e3 (must not truncate to 1.5)",   PriceFeed.parseLeadingFloat("1.5e3"));
optNull("refuses 1.2e-8 (must not truncate to 1.2)",  PriceFeed.parseLeadingFloat("1.2e-8"));
optNull("refuses 6.4E4 (must not truncate to 6.4)",   PriceFeed.parseLeadingFloat("6.4E4"));
optNull("refuses bare-int exponent 2e5",              PriceFeed.parseLeadingFloat("2e5"));
optNull("refuses exponent inside a quoted value",     PriceFeed.parseLeadingFloat("1.5e3\",\"v\":1"));
// Controls: the plain-decimal forms every wired source actually emits are
// untouched, and a trailing letter that ISN'T an exponent still terminates.
optClose("control: plain decimal still parses", PriceFeed.parseLeadingFloat("64046.03"), 64046.03, 0.0001);
optClose("control: 1.5 with no exponent",       PriceFeed.parseLeadingFloat("1.5"),      1.5,      0.0001);
optClose("control: still stops at a letter",    PriceFeed.parseLeadingFloat("75000.5xyz"), 75000.5, 0.0001);
// Leading 'e' was never a number to begin with.
optNull("refuses a bare exponent with no mantissa", PriceFeed.parseLeadingFloat("e5"));

// ── findAfter ────────────────────────────────────────────────────
// Returns the substring after the first occurrence of `needle`.
// Used by extractors to locate JSON-field-value boundaries.

func optEq(name : Text, actual : ?Text, expected : Text) {
  switch (actual) {
    case null { Runtime.trap("FAIL: " # name # " — got null") };
    case (?v) {
      if (v != expected) {
        Runtime.trap("FAIL: " # name # " — expected '" # expected # "' got '" # v # "'");
      };
      Debug.print("  ✓ " # name);
    };
  };
};

optEq("findAfter basic",
      PriceFeed.findAfter("{\"price\":75000}", "\"price\":"),
      "75000}");

optEq("findAfter at start",
      PriceFeed.findAfter("hello world", "hello "),
      "world");

switch (PriceFeed.findAfter("no match here", "needle")) {
  case null { Debug.print("  ✓ findAfter returns null when needle absent") };
  case (?_) { Runtime.trap("FAIL: should not have matched") };
};

// ── median / mean / stddev ───────────────────────────────────────

optClose("median of odd-length sorted",   PriceFeed.median([1.0, 2.0, 3.0]),         2.0, 0.0001);
optClose("median of even-length sorted",  PriceFeed.median([1.0, 2.0, 3.0, 4.0]),    2.5, 0.0001);
optClose("median of unsorted",            PriceFeed.median([5.0, 1.0, 3.0]),         3.0, 0.0001);
optClose("median single value",           PriceFeed.median([42.0]),                  42.0, 0.0001);
optNull("median of empty array",          PriceFeed.median([]));

optClose("mean basic",                    PriceFeed.mean([1.0, 2.0, 3.0]),           2.0, 0.0001);
optNull("mean of empty array",            PriceFeed.mean([]));

// stddev: sample stddev (Bessel-corrected). For [2,4,4,4,5,5,7,9],
// expected sample stddev ≈ 2.138 (compared to population 2.000).
optClose("stddev basic",
         PriceFeed.stddev([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]),
         2.13809, 0.001);
optNull("stddev of single value",         PriceFeed.stddev([42.0]));
optNull("stddev of empty",                PriceFeed.stddev([]));

// ── robustMedian ─────────────────────────────────────────────────
// Drops samples outside ±sigmaTrim*stddev from initial median, then
// re-medians. Used for oracle aggregation to reject outlier feeds.

// 5 values clustered around 100 with one outlier at 200 — outlier
// should be removed before computing the final median.
optClose("robustMedian rejects outlier",
         PriceFeed.robustMedian([99.0, 100.0, 101.0, 100.5, 200.0], 2.0),
         100.0, 0.5);

// Falls back to plain median for short series (<3 samples).
optClose("robustMedian small sample falls through",
         PriceFeed.robustMedian([100.0, 102.0], 2.0),
         101.0, 0.0001);

optNull("robustMedian of empty",          PriceFeed.robustMedian([], 2.0));

// ── extractFromBody ──────────────────────────────────────────────
// Format-specific extraction. These bodies are real shapes the
// providers return; if a provider changes their JSON shape, these
// tests fail and we know to update the parser.

let coinbaseBody = Text.encodeUtf8("{\"data\":{\"amount\":\"75517.39\",\"base\":\"BTC\",\"currency\":\"USD\"}}");
optClose("coinbase body extract",
         PriceFeed.extractFromBody(#coinbase, coinbaseBody, "BTC"),
         75517.39, 0.001);

let coingeckoBody = Text.encodeUtf8("{\"bitcoin\":{\"usd\":75490}}");
optClose("coingecko body extract",
         PriceFeed.extractFromBody(#coingecko, coingeckoBody, "BTC"),
         75490.0, 0.001);

let coinpaprikaBody = Text.encodeUtf8(
  "{\"id\":\"btc-bitcoin\",\"quotes\":{\"USD\":{\"price\":75501.123,\"volume_24h\":1.0}}}"
);
optClose("coinpaprika body extract",
         PriceFeed.extractFromBody(#coinpaprika, coinpaprikaBody, "BTC"),
         75501.123, 0.001);

// Kraken (#krakenLike): last trade is c[0]. The result key carries legacy
// X/Z prefixes for BTC/ETH, but the extractor scans for the "c" array so the
// key name is irrelevant — verify both a plain and a prefixed key.
let krakenIcp = Text.encodeUtf8(
  "{\"error\":[],\"result\":{\"ICPUSD\":{\"a\":[\"2.77600\",\"1\",\"1.0\"],\"b\":[\"2.77400\",\"2\",\"2.0\"],\"c\":[\"2.77500\",\"0.5\"],\"v\":[\"1\",\"2\"]}}}"
);
optClose("kraken ICP body extract",
         PriceFeed.extractFromBody(#krakenLike, krakenIcp, "ICP"),
         2.775, 0.0001);
let krakenBtc = Text.encodeUtf8(
  "{\"error\":[],\"result\":{\"XXBTZUSD\":{\"a\":[\"63100.0\",\"1\"],\"c\":[\"63108.62\",\"0.1\"]}}}"
);
optClose("kraken BTC body extract (legacy XXBTZUSD key)",
         PriceFeed.extractFromBody(#krakenLike, krakenBtc, "BTC"),
         63108.62, 0.001);

// OKX: data[0].last
let okxBody = Text.encodeUtf8(
  "{\"code\":\"0\",\"msg\":\"\",\"data\":[{\"instType\":\"SPOT\",\"instId\":\"ICP-USDT\",\"last\":\"2.779\",\"lastSz\":\"0.15\",\"askPx\":\"2.779\"}]}"
);
optClose("okx body extract", PriceFeed.extractFromBody(#okx, okxBody, "ICP"), 2.779, 0.0001);

// KuCoin: data.price (the first "price" field, ahead of bestBid/bestAsk)
let kucoinBody = Text.encodeUtf8(
  "{\"code\":\"200000\",\"data\":{\"time\":1780597674154,\"sequence\":\"33734\",\"price\":\"2.777\",\"size\":\"0.35\",\"bestBid\":\"2.777\",\"bestAsk\":\"2.779\"}}"
);
optClose("kucoin body extract", PriceFeed.extractFromBody(#kucoin, kucoinBody, "ICP"), 2.777, 0.0001);

// CryptoCompare: {"USD":x} — bare number
let ccBody = Text.encodeUtf8("{\"USD\":2.774}");
optClose("cryptocompare body extract", PriceFeed.extractFromBody(#cryptocompare, ccBody, "ICP"), 2.774, 0.0001);

// HTX (Huobi): tick.close is the last trade, a bare number. Body shape
// captured live 2026-07-11 from /market/detail/merged?symbol=icpusdt.
let htxBody = Text.encodeUtf8(
  "{\"ch\":\"market.icpusdt.detail.merged\",\"status\":\"ok\",\"ts\":1783725182735,\"tick\":{\"id\":8185240693,\"version\":8185240693,\"open\":2.33,\"close\":2.29,\"low\":2.27,\"high\":2.38,\"amount\":154427.70414743637,\"vol\":359209.31292931,\"count\":4114}}"
);
optClose("htx body extract", PriceFeed.extractFromBody(#htx, htxBody, "ICP"), 2.29, 0.0001);
// HTX error body has no "close" → parse must fail, not return garbage.
let htxErr = Text.encodeUtf8("{\"status\":\"error\",\"err-code\":\"invalid-parameter\",\"err-msg\":\"invalid symbol\"}");
optNull("htx error body → null", PriceFeed.extractFromBody(#htx, htxErr, "ICP"));

// Crypto.com: result.data[0].a is the latest trade. Their gateway
// PRETTY-PRINTS (`"a" : "2.2965"`) — captured live 2026-07-11 — and the
// extractor must also survive a compact rendering if they change it.
let cryptocomPretty = Text.encodeUtf8(
  "{\n  \"id\" : -1,\n  \"method\" : \"public/get-tickers\",\n  \"code\" : 0,\n  \"result\" : {\n    \"data\" : [ {\n      \"i\" : \"ICP_USDT\",\n      \"h\" : \"2.3780\",\n      \"l\" : \"2.2782\",\n      \"a\" : \"2.2965\",\n      \"v\" : \"4821.00\",\n      \"vv\" : \"11151.16\",\n      \"c\" : \"-0.0211\"\n    } ]\n  }\n}"
);
optClose("crypto.com pretty-printed body extract",
         PriceFeed.extractFromBody(#cryptocom, cryptocomPretty, "ICP"),
         2.2965, 0.0001);
let cryptocomCompact = Text.encodeUtf8(
  "{\"id\":-1,\"method\":\"public/get-tickers\",\"code\":0,\"result\":{\"data\":[{\"i\":\"BTC_USDT\",\"h\":\"64697.99\",\"l\":\"62918.51\",\"a\":\"64084.20\",\"v\":\"1788.9712\"}]}}"
);
optClose("crypto.com compact body extract",
         PriceFeed.extractFromBody(#cryptocom, cryptocomCompact, "BTC"),
         64084.20, 0.0001);

// Binance: flat {"symbol","price"} pair — captured live 2026-07-11.
let binanceBody = Text.encodeUtf8("{\"symbol\":\"BTCUSDT\",\"price\":\"64158.01000000\"}");
optClose("binance body extract",
         PriceFeed.extractFromBody(#binance, binanceBody, "BTC"),
         64158.01, 0.0001);

// numberAfterKey: the punctuation-tolerant extractor behind the two above.
optClose("numberAfterKey compact bare",   PriceFeed.numberAfterKey("{\"close\":64046.03}", "\"close\""), 64046.03, 0.0001);
optClose("numberAfterKey pretty quoted",  PriceFeed.numberAfterKey("{\"a\" : \"2.29\"}", "\"a\""),        2.29,     0.0001);
optNull("numberAfterKey missing key", PriceFeed.numberAfterKey("{\"b\":1}", "\"a\""));
optNull("numberAfterKey non-numeric value", PriceFeed.numberAfterKey("{\"a\":\"ok\"}", "\"a\""));

// ── First-match fragility, and the anchored form that fixes it ────
// findAfter is first-occurrence BY CONSTRUCTION, so a short key matches any
// earlier field that shares its name — and the wrong value parses perfectly.
// This is the exact reported case: `"a"` occurs once as a top-level field and
// again as the ticker's price.
let ambiguous = "{\"a\":\"99.90\",\"ticker\":{\"a\":\"2.29\"}}";
// Pinning the documented (fragile) behaviour of the bare-key form, so nobody
// "fixes" it into something surprising: it reads the FIRST "a".
optClose("numberAfterKey is first-occurrence (reads the earlier 99.90)",
         PriceFeed.numberAfterKey(ambiguous, "\"a\""), 99.90, 0.0001);
// The anchored form names the containing object and reaches the INTENDED one.
optClose("numberAfterPath reaches the INTENDED ticker \"a\" (2.29, not 99.90)",
         PriceFeed.numberAfterPath(ambiguous, ["\"ticker\"", "\"a\""]), 2.29, 0.0001);
// A path whose container is absent is a miss, not a fallback to a loose match:
// the whole point is that drift yields NO reading rather than a wrong one.
optNull("numberAfterPath: absent container → null (never falls back)",
        PriceFeed.numberAfterPath(ambiguous, ["\"quotes\"", "\"a\""]));
optNull("numberAfterPath: absent leaf key → null",
        PriceFeed.numberAfterPath(ambiguous, ["\"ticker\"", "\"zzz\""]));
optNull("numberAfterPath: empty path → null", PriceFeed.numberAfterPath(ambiguous, []));
optClose("numberAfterPath: a single segment is exactly numberAfterKey",
         PriceFeed.numberAfterPath(ambiguous, ["\"a\""]), 99.90, 0.0001);

// findAfter must return the WHOLE remainder, not the text up to the needle's
// NEXT occurrence — numberAfterPath chains it, and a truncating intermediate
// segment would cut the target key out before the next segment looked for it.
optEq("findAfter returns the full remainder past a repeated needle",
      PriceFeed.findAfter("a1b1c", "1"), "b1c");
// The multi-key path that depends on it (Crypto.com's shape).
optClose("numberAfterPath survives a repeated intermediate key",
         PriceFeed.numberAfterPath(
           "{\"data\":0,\"result\":{\"data\":[{\"i\":\"BTC_USDT\",\"a\":\"64084.20\"}]}}",
           ["\"result\"", "\"data\"", "\"a\""]),
         64084.20, 0.0001);

// ── Extractor anchoring: the 8 WIRED sources ─────────────────────
// PRICE_SOURCES in main.mo wires coinbase, okx, kucoin, coingecko, htx,
// cryptocom, binance and kraken. Each extractor now names the CONTAINING
// object of the field it reads, so a same-named field appearing EARLIER in the
// body — an envelope field an upstream adds above the container, a second coin
// in the response, provider text inside an error array — can no longer be the
// match. The realistic-body tests above pin that the anchors still parse the
// live shapes; these pin that the anchor is load-bearing. Every one of these
// bodies would have yielded the DECOY price under the old first-match form.

// Coinbase: v2 responses can carry a `warnings` array ahead of `data`.
let coinbaseDecoy = Text.encodeUtf8(
  "{\"warnings\":[{\"id\":\"missing_version\",\"amount\":\"0.01\"}],\"data\":{\"amount\":\"75517.39\",\"base\":\"BTC\",\"currency\":\"USD\"}}"
);
optClose("coinbase: reads data.amount, not an earlier warnings amount",
         PriceFeed.extractFromBody(#coinbase, coinbaseDecoy, "BTC"), 75517.39, 0.001);

// Coingecko: `ids=` takes a LIST, so a body carrying more than one coin is the
// provider's own documented shape — the extractor must read the coin it asked
// for. Anchoring on the mapped id ("bitcoin" for BTC) does that.
let geckoTwoCoins = Text.encodeUtf8(
  "{\"internet-computer\":{\"usd\":2.29},\"bitcoin\":{\"usd\":64046.03}}"
);
optClose("coingecko: picks the REQUESTED coin's usd (BTC → 64046.03)",
         PriceFeed.extractFromBody(#coingecko, geckoTwoCoins, "BTC"), 64046.03, 0.001);
optClose("coingecko: same body, ICP → 2.29",
         PriceFeed.extractFromBody(#coingecko, geckoTwoCoins, "ICP"), 2.29, 0.0001);
optNull("coingecko: body that answers a DIFFERENT coin → null",
        PriceFeed.extractFromBody(#coingecko, Text.encodeUtf8("{\"solana\":{\"usd\":142.5}}"), "BTC"));

// OKX / KuCoin / HTX / Crypto.com: an envelope field added above the container.
let okxDecoy = Text.encodeUtf8(
  "{\"code\":\"0\",\"msg\":\"\",\"last\":\"0.01\",\"data\":[{\"instId\":\"ICP-USDT\",\"last\":\"2.779\",\"lastSz\":\"0.15\"}]}"
);
optClose("okx: reads data[].last, not an envelope \"last\"",
         PriceFeed.extractFromBody(#okx, okxDecoy, "ICP"), 2.779, 0.0001);
let kucoinDecoy = Text.encodeUtf8(
  "{\"code\":\"200000\",\"price\":\"0.01\",\"data\":{\"time\":1780597674154,\"price\":\"2.777\",\"bestBid\":\"2.777\",\"bestAsk\":\"2.779\"}}"
);
optClose("kucoin: reads data.price, not an envelope \"price\"",
         PriceFeed.extractFromBody(#kucoin, kucoinDecoy, "ICP"), 2.777, 0.0001);
let htxDecoy = Text.encodeUtf8(
  "{\"ch\":\"market.icpusdt.detail.merged\",\"status\":\"ok\",\"close\":0.0,\"tick\":{\"open\":2.33,\"close\":2.29,\"low\":2.27}}"
);
optClose("htx: reads tick.close, not an envelope \"close\"",
         PriceFeed.extractFromBody(#htx, htxDecoy, "ICP"), 2.29, 0.0001);
let cryptocomDecoy = Text.encodeUtf8(
  "{\"id\":-1,\"method\":\"public/get-tickers\",\"a\":\"0.01\",\"code\":0,\"result\":{\"data\":[{\"i\":\"ICP_USDT\",\"h\":\"2.3780\",\"a\":\"2.2965\"}]}}"
);
optClose("crypto.com: reads result.data[].a — the 3-char key that made this urgent",
         PriceFeed.extractFromBody(#cryptocom, cryptocomDecoy, "ICP"), 2.2965, 0.0001);

// Kraken: `"c"` is a ONE-character key, so anything named "c" added above the
// result container captures it. (Quotes inside the leading "error" array's
// strings are JSON-escaped, so provider text there cannot collide — the real
// exposure is an envelope key, which is what this pins.)
let krakenDecoy = Text.encodeUtf8(
  "{\"error\":[],\"c\":[\"0.01\"],\"result\":{\"ICPUSD\":{\"a\":[\"2.77600\",\"1\"],\"c\":[\"2.77500\",\"0.5\"]}}}"
);
optClose("kraken: reads result…c[0], not an envelope \"c\"",
         PriceFeed.extractFromBody(#krakenLike, krakenDecoy, "ICP"), 2.775, 0.0001);

// Binance's body is flat with no container, so it anchors on the sibling key
// that always precedes the price. A document carrying a "price" but no
// "symbol" is not the ticker response and must not be read as one.
optNull("binance: a non-ticker document with a \"price\" → null",
        PriceFeed.extractFromBody(#binance, Text.encodeUtf8("{\"price\":\"0.01\",\"code\":-1121}"), "BTC"));

// End to end: a source that starts emitting scientific notation yields NO
// reading (the source drops out and the aggregate carries on), never a
// mantissa 1000× low that would silently become the mark.
optNull("binance body in scientific notation → no reading, not 1.5",
        PriceFeed.extractFromBody(#binance, Text.encodeUtf8("{\"symbol\":\"BTCUSDT\",\"price\":\"1.5e3\"}"), "BTC"));
optNull("htx body in scientific notation → no reading",
        PriceFeed.extractFromBody(#htx, Text.encodeUtf8("{\"status\":\"ok\",\"tick\":{\"close\":6.4E4}}"), "BTC"));

// The two UNWIRED extractors (coinpaprika, cryptocompare) are deliberately
// untouched; their realistic-body tests above are the no-regression check.

// kindText: the candid-stable tag the public API exposes instead of the
// SourceKind variant. Spot-check the mapping, including the one rename
// (#krakenLike → "kraken").
func eqText(name : Text, actual : Text, expected : Text) {
  if (actual != expected) {
    Runtime.trap("FAIL: " # name # " — expected '" # expected # "' got '" # actual # "'");
  };
  Debug.print("  ✓ " # name);
};
eqText("kindText binance",    PriceFeed.kindText(#binance),    "binance");
eqText("kindText krakenLike", PriceFeed.kindText(#krakenLike), "kraken");
eqText("kindText htx",        PriceFeed.kindText(#htx),        "htx");
eqText("kindText cryptocom",  PriceFeed.kindText(#cryptocom),  "cryptocom");

// Garbage body returns null cleanly.
let garbage = Text.encodeUtf8("not json at all");
switch (PriceFeed.extractFromBody(#coinbase, garbage, "BTC")) {
  case null { Debug.print("  ✓ extractFromBody handles garbage gracefully") };
  case (?v) { Runtime.trap("FAIL: garbage body returned " # debug_show v) };
};

// ── aggregate ────────────────────────────────────────────────────
// Builds an Aggregate from a vec of Reading. Mixes ok/!ok readings.

let readings : [PriceFeed.Reading] = [
  { sourceId = "a"; asset = "BTC"; price = 75000.0; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "b"; asset = "BTC"; price = 75100.0; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "c"; asset = "BTC"; price = 0.0;     fetchedAtNs = 0; ok = false; errMessage = ?"timeout" },
  { sourceId = "d"; asset = "BTC"; price = 75050.0; fetchedAtNs = 0; ok = true;  errMessage = null },
];
let agg = PriceFeed.aggregate("BTC", readings, 1_000_000_000_000);
close("aggregate price ≈ median of OK readings", agg.price, 75050.0, 1.0);

if (agg.sourceCount != 3) {
  Runtime.trap("FAIL: agg.sourceCount expected 3, got " # debug_show agg.sourceCount);
};
Debug.print("  ✓ aggregate.sourceCount = 3 (the !ok one excluded)");

if (agg.stddevBps <= 0.0) {
  Runtime.trap("FAIL: expected non-zero stddevBps for varied readings");
};
Debug.print("  ✓ aggregate.stddevBps > 0 with varied readings");

// ── One-outlier veto regression (live incident, 2026-07-12) ───────
// Seven ICP sources: six clustered $2.27–2.279 and crypto.com printing
// $2.3104 (~1.5% high on a thin market). The UNTRIMMED stddev was
// 58bps — over main.mo's 50bps quality gate — so the aggregate was
// vetoed wholesale every tick and the refPrice froze for hours, even
// though the robust median being vetoed had already excluded the
// outlier. Price AND dispersion must be judged on the SAME trimmed set:
// one bad venue must cost a source, never the whole aggregate.
let icpIncident : [PriceFeed.Reading] = [
  { sourceId = "coinbase";  asset = "ICP"; price = 2.2765; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "okx";       asset = "ICP"; price = 2.277;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "kucoin";    asset = "ICP"; price = 2.278;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "coingecko"; asset = "ICP"; price = 0.0;    fetchedAtNs = 0; ok = false; errMessage = ?"http 429" },
  { sourceId = "htx";       asset = "ICP"; price = 2.27;   fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "cryptocom"; asset = "ICP"; price = 2.3104; fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "binance";   asset = "ICP"; price = 2.279;  fetchedAtNs = 0; ok = true;  errMessage = null },
  { sourceId = "kraken";    asset = "ICP"; price = 2.277;  fetchedAtNs = 0; ok = true;  errMessage = null },
];
let icpAgg = PriceFeed.aggregate("ICP", icpIncident, 1_000_000_000_000);
close("incident: price is the robust median", icpAgg.price, 2.277, 0.001);
if (icpAgg.sourceCount != 6) {
  Runtime.trap("FAIL: incident sourceCount expected 6 (7 ok − 1 trimmed outlier), got " # debug_show icpAgg.sourceCount);
};
Debug.print("  ✓ incident: sourceCount counts SURVIVORS (6 — outlier trimmed, 429 excluded)");
if (icpAgg.stddevBps > 50.0) {
  Runtime.trap("FAIL: incident stddevBps must clear the 50bps gate after trimming, got " # debug_show icpAgg.stddevBps);
};
Debug.print("  ✓ incident: trimmed stddevBps clears the 50bps quality gate (≈14bps)");

// trimOutliers edge cases: short sets and all-agreeing sets pass through;
// a trim that would discard everything falls back to the full set so the
// caller's floor judges honest dispersion, not an empty sample.
let trimmed = PriceFeed.trimOutliers([99.0, 100.0, 101.0, 100.5, 200.0], 2.0);
if (trimmed.size() != 4) {
  Runtime.trap("FAIL: trimOutliers expected to keep 4 of 5, got " # debug_show trimmed.size());
};
Debug.print("  ✓ trimOutliers keeps the 4-sample cluster, drops the 200.0 outlier");
if (PriceFeed.trimOutliers([100.0, 102.0], 2.0).size() != 2) {
  Runtime.trap("FAIL: trimOutliers must pass short sets through untouched");
};
Debug.print("  ✓ trimOutliers passes <3-sample sets through");
if (PriceFeed.trimOutliers([], 2.0).size() != 0) {
  Runtime.trap("FAIL: trimOutliers of empty must be empty");
};
Debug.print("  ✓ trimOutliers of empty is empty");

// ── Small-sample masking: the trim must reject at n=3 and n=4 ────
// The band used to be ±sigmaTrim·stddev of the WHOLE set, outlier included,
// which at small n is masking so total it is provable. n=3 samples (a, a, b)
// with d = |b − a| give sd = d/√3, so a 2σ band is ±1.1547·d while the outlier
// sits at exactly d — strictly inside, for ANY d, since the relation is
// homogeneous. n=4 (a, a, a, b) gives sd = d/2 and a band edge of exactly ±d,
// landing on the outlier, which the inclusive keep test then admits. So the
// trim could not reject one bad reading until n=5 — while a source
// rate-limiting in and out puts the fleet at 3-4 as a matter of routine.
//
// Banding against the MAD instead fixes this by construction: no single
// sample, at any magnitude, can move a median-of-deviations.
func trimKeeps(name : Text, xs : [Float], expected : Nat) {
  let got = PriceFeed.trimOutliers(xs, 2.0).size();
  if (got != expected) {
    Runtime.trap("FAIL: " # name # " — expected to keep " # debug_show expected # ", kept " # debug_show got);
  };
  Debug.print("  ✓ " # name);
};

// n=3, two venues agreeing exactly and one off. MAD is 0 here (more than half
// the samples share a value), so this also exercises the band floor.
trimKeeps("n=3: rejects a 1.8% outlier against an exact pair", [2.27, 2.27, 2.31], 2);
// Scale invariance was the sharpest edge of the old defect: because the
// masking relation was homogeneous in d, a 100% outlier was kept just as
// surely as a 0.1% one. Magnitude must now decide.
trimKeeps("n=3: rejects a 100% outlier", [2.27, 2.27, 4.54], 2);
trimKeeps("n=3: rejects a 10x outlier", [2.27, 2.27, 22.7], 2);
// …but a reading INSIDE the caller's own dispersion tolerance is not an
// outlier, whatever the MAD says. This is the band floor doing its job.
trimKeeps("n=3: keeps a 10bps disagreement (inside the caller's gate)", [2.27, 2.27, 2.2723], 3);

// n=4, the exact band-edge case. sd = d/2 puts the old 2σ edge precisely on
// the outlier and `x <= hi` admitted it; here d is chosen to sit exactly
// there (2.2927 − 2.27 = 0.0227 = 2·sd for this set).
trimKeeps("n=4: rejects the outlier sitting exactly on the old 2σ band edge",
          [2.27, 2.27, 2.27, 2.2927], 3);

// The consequence the defect actually produced in service: a lone venue ~1%
// off the cluster inflated the dispersion past the caller's 50bps gate and
// FROZE the mark, which is the precise failure the trim was added to prevent.
// At n=4 the trim now removes it and the surviving cluster clears the gate.
let n4Freeze = PriceFeed.aggregate("ICP", [
  { sourceId = "a"; asset = "ICP"; price = 2.270;  fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "b"; asset = "ICP"; price = 2.272;  fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "c"; asset = "ICP"; price = 2.271;  fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "d"; asset = "ICP"; price = 2.2904; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
if (n4Freeze.sourceCount != 3) {
  Runtime.trap("FAIL: n=4 one-outlier fleet expected 3 survivors, got " # debug_show n4Freeze.sourceCount);
};
Debug.print("  ✓ n=4 with one ~0.9% outlier: 3 survivors");
if (n4Freeze.stddevBps > 50.0) {
  Runtime.trap("FAIL: surviving cluster must clear the 50bps gate, got " # debug_show n4Freeze.stddevBps);
};
Debug.print("  ✓ n=4 with one ~0.9% outlier: survivors clear the 50bps gate (mark no longer freezes)");
eqBool("n=4 with one outlier: 3 survivors may still move the mark",
       PriceFeed.canMoveMark(n4Freeze), true);
close("n=4 with one outlier: mark is the honest cluster's median", n4Freeze.price, 2.271, 0.0005);

// The other direction matters just as much: a genuinely wide but SYMMETRIC
// market is real disagreement, not an outlier, and must survive intact so the
// caller's gate sees honest dispersion and refuses to price.
trimKeeps("wide symmetric market is not trimmed", [2.20, 2.24, 2.27, 2.30, 2.34], 5);
let wideAgg = PriceFeed.aggregate("X", [
  { sourceId = "a"; asset = "X"; price = 2.20; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "b"; asset = "X"; price = 2.27; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "c"; asset = "X"; price = 2.34; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
if (wideAgg.stddevBps <= 50.0) {
  Runtime.trap("FAIL: honest wide disagreement must keep dispersion above the gate, got " # debug_show wideAgg.stddevBps);
};
Debug.print("  ✓ honest wide disagreement keeps its dispersion (gate still refuses)");

// mad() itself: the property the whole fix rests on is that one sample cannot
// move it, however far out it is.
optClose("mad of a tight cluster", PriceFeed.mad([100.0, 101.0, 102.0]), 1.0, 0.0001);
optClose("mad is unmoved by an arbitrarily distant outlier",
         PriceFeed.mad([100.0, 101.0, 102.0, 1.0e9]), 1.0, 0.0001);
optClose("mad is 0 when a majority share a value", PriceFeed.mad([5.0, 5.0, 9.0]), 0.0, 0.0001);
optNull("mad of empty", PriceFeed.mad([]));

// ── Robustness floor (n < 3 cannot MOVE a mark) ──────────────────
// trimOutliers is inoperative below 3 samples — a trim can only reject a
// MINORITY, and it locates the cluster with a median and a MAD, both of which
// need the good readings to outnumber the bad. At n=2 there is no majority to
// find. The underlying protection is the MEDIAN's breakdown point, which at
// n=2 is exactly zero: the median of two is their mean, so one rogue venue
// moves the mark by half its error, unbounded and untrimmed. The predicate
// makes that floor explicit so a caller can refuse to MOVE a mark on 2 sources
// while still letting it HOLD.
eqBool("robust floor: n=0 is not robust", PriceFeed.isRobustSourceCount(0), false);
eqBool("robust floor: n=1 is not robust", PriceFeed.isRobustSourceCount(1), false);
eqBool("robust floor: n=2 is NOT robust (median breakdown point = 0)",
       PriceFeed.isRobustSourceCount(2), false);
eqBool("robust floor: n=3 IS robust (tolerates one arbitrarily-wrong source)",
       PriceFeed.isRobustSourceCount(3), true);
eqBool("robust floor: n=8 is robust", PriceFeed.isRobustSourceCount(8), true);
if (PriceFeed.MIN_ROBUST_SOURCES != 3) {
  Runtime.trap("FAIL: MIN_ROBUST_SOURCES expected 3, got " # debug_show PriceFeed.MIN_ROBUST_SOURCES);
};
Debug.print("  ✓ MIN_ROBUST_SOURCES = 3");
eqBool("robust floor over a sample set: 2 samples → false",
       PriceFeed.isRobustSample([100.0, 110.0]), false);
eqBool("robust floor over a sample set: 3 samples → true",
       PriceFeed.isRobustSample([100.0, 110.0, 105.0]), true);

// The demonstration behind the floor: at n=2 the "aggregate" is the MEAN of the
// two, so a single rogue reading drags the mark half its error — and
// trimOutliers passes the pair through untouched, so nothing catches it.
let twoWithRogue = PriceFeed.aggregate("X", [
  { sourceId = "good";  asset = "X"; price = 100.0; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "rogue"; asset = "X"; price = 200.0; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
close("n=2: one rogue source drags the mark to the midpoint", twoWithRogue.price, 150.0, 0.0001);
eqBool("n=2 aggregate must NOT be allowed to move a mark",
       PriceFeed.canMoveMark(twoWithRogue), false);
// Add one honest source and the rogue no longer reaches the mark at all: the
// trim rejects it (MAD locates the honest pair), and the median of what
// survives is an honest price. Both mechanisms point the same way here.
let threeWithRogue = PriceFeed.aggregate("X", [
  { sourceId = "good1"; asset = "X"; price = 100.0; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "good2"; asset = "X"; price = 101.0; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "rogue"; asset = "X"; price = 200.0; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
close("n=3: the rogue is trimmed, leaving the honest pair's median",
      threeWithRogue.price, 100.5, 0.0001);
if (PriceFeed.trimOutliers([100.0, 101.0, 200.0], 2.0).size() != 2) {
  Runtime.trap("FAIL: at n=3 the trim must reject the rogue, keeping 2 of 3");
};
Debug.print("  ✓ n=3: the trim rejects the rogue (MAD cannot be inflated by it)");

// And then the floor refuses to MOVE on the result — deliberately. Rejecting a
// sample COSTS a source, so a 3-source fleet with one rogue leaves 2
// survivors, which is below MIN_ROBUST_SOURCES. That is the honest reading of
// what is on hand: two corroborating readings, and by the breakdown-point
// argument above two is not enough to move a mark. The mark HOLDS rather than
// moving on a pair, which is exactly the distinction the floor exists to draw.
//
// Worth being clear that this is not a freeze the trim introduced: before the
// trim could reject anything, this same fleet was vetoed by the caller's
// dispersion gate instead (the rogue's own distance blew stddevBps far past
// 50). Same outcome, but now for a reason that names what is actually wrong.
eqBool("n=3 with one rogue: 2 survivors cannot move a mark",
       PriceFeed.canMoveMark(threeWithRogue), false);
// The count that matters is SURVIVORS, not readings received.
if (threeWithRogue.sourceCount != 2) {
  Runtime.trap("FAIL: expected 2 survivors of 3, got " # debug_show threeWithRogue.sourceCount);
};
Debug.print("  ✓ n=3 with one rogue: sourceCount = 2 (survivors, not readings)");

// Two sources far apart (untrimmable, n<3): dispersion must stay HONEST —
// big stddev survives so the quality floor correctly refuses to price.
let splitAgg = PriceFeed.aggregate("X", [
  { sourceId = "a"; asset = "X"; price = 100.0; fetchedAtNs = 0; ok = true; errMessage = null },
  { sourceId = "b"; asset = "X"; price = 110.0; fetchedAtNs = 0; ok = true; errMessage = null },
], 0);
if (splitAgg.stddevBps < 500.0) {
  Runtime.trap("FAIL: 2-way disagreement must keep its honest (large) stddev, got " # debug_show splitAgg.stddevBps);
};
Debug.print("  ✓ 2-source disagreement keeps honest dispersion (floor still refuses)");

// ── Partial-set aggregation (H-37 / F34) ─────────────────────────
// The fan-out applies the mark on a QUORUM of arrivals (or the deadline),
// so `aggregate` must price a PARTIAL fleet honestly: four of eight sources
// in cluster → four survivors (≥ the floor), the median of the four, and a
// dispersion measured on those four — nothing about the sources that have
// not answered enters the sample. The missing sources are simply absent
// from `readings` (a fan-out never fabricates a failed reading for them).
let partial = PriceFeed.aggregate("SOL", [
  { sourceId = "okx";      asset = "SOL"; price = 150.10; fetchedAtNs = 10; ok = true; errMessage = null },
  { sourceId = "kucoin";   asset = "SOL"; price = 150.00; fetchedAtNs = 11; ok = true; errMessage = null },
  { sourceId = "coinbase"; asset = "SOL"; price = 150.20; fetchedAtNs = 12; ok = true; errMessage = null },
  { sourceId = "binance";  asset = "SOL"; price = 150.05; fetchedAtNs = 13; ok = true; errMessage = null },
], 20);
if (partial.sourceCount != 4) {
  Runtime.trap("FAIL: partial set of 4 must yield 4 survivors, got " # debug_show partial.sourceCount);
};
close("partial set (4 of 8): median of the four",           partial.price, 150.075, 0.001);
eqBool("partial set (4 of 8): robust enough to move a mark", PriceFeed.canMoveMark(partial), true);
if (partial.stddevBps > 50.0) {
  Runtime.trap("FAIL: partial set dispersion must be measured on the four present, got " # debug_show partial.stddevBps);
};
Debug.print("  ✓ partial set (4 of 8): dispersion within the gate, absent sources absent (readings 4)");
if (partial.readings.size() != 4) { Runtime.trap("FAIL: readings must be the four that arrived") };

Debug.print("── PriceFeed.test PASS ──");
