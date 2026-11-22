# W3-05 — USD and USDT venues are pooled into one median and one dispersion

**Issue:** [#17](https://github.com/dfinity/public-multidex/issues/17) item 3 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` HIGH
**Effort:** L

## What's wrong

`PriceFeed.aggregate` folds every reading into one `okPrices` array and computes a single median and
a single dispersion. The source list mixes **USD-quoted** venues (coinbase, coingecko) with
**USDT-quoted** venues (okx, kucoin, htx, cryptocom, binance), and the XRC anchor is fetched with
`quote_asset = { symbol = "USDT" }`.

So the mark the venue calls "USD" is really a blend of USD and USDT prices, and the anchor that is
supposed to catch a drift sits on the USDT side of it. During a USDT depeg — the exact scenario an
anchor exists for — the blend moves, the anchor moves with it, and the dispersion gate sees
agreement rather than disagreement.

This is a *pricing correctness* issue, not an availability one: it silently mis-marks every
position, margin health and liquidation threshold by the depeg magnitude.

## Evidence

- `src/backend/lib/PriceFeed.mo:358-383` — `aggregate`, one `okPrices` fold → one median, one stddev;
  no per-quote grouping
- `src/backend/main.mo:12974+` — `PRICE_SOURCES` mixes USD- and USDT-quoted venues
- `:13771` — XRC anchor `quote_asset = { symbol = "USDT" }`
- `:13750` — the comment explaining the USDT choice ("matching the Kraken primary leg")

## Fix

Two defensible designs; pick one deliberately and write down which:

1. **Normalize to one quote.** Convert USDT-quoted readings to USD using a USDT/USD rate before
   aggregation, and anchor on the USD side. Correct, and adds a dependency on a USDT/USD source.
2. **Tag and aggregate per quote.** Group readings by quote asset, aggregate each group separately,
   and combine with an explicit, documented rule — including what happens when the two groups
   disagree by more than a threshold (that disagreement *is* the depeg signal, and it is currently
   invisible).

Either way the XRC anchor should sit on whichever side the pool's mark is denominated in.

## Done when

- [x] The mark's quote asset is explicit, documented, and consistent from source to anchor
- [x] A simulated USDT depeg moves the two groups apart and is **detected**, not averaged away
- [x] Dispersion is computed within a quote group, not across quotes
- [x] `oracle-xrc-fallback-design.md` reflects the chosen design

## Completed 2026-08-15 — design 2 (tag and aggregate per quote), chosen deliberately

- Every `PriceFeed.Source` carries `quote : {#usd; #usdt}` (coinbase/coingecko USD; okx, kucoin,
  htx, cryptocom, binance, kraken USDT). `PriceFeed.aggregateByQuote` aggregates each group with
  the same trim/median machinery and combines explicitly: agreement (≤100bps) → pooled (maximal
  sources, groups corroborate); DIVERGED → the mark follows the **USD group** with its own
  dispersion and count, and the divergence is logged loudly as the depeg signal; one group empty →
  the other prices alone with no false signal. The full reading fleet stays on the stored
  aggregate for observability, and the Aggregate type is unchanged (it persists in
  `lastAggregates` — layout-stable).
- The XRC anchor request is now `quote = USD (fiat)` — the anchor sits on the mark's denomination
  instead of on the depegging side of the blend it was meant to catch.
- Depeg simulation lives at the unit level (`tests/PriceFeedQuotes.test.mo`, 14 green): a +10%
  USDT-group split is detected at ≈1000bps with the mark at the USD median and tight USD-group
  dispersion, contrasted against the pooled aggregate that would have carried the depeg as mere
  dispersion. Wiring pinned in hygiene §6e; design documented in
  `docs/oracle-xrc-fallback-design.md` §"Quote bases".
- Live agreement path verified against real sources (fetchAndSetRefPrice → ok); oracle suites
  green (xrc_fallback 13/0, time_bases 6/6).
- **Bonus**: the whole-main.mo hygiene haystack (≈488KB) tripped W5-10 item 3's SIGPIPE matcher
  race deterministically — fixed in the same pass (matchers drain via `grep -cF >/dev/null`),
  verified stable across repeated runs. Noted in W5-10.

## Notes

Large enough to deserve its own change with its own tests. Sequence it after
[W3-06](W3-06-confirmation-gate-sample-time.md) and [W3-07](W3-07-xrc-anchor-aging.md), which touch
the same pipeline in smaller ways, or plan all three as one oracle pass.
