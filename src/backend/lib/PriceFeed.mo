import Array "mo:core/Array";
import Text "mo:core/Text";
import Float "mo:core/Float";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Option "mo:core/Option";
import Int "mo:core/Int";

// PriceFeed.mo — multi-source external price aggregation.
//
// Architecture:
//   main.mo configures a set of `Source`s per asset (BTC, ETH, SOL, ICP),
//   issues parallel non-replicated HTTPS outcalls to each, and hands
//   the responses to `extractFromBody` here. A fleet of `Reading`s is
//   then fed through `aggregate` to produce a robust price estimate
//   (median with 2σ outlier rejection). The resulting `Aggregate` is
//   written into the AMM pool's refPrice.
//
// Why non-replicated outcalls matter for this module:
//   - Each call runs on one replica, not all 13/34, so response bodies
//     don't have to be deterministic across replicas. That lets us use
//     sources whose bodies include timestamps, nonces, or request IDs
//     (Coinpaprika, Pyth Hermes).
//   - Cost is currently the same as replicated per-call but the plan
//     of record is that non-replicated will become ~N× cheaper.
//   - Latency is currently 2-10× worse on non-replicated (a known
//     beta artifact being fixed); on par after the fix.
//
// This module is all pure functions — no outcalls, no state. main.mo
// does the I/O; we do the math.

