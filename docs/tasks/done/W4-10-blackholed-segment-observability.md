# W4-10 — Blackholed archive segments are never re-observed, so the chain table shows a stale `ok`

**Issue:** [#26](https://github.com/dfinity/public-multidex/issues/26) item 3 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW–MEDIUM / `#production` LOW–MEDIUM
**Effort:** S

## What's wrong

`_archiveObs` is written **only inside the `try`**, after `ic00.canister_status` succeeds — and
`canister_status` requires controllership. Seal-time blackholing (`update_settings { controllers = ?[] }`,
gated by `_blackholeAtSeal`) permanently removes that controllership. From then on the status call
rejects, control falls to the catch, and `_archiveObs` for that principal is **never refreshed
again**. `getArchiveChain` serves whatever is in `_archiveObs`, and the frontend renders it.

So the segments that are **immutable by design and therefore unfixable** are exactly the segments
whose health is never observed again, and the dashboard reports the last-known `ok` indefinitely.

The freeze half is now partly mitigated — the catch blind-funds sealed archives — but the
*observation* is still never refreshed, and the headroom skip in that catch still logs nothing.

## The fix already exists ~150 lines away

`tickBridgeFuel` reads the callee's own `cyclesBalance()` query **precisely because**
`canister_status` would need controllership, and its comment says so. `ArchiveCanister.stats()` is a
public query returning `cycles`, and the frontend already calls it directly. The affordance exists,
is already consumed elsewhere, and is the one thing that restores visibility on the segments that
cannot be status-read.

## Evidence

- `src/backend/main.mo:6662` — `ic00.canister_status`; `:6668` — `_archiveObs` written inside the try
- `:6688` — the catch; `:6695-6702` — blind-fund, but no obs refresh, no `stats()` fallback
- `:6741-6745` — `getArchiveChain` serving the stale observation
- `:7793` — seal-time blackholing
- `:6784+` — `tickBridgeFuel`'s controllership-free probe, the pattern to copy

## Fix

Fall back to `stats()` / `cyclesBalance()` when `canister_status` rejects, and mark the observation
**degraded** rather than leaving the previous one in place. Also log the silent skip — today a
blackholed segment that fails the blind-fund headroom test is skipped with no event at all.

## Done when

- [x] A blackholed segment's cycles are still observed and shown
- [x] Its row is visibly marked degraded rather than showing a stale `ok`
- [x] The headroom skip emits an event
- [x] Feeds [W1-03](W1-03-archive-execute-hop-isolation.md)'s "skip segments observed frozen"

## Completed 2026-08-15 (W4 batch 2)

When `canister_status` rejects on a sealed segment, the observer falls back to the segment's own
public `stats()` (the tickBridgeFuel pattern), refreshes `_archiveObs` (freeze limit = last known),
and marks the row DEGRADED via a parallel transient map (extending stable `ArchiveObs` would
change its layout). `getArchiveChain` exposes `degraded`; the silent headroom skip now logs. New
`adminRunArchiveFuelPass` runs the pass on demand (the cadence is 5 min). `test_w4_batch2.sh` §3:
a live-blackholed segment is re-observed and marked degraded. Feeds W1-03's frozen-skip as
promised.
