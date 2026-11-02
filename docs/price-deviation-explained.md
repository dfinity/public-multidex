# Why trades sometimes print far from mid, "past the AMM ladder"

*Written 2026-06-09. Grounded in `src/backend/lib/MatchingEngine.mo`, `src/backend/main.mo` (matching contexts, the deferred/GEPTOR release, and `updateStatsAfterTrades`), and `src/backend/lib/AMM.mo`. Cross-checked against the live canister.*

## The symptom

Events occasionally shows a line like:

> ICP trade at $2.44 — +5.77% from mid $2.31 · AMM ladder NOT matched — 15 AMM asks still on book @ 2.29–2.41 (deepest $2.41); order filled past them into stranded book liquidity · inv +37.22% vs target

i.e. a trade printed well off the oracle mid, *beyond* the AMM's own quoted ladder, while that ladder was visibly still resting on the book. On the live system right now the same machinery is producing the milder, benign variant:

> SOL trade at $63.79 — −1.80% from mid $64.95 · AMM bids empty at fill time — consumed since the last requote
> ICP trade at $2.25 — −1.03% from mid $2.27 · AMM bids empty at fill time — consumed since the last requote

Both come from the same root. The difference between them ("warn" vs "info") is the whole story, so it's worth being precise.

## The root cause: the AMM's quotes are *indicative*, not takeable

The AMM does not trade by having its resting quotes hit. Its ladder is **non-takeable** — `MatchingEngine` is handed an `isNonTakeable(orderId, owner)` predicate, and when the best maker on the book is an AMM quote, the matcher **skips it** (`MatchingEngine.mo:181` for market orders, `:488` for limit orders) and walks the taker on to the next maker:

```
// Indicative (AMM) makers are not takeable: skip so this taker walks
// past them and rests the remainder at its limit. The AMM fills resting
// orders itself on its next requote (at its fresh price).
```

Instead, every incoming order is **sealed off-book until the next fresh-price moment** ("GEPTOR" = get-fresh-oracle-price-then-requote). `placeMarketOrder` and `placeLimitOrder`* don't match anything synchronously — they `parkDeferred(...)` the whole order at its slippage cap (`main.mo:3135`, `:2767`). On the next requote the pool re-prices, *then* the staged order is released (`processDeferred`, `main.mo:1415`) against the **fresh** AMM plus any crossing user liquidity. Release is anti-snipe gated: an order only fires once a fresh price *postdates* it (`d.ts < pool.refPriceUpdatedNs`, `main.mo:1434`).

Why build it this way? It makes the AMM impossible to pick off on a stale quote. You can never see the AMM's price, fire an order at it, and get filled at that now-stale number — by the time you execute, the pool has re-fetched the oracle and re-quoted. That is the core anti-arbitrage / anti-sandwich protection of the "sealed model."

The cost of that protection is the subject of this doc: **between requotes, the AMM's near-side liquidity can be momentarily absent or unusable, and a taker can reach a user order sitting further from mid.**

## Two flavors of the same event

`updateStatsAfterTrades` (`main.mo:3364`) inspects each trade batch, finds the worst deviation from mid, and asks: *did the worst fill land beyond the AMM's deepest open quote on that side?* If yes and |dev| ≥ 1%, it logs — and it picks the severity by **why** the AMM wasn't there:

### (a) "info" — the near side was simply eaten and hasn't refilled yet

