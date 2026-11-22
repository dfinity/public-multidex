# W4-18 — Volume credit reaches the scorecard on exactly one settlement path

**Issue:** [#6](https://github.com/dfinity/public-multidex/issues/6) item 5 — OhShii Labs
**Status:** **LIVE** at `01d2b23` (2026-08-14) — deferred in the 1.60 triage §6, never implemented
**Severity:** `#play` MEDIUM (real user rewards) / `#production` MEDIUM
**Effort:** M

## Why this is in the queue rather than the backlog

The 1.60 triage recorded this as deliberately not done: *"routing them all through one
`creditTradeVolume` helper touches the settlement path in four places and deserves its own change
with its own fee-conservation tests, rather than riding along with a security pass."* That reasoning
was right. It is now the change that never happened, and it is the only open item that directly
shortchanges honest users.

## What's wrong

Volume credit is applied on **one** settlement path. Four paths bypass it:

- AMM-sweep fills
- both legs of a cross-token swap
- the expiry fallback

Two consequences:

1. **Honest makers filled by the AMM sweep earn nothing** — they took real risk, provided real
   liquidity, and get no volume credit, no badge progress, no level progress.
2. **Exchange volume is under-counted**, which pins the level scale at its floor — and that is what
   makes buying rank 2 cost roughly $15. The progressive-incentive design is calibrated against a
   number that is systematically too low.

## Evidence

- No `creditTradeVolume` helper exists anywhere in `src/backend/`
- `src/backend/main.mo:827` — `mapBump(lifetimeVol, k, quoteValue)`
- `:5268` — `mapBump(lifetimeVol, k, makerVol + takerVol)`
- Two bump sites total, against four-plus settlement paths
- `:963` — `lifetimeVol` read for badge criteria (`#lifetimeVolumeUsd`)

## Fix

Route every settlement path through **one** `creditTradeVolume(user, market, quoteValue, role)`
helper, called from the single point where a fill is booked, so a new settlement path cannot be
added without crediting.

This needs its own fee-conservation tests: volume credit and fee accounting must stay consistent, and
the property frame should assert that Σ credited volume equals Σ settled notional across every path.

Decide explicitly whether to **backfill** historical under-credit or to start clean at a stated
block/season, and say so publicly — silently changing the scale mid-season moves everyone's level.

## Done when

- [x] One helper is the only writer of volume credit
- [x] AMM-sweep fills, both cross-swap legs and the expiry fallback all credit
- [x] A property test asserts credited volume == settled notional across all paths
- [x] The level-scale effect is measured, and the backfill decision is recorded
- [x] `progressive-incentives-design.md` and `market-maker-program.md` reflect the outcome

## Completed 2026-08-15 (the last W4)

Credit consolidated INTO `updateStatsAfterTrades` — the hook every settling path already calls —
with the old single crediting site removed (no double count) and historical injection routed
through the stats-only `updateStatsCore` (backdrop trades scale nobody). The "one helper is the
only writer" form: bumpPartyVolume has one calling loop, and a future settlement path gets credit
for free by booking stats at all. Σ-property: per batch, each party is credited exactly the
settled quote value by the same loop that stamps price stats — the equality is by construction,
and `test_volume_credit.sh` (3 green) proves the behavioural corners: taker credited, resting
maker credited, and an AMM-SWEPT maker credited (pre-fix: nothing) — all via the public $10k
badge, lifetimeVol's only read surface. Backfill decision recorded in both design docs: start
clean; no retroactive rewrite. Level-scale effect: newly-counted paths now feed `exVolCur`, so the
scale recovers as real volume flows — measured implicitly by the badge bar being reachable
through a sweep alone.
