# W4-08 — The arb's per-tick clip is 2.05× the DEX's per-call cap, so its inventory is unflattenable

**Issue:** [#24](https://github.com/dfinity/public-multidex/issues/24) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` N/A (`extMarketSwap` refuses on `IS_PRODUCTION`)
**Effort:** S

## What's wrong

Two constants in two canisters with no shared source, no assertion and no fallback:

- `src/arb/main.mo:53` — `TRADE_CAP_USD = 1_025_000_000_000` = **$10,250**
- `src/backend/main.mo:5050` — `ARB_MAX_SWAP_USD = 500_000_000_000` = **$5,000**

The arb sizes a leg up to $10,250; the DEX rejects anything over $5,000 with
`#err("Exceeds per-call cap")`. The **flatten** step is the arb's only way to close a position, and
it is the step that is refused — while the cheap branch buys through the ordinary limit-order path,
which is **not** subject to `ARB_MAX_SWAP_USD` and can go to the full $10,250. So one fully-filled
cheap-side buy leaves the arb holding more inventory than its own exit accepts, and it retries every
5 s forever.

"Permanent" with a caveat: the stuck predicate is evaluated against the *current* mark, so a
sufficient mark decline drops the notional under $5,000 and frees it. Nothing makes that happen; it
is weather.

`getArbStats()` already exists and could publish the cap — the arb never reads it.

## Evidence

- `src/arb/main.mo:53` — `TRADE_CAP_USD`; `:203-205`, `:215`, `:222-224` — the sizing and the calls
- `src/backend/main.mo:5050` — `ARB_MAX_SWAP_USD`; `:5177` — the rejection
- `:5231`, `:5249` — `getArbStats` publishes `perCallCapUsd`; **no reader in `src/arb/`**

## Fix

Immediate (one line): hard-set `TRADE_CAP_USD ≤ ARB_MAX_SWAP_USD`.

Proper: make the DEX the single source of truth — clamp every leg to
`Nat.min(capBase, mulDiv(perCallCapUsd, SCALE, mark, false))` read from `getArbStats()` — and add a
slice loop so a position larger than the per-call cap is exported in cap-sized chunks across ticks
rather than not at all.

## Done when

- [x] No arb leg can be sized above the DEX's advertised per-call cap
- [x] A position opened at full clip can be fully flattened
- [x] The two constants cannot silently diverge again (shared source or an assertion)

## Notes

The other four arb findings are deferred together in
[W4-17](W4-17-arb-design-cluster.md); this one is split out because it is a one-line fix for a
self-inflicted stuck state.

## Completed 2026-08-15 (W4 batch 1)

Immediate fix taken: `TRADE_CAP_USD` clamped to $5k (= `ARB_MAX_SWAP_USD`) with the incident
documented at the constant. Divergence pinned forever in hygiene §6h (arb ≤ DEX, compared from
both sources). The "proper" variant (read the cap from `getArbStats` + slice large positions
across ticks) is recorded in W4-17's cluster, where the remaining arb findings live.
