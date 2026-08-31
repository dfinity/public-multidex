# Oracle hardening: the M3 floor + XRC as a fallback anchor

Status: IMPLEMENTED (this commit). Closes the last open oracle item from the
2026-06-09/13 reviews (M3 — "GEPTOR accepts a single-source price") and adds a
verified-facts design for using the IC's exchange-rate canister (XRC) without
touching GEPTOR's latency.

## 1. Verified XRC facts (source: dfinity/exchange-rate-canister @ main)

The claim to check was: *"XRC quotes are out of date — it only updates every
thirty seconds or so, and to work with GEPTOR we would have to wait ~15s."*
Reading the source confirms the substance and sharpens the numbers:

- **Rates are minute-granular, offset 30s into the past — by design.**
  `utils.rs :: get_normalized_timestamp`: a request with no timestamp is
  served for `((now − 30s) / 60) × 60` — thirty seconds are subtracted, then
  the result truncates to the start of that minute. So the freshest rate XRC
  will serve lags wall-clock by **30–90 seconds** (≈60s on average),
  structurally. The offset exists because upstream exchanges need time to
  publish each minute's candle; asking for a newer minute yields errors, not
  fresher data.
- **Fetches happen at request time, per (pair, minute) cache key.**
  A cache miss fires HTTPS outcalls to multiple exchanges *during your call*
  (multi-second), then caches the median for that minute. A cache hit returns
  quickly. Either way the caller pays a cross-subnet update-call round trip
  (~2–4s floor); a cold pair/minute can take ~10s+.
- **Requests can fail transiently.** `api.rs` returns
  `Pending` (`AlreadyInflight` — someone else is fetching that pair/minute;
  `PastTimestampNotCached`) and `RateLimited` (global in-flight cap), i.e. a
  caller may need retries — consistent with the observed "~15s wait".
- **Cost:** 1B cycles must be attached per call (`XRC_REQUEST_CYCLES_COST`);
  the unneeded remainder is refunded (base fee 20M on cache hits; more when
  outcalls run). Mainnet canister id: `uf6dk-hyaaa-aaaaq-qaaaq-cai`.

**Conclusion — the user's architectural call is forced, not just preferred.**
GEPTOR's anti-snipe design needs second-scale freshness (a release price must
postdate the staged intent by seconds). XRC is minute-scale and 30–90s lagged,
with multi-second, sometimes-Pending calls. It can never sit in the GEPTOR hot
path, and it can't even be a same-tick quorum member (comparing a t and a
t−60s price in a fast market manufactures false divergence). What XRC *is*
good for: an independent, exchange-aggregated **anchor** that keeps marks
honest when the primary feed degrades, and a slow cross-check on the primary.

## 2. What the primary feed already is (current code)

`refreshMultiSourcePrice` fans out parallel non-replicated HTTPS outcalls to
**three independent providers** (Coinbase, CoinGecko, Kraken —
`PRICE_SOURCES`), takes the median, computes stddev, and edge-logs health
against `PRICE_MIN_SOURCES = 2`. The **periodic** path (`tickPriceRefresh`)
already enforces the full quality gate:

    sourceCount >= PRICE_MIN_SOURCES  AND  stddevBps <= PRICE_MAX_STDDEV_BPS
    AND acceptOrPendPrice (the ±2.5% jump breaker)

**The M3 hole**: the **GEPTOR** path (`geptorFetchAndSweep`) gated on
`sourceCount > 0` — with a single responding source, stddev is trivially 0 and
the price is accepted (bounded only by the jump breaker: a 2.5%-per-tick
mark-walk for whoever controls the one surviving source). The admin
`fetchAndSetRefPrice` had the same single-source acceptance.

## 3. Design

### 3.1 One accept gate, three callers (closes M3)