This is what's live right now. Flow is one-sided (lots of sells), the AMM's **bid** rungs get consumed faster than the ~2 s requote cadence refills them, and for a moment the best remaining liquidity on the bid side is a *user* order 1–2 % below mid. The sell fills there. `span.count == 0` (the AMM's bids really are gone), the oracle is fresh, no floor is engaged → the code calls this benign and logs it as **info**:

> "AMM bids empty at fill time — consumed since the last requote; refills on the next (~2s), not a withdrawal"

This is normal market-maker behaviour: a CLOB market maker also shows a thin side under one-sided pressure until it re-quotes. The 1–2 % is bounded by where the nearest user bid sits, and it mean-reverts as soon as the AMM re-quotes.

### (b) "warn" — the ladder is *still resting* but a fill went past it

This is the quoted $2.44 example. Here `span.count > 0` — the AMM's asks (all 15, *including the cheapest 2.29 rung*) are still on the book — yet a buy filled at 2.44, past the whole ladder. A normal taker fills cheapest-first; if the 2.29 rung is untouched, the taker **did not match the AMM at all**. The only way that happens is a taker for whom the AMM is non-takeable: a **forced/internal taker that *is* the AMM**. The code names exactly these (`main.mo:3373`):

> • forced/internal takers (AMM rebalance + liquidation collateral sales) that route through `buildProtectionCtx`, where the AMM's own quotes are NON-TAKEABLE — so the AMM, as taker, skips its full bid/ask ladder and dumps into stranded book liquidity (the recurring wick)

When the AMM rebalances (it's carrying too much or too little of an asset) it crosses the spread *as a taker* (`ammExecuteRebalance`, `main.mo:1811`). But it can't trade with itself, so its own ladder is invisible to it — it skips all 15 of its own asks and reaches whatever *user* order is next, which can be a lone "stranded" arb order sitting at +5.77 %. That print is the candle wick, and it's a genuine concern because the AMM is also moving real vault inventory at a bad price.

The "inv … % vs target" suffix is context, not cause: it just reports how far the vault's holding of that asset is from its 12.5 % target — which is *why* the rebalancer is active in the first place.

## What already bounds it

1. **Forced-taker band cap** (`bandCappedSlippage`, `main.mo:1795`, commit `0f13f7b`). A rebalance/liquidation taker's slippage is clamped to the AMM's *own* quoted band on the side it hits — so it can only reach within-band user liquidity, and the IOC leftover is dropped rather than chasing a distant order. This is the primary fix for the (b) wick.
2. **Liquidation internal-absorb** (`Liquidator.mo`, this branch). Cross-token seizures no longer sell collateral on the book at all — they absorb into the vault at the oracle mid. A self-trade against the AMM's own resting ladder can't substitute for a real sale under the sealed model, so routing it through the book was the old wick source; it's gone.
3. **±6 % out-of-band clamp** (`OUT_OF_BAND_PCT = 0.06`, applied in `releaseDeferred` on the users-only fallback path, `main.mo:1372`). When the AMM is sidelined (oracle stall), a released order can't run past ±6 % of mid into a stale stranded order — near-mid user liquidity still fills, the wick can't. Note this is the ceiling that lets +5.77 % through: it sits *just under* the 6 % band.
4. **Mid-anchored slippage band** (`main.mo:3118`). Market-order slippage is measured from the AMM/oracle mid, not the book's best order — so when the ladder is momentarily pulled, the cap doesn't re-anchor to a stranded far quote and inflate.

## Bottom line

- The price can leave mid because the AMM's quotes are *indicative and non-takeable*; real fills happen against user liquidity (or the AMM's own next requote), and between requotes the near side can be thin.
- The **frequent, mild** version (what's live: SOL/ICP −1 to −2 %, "info") is benign one-sided flow eating a side faster than the ~2 s refill. It self-corrects.
- The **rarer, larger** version (the +5.77 % "warn") is the AMM's *own forced taker* skipping its non-takeable ladder into a stranded order. That's the real defect, and it's already mitigated by the band cap and liquidation internal-absorb; the residual is whatever slips under those plus the ±6 % clamp ceiling.

## Options to reduce it further (not yet done — flagged for decision)

- **Tighten `OUT_OF_BAND_PCT`** from 6 % toward ~3 %. Directly caps the worst wick; risk is rejecting legitimate fast-move fills, so it should track real oracle volatility.
- **Give the rebalancer a maker-first path**: post a within-band IOC *limit* at its own quote edge instead of a market-taker, so it never reaches past its ladder even within the band. Cleaner than relying on the band cap to truncate a market order.
- **Seed/keep deeper near-mid user liquidity** (sim or incentivised) so there are no stranded gaps for a skipping taker to fall into. The wick magnitude is ultimately set by *where the nearest user order is*; closing the gaps shrinks it.
- **Suppress stranded far orders**: an order-book maintenance pass that cancels/expires user limits more than X % from mid would remove the targets these takers fall into (the sim bots are a known source of such strays).