module {

  public type Asset = Text; // "BTC", "ETH", "SOL", "ICP"

  // Per-source response shape. Keep this enum small and extend it as
  // we add providers; each variant maps to a concrete extractor below.
  public type SourceKind = {
    #coinbase;        // {"data":{"amount":"X.XX","base":"BTC","currency":"USD"}}
    #coingecko;       // {"bitcoin":{"usd":XXXXX}}
    #coinpaprika;     // {"quotes":{"USD":{"price":X.XX, ...}}}
    #krakenLike;      // Kraken — {"result":{"XBTUSDT":{"c":["X.XX", ...]}}}
    #okx;             // {"code":"0","data":[{"instId":"ICP-USDT","last":"X.XX", ...}]}
    #kucoin;          // {"code":"200000","data":{"price":"X.XX", ...}}
    #cryptocompare;   // {"USD":X.XX}
    #htx;             // HTX (Huobi) — {"status":"ok","tick":{...,"close":X.XX, ...}}
    #cryptocom;       // Crypto.com — {"result":{"data":[{"i":"BTC_USDT","a" : "X.XX", ...}]}}
    #binance;         // {"symbol":"BTCUSDT","price":"X.XX"}
  };

  // A named price-source configuration. urlTemplate has a `{asset}`
  // placeholder that `buildUrl` substitutes with the per-source symbol
  // (so we can map our internal "BTC" to Coingecko's "bitcoin", etc.).
  // W3-05: the quote asset a venue's ticker is denominated in. The venue's
  // MARK is denominated in USD; USDT-quoted venues are usable only while
  // USDT trades at par, and the difference between the two groups IS the
  // depeg signal — pooling them into one median averaged it away.
  public type QuoteAsset = { #usd; #usdt };

  public type Source = {
    id               : Text;
    urlTemplate      : Text;
    kind             : SourceKind;
    maxResponseBytes : Nat64;
    quote            : QuoteAsset;
  };

  // One fetched sample from one source. Written by main.mo after a
  // successful outcall (or a failed one with ok=false).
  public type Reading = {
    sourceId    : Text;
    asset       : Asset;
    price       : Float;
    fetchedAtNs : Int;
    ok          : Bool;
    errMessage  : ?Text;
  };

  // Result of aggregating many readings for a single asset. `stddevBps`
  // is relative to the final price and lets callers refuse to update
  // the AMM when the sources disagree wildly.
  public type Aggregate = {
    asset       : Asset;
    price       : Float;
    sourceCount : Nat;   // number of readings that survived filtering
    stddevBps   : Float;
    timestamp   : Int;
    readings    : [Reading];
  };

  // Textual tag for a SourceKind. The public API exposes THIS instead of the
  // raw variant: a variant in a public return type makes every added provider
  // a breaking interface change (the upgrade's Candid gate rejects a grown
  // variant — old clients can't decode new tags). Text grows freely.
  public func kindText(kind : SourceKind) : Text {
    switch (kind) {
      case (#coinbase)      { "coinbase" };
      case (#coingecko)     { "coingecko" };
      case (#coinpaprika)   { "coinpaprika" };
      case (#krakenLike)    { "kraken" };
      case (#okx)           { "okx" };
      case (#kucoin)        { "kucoin" };
      case (#cryptocompare) { "cryptocompare" };
      case (#htx)           { "htx" };
      case (#cryptocom)     { "cryptocom" };
      case (#binance)       { "binance" };
    };
  };

  // ── URL construction ──────────────────────────────────────────────

  public func assetSymbol(kind : SourceKind, asset : Asset) : Text {
    switch (kind) {
      case (#coingecko) {
        switch (asset) {
          case ("BTC") { "bitcoin" };
          case ("ETH") { "ethereum" };
          case ("SOL") { "solana" };
          case ("ICP") { "internet-computer" };
          case (a)     { a };
        };
      };
      case (#coinpaprika) {
        switch (asset) {
          case ("BTC") { "btc-bitcoin" };
          case ("ETH") { "eth-ethereum" };
          case ("SOL") { "sol-solana" };
          case ("ICP") { "icp-internet-computer" };
          case (a)     { a };
        };
      };
      case (#krakenLike) {
        // Kraken USD spot pairs. BTC is "XBT"; the result key may carry
        // legacy X/Z prefixes (e.g. XXBTZUSD) but the extractor scans for
        // the "c" array, so the pair param just has to be accepted.
        switch (asset) {
          case ("BTC") { "XBTUSD" };
          case (a)     { a # "USD" };  // ETHUSD, SOLUSD, ICPUSD
        };
      };
      case (#htx) {
        // HTX symbols are lowercase concatenated USDT pairs.
        switch (asset) {
          case ("BTC") { "btcusdt" };
          case ("ETH") { "ethusdt" };
          case ("SOL") { "solusdt" };
          case ("ICP") { "icpusdt" };
          case (a)     { a };
        };
      };
      case (#cryptocom) { asset # "_USDT" }; // BTC_USDT, ETH_USDT, SOL_USDT, ICP_USDT
      case (#binance)   { asset # "USDT" };  // BTCUSDT, ETHUSDT, SOLUSDT, ICPUSDT
      case (_) { asset }; // uppercase ticker works for Coinbase / OKX / KuCoin / CryptoCompare
    };
  };

  public func buildUrl(src : Source, asset : Asset) : Text {
    Text.replace(src.urlTemplate, #text "{asset}", assetSymbol(src.kind, asset));
  };

  // ── Aggregation ───────────────────────────────────────────────────

  func appendFloat(xs : [Float], x : Float) : [Float] {
    let n = xs.size();
    Array.tabulate<Float>(n + 1, func(i) { if (i < n) { xs[i] } else { x } });
  };

  public func median(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n == 0) { return null };
    let sorted = Array.sort<Float>(xs, Float.compare);
    if (n % 2 == 1) { ?sorted[n / 2] }
    else { ?((sorted[n / 2 - 1] + sorted[n / 2]) / 2.0) };
  };

  public func mean(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n == 0) { return null };
    var sum : Float = 0.0;
    for (x in xs.vals()) { sum += x };
    ?(sum / Float.fromInt(n));
  };

  // Sample stddev (Bessel-corrected). null if < 2 samples.
  public func stddev(xs : [Float]) : ?Float {
    let n = xs.size();
    if (n < 2) { return null };
    switch (mean(xs)) {
      case null { null };
      case (?m) {
        var s : Float = 0.0;
        for (x in xs.vals()) {
          let d = x - m;
          s += d * d;
        };
        ?Float.sqrt(s / Float.fromInt(n - 1));
      };
    };
  };

  // Median absolute deviation — the median of |x − median(x)|. null on an
  // empty set.
  //
  // This is the dispersion estimate the trim bands against, and the reason is
  // its BREAKDOWN POINT: half the sample can be arbitrarily corrupted before
  // MAD can be dragged anywhere, so no single rogue reading inflates it at any
  // magnitude. The sample standard deviation has a breakdown point of zero —
  // one bad sample moves it without limit — which is fatal for a detector that
  // uses its own dispersion estimate to decide what to reject.
  public func mad(xs : [Float]) : ?Float {
    let m = switch (median(xs)) { case null { return null }; case (?v) { v } };
    var devs : [Float] = [];
    for (x in xs.vals()) { devs := appendFloat(devs, Float.abs(x - m)) };
    median(devs);
  };

  // Makes MAD a consistent estimator of σ for a normal sample, so `sigmaTrim`
  // keeps its plain "how many sigmas" meaning at the call site.
  public let MAD_TO_SIGMA : Float = 1.4826;

  // MAD × 1.4826 is unbiased for σ only ASYMPTOTICALLY; at the sample sizes an
  // oracle fleet actually runs (3-8) it reads systematically LOW — around 50%
  // low at n=3. An under-estimated scale is a narrow band and an over-eager
  // trim, and over-trimming is not a harmless direction here: every rejected
  // sample costs a source against the MIN_ROBUST_SOURCES floor, so a trim that
  // is too keen freezes the mark just as effectively as one that is too blind.
  // Standard Croux-Rousseeuw finite-sample factors, with the usual n/(n−0.8)
  // asymptote past the tabulated range.
  func madFiniteSample(n : Nat) : Float {
    if (n <= 2)      { 1.196 }
    else if (n == 3) { 1.495 }
    else if (n == 4) { 1.363 }
    else if (n == 5) { 1.206 }
    else if (n == 6) { 1.200 }
    else if (n == 7) { 1.140 }
    else if (n == 8) { 1.129 }
    else if (n == 9) { 1.107 }
    else { let f = Float.fromInt(n); f / (f - 0.8) };
  };

  // Minimum trim-band half-width, in bps of the median. See trimOutliers.
  //
  // Set to the caller's own dispersion tolerance (main.mo's
  // PRICE_MAX_STDDEV_BPS, 50 bps): a reading closer to the mark than that is
  // inside the policy the caller has already declared acceptable, so rejecting
  // it would be this module substituting a stricter opinion for the caller's.
  // If that gate is ever retuned, retune this with it.
  public let TRIM_BAND_FLOOR_BPS : Float = 50.0;

  // The samples robustMedian keeps: everything within ±sigmaTrim·σ̂ of the
  // initial median, where σ̂ is estimated from the MAD. Under 3 samples there
  // is nothing to trim against — the full set comes back; a trim that would
  // discard EVERYTHING also returns the full set (all-outliers means "no
  // agreement", and the caller's quality floor should judge that on the
  // honest, untrimmed dispersion rather than an empty set).
  //
  // WHY NOT THE STANDARD DEVIATION. This banded against ±sigmaTrim·stddev of
  // the whole set, outlier included, and that is textbook masking: at small n
  // the outlier inflates the very band meant to exclude it, by more than its
  // own distance from the median. Work n=3, samples (a, a, b), d = |b − a|:
  // sd = d/√3, so a 2σ band is ±1.1547·d while the outlier sits at exactly d —
  // strictly inside, and the relation is homogeneous in d, so a 0.1% outlier
  // and a 100% outlier are BOTH kept. At n=4, (a, a, a, b) gives sd = d/2 and
  // a band edge of exactly ±d, landing on the outlier, which the inclusive
  // keep test then admits. Rejection only began at n=5. Since a source
  // dropping in and out puts the fleet at 3-4 routinely, the trim was
  // inoperative in normal operation — and because the caller computes its
  // dispersion gate over the KEPT set, a single venue ~1% off the cluster
  // blew that gate and froze the mark instead of being rejected. Raising the
  // source floor does not help: it moves the failure from "trim never runs"
  // to "trim runs and cannot reject". The floor was never the defect; the
  // estimator was.
  public func trimOutliers(xs : [Float], sigmaTrim : Float) : [Float] {
    let n = xs.size();
    if (n < 3) { return xs };
    let m = switch (median(xs)) { case null { return xs }; case (?v) { v } };
    let d = switch (mad(xs)) { case null { return xs }; case (?v) { v } };
    // Floor the band width. MAD is exactly 0 whenever more than half the
    // samples share a value — three venues printing 2.27, 2.27, 2.31 is the
    // ordinary case, not a contrived one — and a zero-width band would trim
    // every sample not exactly on the median, good ones included. The floor is
    // a fraction of the mark rather than an absolute so it scales across
    // assets, and it only ever WIDENS the band, so it can admit a sample the
    // MAD would have rejected but can never reject one the MAD would have
    // kept. See TRIM_BAND_FLOOR_BPS for why it is set where it is.
    let half = Float.max(
      sigmaTrim * MAD_TO_SIGMA * madFiniteSample(n) * d,
      m * TRIM_BAND_FLOOR_BPS / 10000.0,
    );
    if (half <= 0.0) { return xs };
    let lo = m - half;
    let hi = m + half;
    var kept : [Float] = [];
    for (x in xs.vals()) {
      if (x >= lo and x <= hi) { kept := appendFloat(kept, x) };
    };
    if (kept.size() == 0) { return xs };
    kept;
  };

  // Robust median: drop samples more than `sigmaTrim * stddev` from the
  // initial median, then take the median of what's left. Falls back to
  // the simple median when there aren't enough samples (<3) to trust
  // the stddev computation.
  public func robustMedian(xs : [Float], sigmaTrim : Float) : ?Float {
    median(trimOutliers(xs, sigmaTrim));
  };

  // ── Robustness floor: how many samples it takes to MOVE a mark ─────
  //
  // Below three surviving readings the aggregate has NO defence against a
  // single bad one, and it is worth being precise about why, because the
  // obvious answer is wrong:
  //
  //   * `trimOutliers` is not the defence, even though it now works at n≥3.
  //     It returns the sample set untouched below that (nothing to trim
  //     against), and a trim can only ever reject a MINORITY — it locates the
  //     cluster with a median and a MAD, both of which need the good readings
  //     to be the majority. Give it two samples and there is no majority to
  //     find. So the trim sharpens a robust aggregate; it cannot make a
  //     non-robust one robust.
  //
  //   * The MEDIAN is the defence, and what protects it is its breakdown
  //     point — the fraction of arbitrarily-corrupted samples it tolerates
  //     before the output can be dragged anywhere the attacker likes. For n
  //     samples that is floor((n-1)/2)/n: at n=3 one source can be arbitrarily
  //     wrong and the median still lands on a good sample. At n=2 it is
  //     EXACTLY ZERO — the median of two is their mean, so a single rogue or
  //     stale venue moves the mark by half its error, without limit and
  //     without ever being trimmed.
  //
  // So n=3 is not a "nicer" sample size, it is the smallest one at which the
  // aggregate is robust at all. A caller may still HOLD a mark on two sources
  // (a stale-but-corroborated price is fine, and refusing to hold would hand a
  // liquidation cascade to whoever can knock a provider offline); what it must
  // not do is MOVE the mark on them.
  public let MIN_ROBUST_SOURCES : Nat = 3;

  // True iff a sample count is robust enough to move a mark. Callers gate mark
  // MOVEMENT on this — see the breakdown-point note above.
  public func isRobustSourceCount(n : Nat) : Bool { n >= MIN_ROBUST_SOURCES };

  // Same test over a sample set.
  public func isRobustSample(xs : [Float]) : Bool { isRobustSourceCount(xs.size()) };

  // Same test over a finished aggregate. `sourceCount` is the count of readings
  // that SURVIVED filtering, which is the set the median was actually taken
  // over — the right denominator for the breakdown-point argument.
  public func canMoveMark(agg : Aggregate) : Bool { isRobustSourceCount(agg.sourceCount) };

  // Aggregate a fleet of readings into a price + quality signal. BOTH the
  // price and the dispersion are computed over the OUTLIER-TRIMMED sample
  // set (±2σ̂ of the initial median, σ̂ from the MAD). They must share the
  // sample set: one venue printing an off-cluster price (thin market, stale
  // cache) used to blow `stddevBps` past the caller's quality gate and veto
  // the aggregate WHOLESALE — while the robust median being vetoed had
  // already excluded that very venue. (Live incident: 7 ICP sources, six at
  // $2.27–2.279 and one at $2.31 → untrimmed stddev 58bps > the 50bps gate →
  // refPrice frozen for hours on a perfectly priceable market.) That the
  // dispersion is measured on the SURVIVING cluster is the load-bearing half:
  // reporting it over cluster-plus-outlier hands the gate the very reading the
  // trim exists to discard, which reinstates the freeze the trim prevents.
  // `sourceCount` likewise matches its declared contract — readings that
  // SURVIVED filtering — so the ≥minSources floor judges the trimmed set too.
  // The full raw fleet stays in `readings` for observability.
  public func aggregate(asset : Asset, readings : [Reading], now : Int) : Aggregate {
    var okPrices : [Float] = [];
    for (r in readings.vals()) {
      // Finite-magnitude gate. A rogue source printing a ~400-digit number
      // parses to Float `inf`, and `inf > 0.0` is true — so it would slip into
      // the sample, drive trimOutliers' mean/stddev to inf/NaN, widen the trim
      // band to ±inf (the outlier is then KEPT, defeating the very trim meant to
      // drop it), and blow stddevBps to inf/NaN so the caller's quality gate
      // vetoes every tick. `< 1e15` rejects inf AND NaN (both comparisons are
      // false) while sitting far above any real asset price. Fixes the
      // one-rogue-source feed-freeze.
      if (r.ok and r.price > 0.0 and r.price < 1.0e15) { okPrices := appendFloat(okPrices, r.price) };
    };
    let kept = trimOutliers(okPrices, 2.0);
    let finalPrice = Option.get(median(kept), 0.0);
    let sd = Option.get(stddev(kept), 0.0);
    let stddevBps = if (finalPrice > 0.0) { sd / finalPrice * 10000.0 } else { 0.0 };
    {
      asset;
      price       = finalPrice;
      sourceCount = kept.size();
      stddevBps;
      timestamp   = now;
      readings;
    };
  };

  // ── Per-quote aggregation (W3-05) ─────────────────────────────────
  // Group readings by their source's quote asset, aggregate each group with
  // the same trim/median machinery, and combine explicitly:
  //   · both groups present and within `depegThresholdBps` → the pooled
  //     aggregate (maximal sources; the groups corroborate each other, so
  //     cross-quote dispersion carries no hidden signal)
  //   · groups DIVERGED → the USD group is the mark (the venue's mark is
  //     USD-denominated) with ITS dispersion and ITS source count — the
  //     divergence is reported to the caller as the depeg signal instead of
  //     being averaged into the blend
  //   · one group empty → the other, with no cross-check available
  // The returned Aggregate keeps the FULL reading fleet for observability
  // regardless of which group priced the mark.
  public func aggregateByQuote(
    asset : Asset, readings : [Reading], sources : [Source], now : Int, depegThresholdBps : Nat
  ) : { agg : Aggregate; usdCount : Nat; usdtCount : Nat; depegBps : Nat; diverged : Bool } {
    func quoteOf(sourceId : Text) : QuoteAsset {
      for (src in sources.vals()) { if (src.id == sourceId) { return src.quote } };
      #usd;   // unknown source id — treat as the mark's own denomination
    };
    var usdReadings : [Reading] = [];
    var usdtReadings : [Reading] = [];
    for (r in readings.vals()) {
      switch (quoteOf(r.sourceId)) {
        case (#usd)  { usdReadings := appendReading(usdReadings, r) };
        case (#usdt) { usdtReadings := appendReading(usdtReadings, r) };
      };
    };
    let aggUsd  = aggregate(asset, usdReadings, now);
    let aggUsdt = aggregate(asset, usdtReadings, now);
    if (aggUsd.sourceCount == 0 or aggUsdt.sourceCount == 0) {
      return {
        agg = aggregate(asset, readings, now);
        usdCount = aggUsd.sourceCount; usdtCount = aggUsdt.sourceCount;
        depegBps = 0; diverged = false;
      };
    };
    let diffBps = Float.abs(aggUsd.price - aggUsdt.price) / aggUsd.price * 10000.0;
    let depegBps = if (diffBps < 0.0) { 0 } else { Int.abs(Float.toInt(diffBps)) };
    let diverged = depegBps > depegThresholdBps;
    if (diverged) {
      { agg = { aggUsd with readings }; usdCount = aggUsd.sourceCount;
        usdtCount = aggUsdt.sourceCount; depegBps; diverged = true };
    } else {
      { agg = aggregate(asset, readings, now); usdCount = aggUsd.sourceCount;
        usdtCount = aggUsdt.sourceCount; depegBps; diverged = false };
    };
  };

  func appendReading(a : [Reading], r : Reading) : [Reading] {
    Array.tabulate<Reading>(a.size() + 1, func(i) { if (i < a.size()) { a[i] } else { r } });
  };

  // ── Body parsing ──────────────────────────────────────────────────
  // Every source response is a JSON-ish body where we only care about
  // a single number. Rather than pull in a full JSON parser we look
  // for a known key prefix (e.g. `"amount":"`) and read the leading
  // numeric token that follows. Brittle against upstream schema
  // changes but trivially auditable per-source.

  // Parse a leading signed decimal from `t`, skipping leading whitespace.
  // Stops at the first non-numeric character. Returns null if no digits.
  //
  // SCIENTIFIC NOTATION IS REFUSED, NOT TRUNCATED. A plain "stop at the first
  // non-numeric character" loop treats the `e` of `1.5e3` as a terminator and
  // silently returns the MANTISSA — 1.5 for a true value of 1500 (1000× low),
  // 1.2 for 1.2e-8 (10^8 high). This value becomes the oracle mark that drives
  // liquidations and collateral valuation, so a silently wrong magnitude is far
  // more dangerous than a missing reading: the aggregator already tolerates a
  // source returning nothing (it drops out of the sample and the remaining
  // sources carry the mark), but nothing downstream can detect a plausible-
  // looking price that is off by three orders of magnitude. In well-formed JSON
  // a digit run can only be followed by `,` `}` `]` `"` or whitespace, so an
  // `e`/`E` immediately after digits is unambiguously an exponent — refusing it
  // costs us nothing on the plain-decimal bodies every wired source emits, and
  // makes a truncated magnitude impossible rather than merely unlikely.
  public func parseLeadingFloat(t : Text) : ?Float {
    var intPart  : Nat = 0;
    var fracPart : Nat = 0;
    var fracLen  : Nat = 0;
    var sawDot   = false;
    var sawDigit = false;
    var negative = false;
    var sawNonWs = false;
    var sawExp   = false;
    label lp for (c in t.chars()) {
      if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
        if (sawNonWs) { break lp };
      } else {
        sawNonWs := true;
        if (c == '-' and not sawDigit and not sawDot) {
          negative := true;
        } else if (Char.isDigit(c)) {
          let code : Nat = Nat32.toNat(Char.toNat32(c) - 48);
          if (sawDot) {
            fracPart := fracPart * 10 + code;
            fracLen += 1;
          } else {
            intPart := intPart * 10 + code;
          };
          sawDigit := true;
        } else if (c == '.' and not sawDot and sawDigit) {
          sawDot := true;
        } else if ((c == 'e' or c == 'E') and sawDigit) {
          sawExp := true;   // exponent: refuse the whole token (see above)
          break lp;
        } else {
          break lp;
        };
      };
    };
    if (sawExp)      { return null };
    if (not sawDigit) { return null };
    var result : Float = Float.fromInt(intPart);
    if (fracLen > 0) {
      var denom : Float = 1.0;
      var i : Nat = 0;
      while (i < fracLen) { denom *= 10.0; i += 1 };
      result += Float.fromInt(fracPart) / denom;
    };
    if (negative) { result := -result };
    ?result;
  };

  // First occurrence of `needle` in `haystack`; returns EVERYTHING after it,
  // or null if not found.
  //
  // The rejoin matters. `Text.split` on a needle that occurs N times yields
  // N+1 pieces, so taking the second piece returns only the text BETWEEN the
  // first and second occurrence — not the remainder. That was invisible while
  // every caller did nothing but parse a leading number out of the result
  // (identical either way), but `numberAfterPath` chains this call: an
  // intermediate segment that truncated at its own second occurrence would cut
  // the target key out of the text before the next segment ever looked for it.
  // Re-joining the tail with the needle restores the substring this function's
  // name and docstring always claimed to return.
  public func findAfter(haystack : Text, needle : Text) : ?Text {
    let parts = Text.split(haystack, #text needle);
    ignore parts.next();
    switch (parts.next()) {
      case null { null };
      case (?first) {
        var rest = first;
        for (p in parts) { rest #= needle # p };
        ?rest;
      };
    };
  };

  // Numeric value following `key` in a JSON-ish body, tolerant of the
  // punctuation between key and value: arbitrary whitespace around the
  // colon, an optionally-quoted value, and an array wrapper (Kraken's
  // `"c":["64046.03","0.1"]`, where the first element is the last trade).
  // Handles both the compact (`"close":64046.03`, `"a":"2.29"`) and
  // pretty-printed (`"a" : "2.29"`) bodies providers emit — Crypto.com's
  // gateway pretty-prints, and a fixed `"key":"` needle would silently stop
  // matching if a provider flipped formatting.
  //
  // FIRST-OCCURRENCE, BY CONSTRUCTION: `findAfter` anchors on the first match
  // of `key` in the WHOLE body, so a short key matches any earlier field that
  // happens to share its name — `numberAfterKey("{\"a\":\"99.90\",\"ticker\":
  // {\"a\":\"2.29\"}}", "\"a\"")` reads 99.90, not the ticker's 2.29. Callers
  // that cannot prove their key is unique across the entire body must use
  // `numberAfterPath` and name the containing object.
  public func numberAfterKey(haystack : Text, key : Text) : ?Float {
    switch (findAfter(haystack, key)) {
      case null { null };
      case (?rest) {
        let value = Text.trimStart(rest, #predicate (func(c : Char) : Bool {
          c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ':' or c == '\"' or c == '['
        }));
        parseLeadingFloat(value);
      };
    };
  };

  // Numeric value at a nested PATH: every segment but the last is located in
  // the remainder left by the segment before it, so the final (often very
  // short) key is only ever searched for INSIDE the object its path names.
  // `numberAfterPath(body, ["\"ticker\"", "\"a\""])` reaches the ticker's own
  // "a" even when an unrelated `"a"` appears earlier in the body — which plain
  // `numberAfterKey` cannot do at any length of key.
  //
  // Every extractor below is built on this, not on a bare key. A key short
  // enough to be cheap to match (`"a"`, `"c"`, `"last"`, `"price"`) is also
  // short enough to collide, and the failure is SILENT: the wrong field parses
  // perfectly and becomes a price. Anchoring converts that class of upstream
  // schema drift from "wrong mark" into "no reading" — the source drops out,
  // the aggregate carries on with the rest, and `parse failed` shows up in the
  // per-source diagnostics where an operator can see it.
  public func numberAfterPath(haystack : Text, path : [Text]) : ?Float {
    let n = path.size();
    if (n == 0) { return null };
    var rest = haystack;
    var i = 0;
    while (i + 1 < n) {
      switch (findAfter(rest, path[i])) {
        case null { return null };   // container absent ⇒ not the document we expect
        case (?r) { rest := r };
      };
      i += 1;
    };
    numberAfterKey(rest, path[n - 1]);
  };

  // Pull the price out of one source's response body.
  //
  // Every WIRED extractor names the CONTAINING OBJECT of the field it wants and
  // reads the field from inside it (`numberAfterPath`). The old bare-key form
  // took the first match anywhere in the body, which made each extractor's
  // correctness rest on an ordering accident — "no other key in the body
  // contains `"a"`" is a property of today's response, not of the contract, and
  // an upstream field added ABOVE the container silently re-points the parse at
  // a different number. Anchoring makes the container part of the match, so
  // drift produces null (source drops out, aggregate survives) instead of a
  // confident wrong price. The comments record the real body shapes, captured
  // live 2026-07-11 and pinned by tests/PriceFeed.test.mo.
  public func extractFromBody(kind : SourceKind, body : Blob, asset : Asset) : ?Float {
    let text = switch (Text.decodeUtf8(body)) {
      case null { return null };
      case (?t) { t };
    };
    switch (kind) {
      case (#coinbase) {
        // {"data":{"amount":"75517.39","base":"BTC","currency":"USD"}}
        numberAfterPath(text, ["\"data\"", "\"amount\""]);
      };
      case (#coingecko) {
        // {"bitcoin":{"usd":75490}} — the outer key is the coin id we asked
        // for (`ids=bitcoin`), so anchoring on it does double duty: it scopes
        // the 5-char "usd" to the right object AND confirms the body answers
        // the asset we requested rather than a cached neighbour.
        numberAfterPath(text, ["\"" # assetSymbol(#coingecko, asset) # "\"", "\"usd\""]);
      };
      case (#coinpaprika) {
        // NOT WIRED (see PRICE_SOURCES in main.mo) — left as-is deliberately.
        // {"id":"btc-bitcoin",…,"quotes":{"USD":{"price":X.XX,…}}}
        switch (findAfter(text, "\"USD\":{\"price\":")) {
          case null {
            switch (findAfter(text, "\"price\":")) {
              case null { null };
              case (?rest) { parseLeadingFloat(rest) };
            };
          };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#krakenLike) {
        // {"error":[],"result":{"PAIRUSD":{"a":[…],"b":[…],"c":["X.XX","VOL"],…}}}
        // — c[0] is the last trade. Anchor under "result" so a `"c"` inside an
        // "error" array (which PRECEDES result, and carries free-form provider
        // text) can never be the match; numberAfterKey steps over the `["`.
        numberAfterPath(text, ["\"result\"", "\"c\""]);
      };
      case (#okx) {
        // {"code":"0","msg":"","data":[{"instId":"ICP-USDT","last":"2.779",…}]}
        // — anchor under "data" so the envelope can grow fields freely. The
        // needle carries its closing quote, so "lastSz" is not a match.
        numberAfterPath(text, ["\"data\"", "\"last\""]);
      };
      case (#kucoin) {
        // {"code":"200000","data":{"time":…,"price":"2.777","size":…,
        //  "bestBid":"2.777","bestAsk":"2.779"}} — data.price is the last
        // trade; it precedes bestBid/bestAsk INSIDE data, and anchoring on
        // "data" keeps the envelope out of the search.
        numberAfterPath(text, ["\"data\"", "\"price\""]);
      };
      case (#cryptocompare) {
        // NOT WIRED (see PRICE_SOURCES in main.mo) — left as-is deliberately.
        // {"USD":2.774} — value is a bare number, not a quoted string.
        switch (findAfter(text, "\"USD\":")) {
          case null { null };
          case (?rest) { parseLeadingFloat(rest) };
        };
      };
      case (#htx) {
        // {"ch":"market.icpusdt.detail.merged","status":"ok","ts":…,
        //  "tick":{"open":63167.0,"close":64046.03,…}} — tick.close is the last
        // trade, a bare number. Anchoring on "tick" makes "appears only inside
        // tick" structural instead of observed. Error bodies carry no "tick" →
        // null → ok=false, as before.
        numberAfterPath(text, ["\"tick\"", "\"close\""]);
      };
      case (#cryptocom) {
        // {"result":{"data":[{"i":"BTC_USDT","h":"…","l":"…","a":"64084.20",…}]}}
        // — data[0].a is the latest trade. The gateway pretty-prints
        // (`"a" : "64084.20"`), which numberAfterKey absorbs. `"a"` is THE
        // pathological short key: three characters, and the old bare-key form
        // survived only because nothing above it in the body happened to
        // contain them. Anchored under result → data, it cannot.
        numberAfterPath(text, ["\"result\"", "\"data\"", "\"a\""]);
      };
      case (#binance) {
        // {"symbol":"BTCUSDT","price":"64158.01000000"} — a flat two-key
        // document with no container to anchor to, so anchor on the sibling
        // that always precedes the price. That also rejects any OTHER body
        // that happens to carry a "price" (e.g. an error envelope) as not
        // being the ticker document.
        numberAfterPath(text, ["\"symbol\"", "\"price\""]);
      };
    };
  };
};