A single helper now owns aggregate acceptance:

    applyFreshAggregate(marketId, baseToken, agg, now) : { #applied : Nat; #pended; #rejected : Text }

- quality gate: `sourceCount >= minSources()` and `price > 0` and
  `stddevBps <= PRICE_MAX_STDDEV_BPS`;
- jump breaker: `acceptOrPendPrice` unchanged;
- **fallback**: if the quality gate FAILS, try the XRC anchor (§3.2) instead —
  if a fresh anchor exists, it is applied *through the same jump breaker* and
  the application is event-logged as a fallback;
- callers: `geptorFetchAndSweep`, `tickPriceRefresh`, `fetchAndSetRefPrice`.
  GEPTOR's latency is untouched: the helper is synchronous state logic; the
  only await in the hot path remains the primary fetch it always did.

`minSources()` = `PRICE_MIN_SOURCES` (2) with a controller-only,
non-production override (`setTestMinSources`) so tests can force the
degraded path deterministically.

### 3.2 XRC anchor (background, never in the hot path)

    xrcAnchors : Map<asset, { rateE8; xrcTimestampSecs; receivedNs; xrcSources }>

- A heartbeat task every `XRC_ANCHOR_PERIOD_NS = 120s` refreshes anchors for
  the enabled pools' base assets, one asset at a time, `await`ing XRC
  (`get_exchange_rate` with **no timestamp** — the canonical freshest
  normalized minute; **quote = USD (fiat)** as of W3-05 — the anchor sits on
  the MARK's denomination. It was USDT "matching the Kraken leg", which put
  the depeg detector on the depegging side of the blend it was meant to
  catch). All errors (`Pending`,
  `RateLimited`, decode failures, missing canister) are caught and simply
  leave the previous anchor in place — the fallback degrades to "no anchor",
  never to a wrong price.
- **Wired principal, not a hardcoded id**: the loop no-ops until a controller
  calls `setXrcCanister(?principal)` (a stable field — survives upgrades,
  must be re-applied after a reinstall, like `setBridge`). On mainnet that's
  the real XRC (`uf6dk-hyaaa-aaaaq-qaaaq-cai`); on a local replica it's the
  dev-only `xrc-mock` canister (`src/xrc-mock/main.mo` — same candid, same
  cycles demand, same timestamp normalization), wired by `cold_start.sh`, so
  the REAL call path (cycles attach, decode incl. the `class_` keyword
  escape, decimals→e8) is exercised before any value-bearing deploy. On a
  play-mode cloud engine that can't reach the NNS subnet, simply leave it
  unwired — same graceful no-anchor degradation. Tests can also inject
  anchors directly via the dev-only `setTestXrcRate(asset, ?rateE8)` hook,
  and force a fetch through the wire with the controller-only
  `adminRefreshXrcAnchors()` (also the mainnet smoke test).
- Freshness bound for USE: `XRC_ANCHOR_MAX_AGE_NS = 180s` since `receivedNs`.
  Worst-case honest lag of an applied anchor ≈ anchor age (≤180s) + XRC's own
  30–90s — comfortably inside the exchange's existing 5-minute staleness wall
  (`AMM_MAX_REFPRICE_AGE_NS`), so the AMM keeps quoting through a primary
  outage instead of pausing, with the breaker still bounding movement.
- Cycles: 4 assets × ≤1B / 120s ⇒ ≤ 2.9T/day worst case, much less in
  practice (per-minute cache keys are shared IC-wide; popular pairs hit the
  cache at 20M). Attached per call with `(with cycles = 1_000_000_000)`.

### 3.3 Divergence cross-check (alarm, not a trip)

When the PRIMARY gate passes and a fresh anchor exists, a deviation greater
than `XRC_DIVERGENCE_ALARM_BPS = 300` logs a `warn` oracle event AND raises a
per-token alarm (`_divergenceAlarms`, exposed as `getCanisterInfo().
oracleDivergence`) that the frontend renders as an app-wide amber banner —
same chrome mechanics as the fuel banner; the next in-band accept clears it,
and the UI ages stale alarms out after 10 minutes. Deliberately
**alarm-only**: the two readings sit on different time bases (0s vs 30–90s+),
so honest fast markets diverge transiently — auto-halting here would
manufacture outages. The jump breaker already bounds how far any single tick
can move the mark; the alarm exists so a slow poisoning of the primary
(within-breaker walking away from the anchor) is visible to every user and
operator, not just in the event log.

### 3.4 Failure semantics (unchanged, now explicit)

With the floor enforced everywhere: primary below floor → anchor fresh →
**anchor applies** (minute-lagged, breaker-bounded, logged). Primary below
floor and no fresh anchor → refPrice freezes and the existing machinery does
what it always did: AMM pauses quoting at 5-min staleness (panic-cancel
later), sealed orders fall to the band-capped users-only path, LP mints refuse
(`vaultPricesStale`, incl. the M1 pend gate). Fail-stalled, never fail-open.

### 3.5 Explicitly out of scope here

- ~~`setAmmRefPrice` remains a dev/test override — production-gating it is a
  deploy-time checklist item~~ DONE: it is now dev-only (`DEPLOY_MODE = #dev`),
  dead on both #play and #production — see docs/deployment-modes.md.
- Weighting XRC as a hot-path quorum member: rejected (time-base mismatch).
- Auto-halt on divergence: rejected v1 (see §3.3).

## 4. Tests

- `tests/test_oracle_xrc_fallback.sh`:
  1. floor pinned high (`setTestMinSources`) + NO anchor → `fetchAndSetRefPrice`
     errors and refPrice stays frozen (old fail-safe);
  2. inject an in-breaker anchor (`setTestXrcRate`) → same call now applies the
     anchor via the fallback, refPrice == anchor, "XRC fallback" event logged;
  3. inject an anchor beyond the ±2.5% breaker → fallback is PENDED, refPrice
     unmoved (a poisoned anchor cannot leap the mark);
  4. pin cleared → primary path unaffected (control);
  5. the REAL call path through the local `xrc-mock`: wire it, set a 9-decimal
     rate, `adminRefreshXrcAnchors` → the anchor lands converted to e8 with
     metadata intact; unknown symbol → error → no anchor (fail-safe), unwire.
- GEPTOR/tick share `applyFreshAggregate`, so the same wiring is exercised.
- The XRC binding is deliberately fail-safe: a decode/transport error just
  means "no anchor", which the tests above cover.

## Quote bases (W3-05, 2026-08-15)

The venue's mark is **USD-denominated**. The primary feed's sources are
tagged with their quote asset (`PriceFeed.Source.quote`: coinbase/coingecko
= USD; okx/kucoin/htx/cryptocom/binance/kraken = USDT), and
`PriceFeed.aggregateByQuote` aggregates each group separately with the same
trim/median machinery:

- groups **agree** (≤ `USDT_DEPEG_ALARM_BPS` = 100bps apart) → the pooled
  aggregate prices the mark (maximal sources; the groups corroborate each
  other);
- groups **diverge** → the divergence IS the depeg signal: a loud `warn`
  event names the magnitude and both group sizes, and the mark follows the
  **USD group** with its own dispersion and source count (which may drop it
  below the source floor — then the XRC fallback applies, and that anchor is
  USD-quoted too, so anchor and mark sit on the same side);
- one group **empty** → the other prices alone; no cross-check, no false
  signal.

Pre-W3-05 all eight venues fed one median: a USDT depeg moved the blend, the
USDT-quoted anchor moved with it, and the dispersion gate saw agreement —
the exact scenario an anchor exists for was invisible. The pure combine
logic is pinned by `tests/PriceFeedQuotes.test.mo`.
