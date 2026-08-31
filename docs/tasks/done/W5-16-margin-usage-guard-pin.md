# W5-16 — The zero-collateral guard on `marginUsage` is unpinned, on a synchronous heartbeat path

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 6 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** S

## What's wrong

`src/backend/lib/MarginPools.mo:120`'s `collateralUsd == 0` guard is pinned by **no Motoko test** —
removing it leaves all 15 files green.

Removing it also converts a divide-by-zero into a **trap on a synchronous heartbeat path**, which is
the class [W3-08](W3-08-heartbeat-subtask-isolation.md) describes: a trap there is not one bad
response, it is permanent maintenance halt until someone notices and upgrades.

So the guard is load-bearing for venue liveness and nothing holds it in place.

## Evidence

- `src/backend/lib/MarginPools.mo:120` — the `collateralUsd == 0` guard
- Mutation: remove it → `mops test` stays green at 15/15
- Reached from the heartbeat via the leaderboard/margin path (see W3-08's inline-subtask list)

## Fix

Add a unit assertion driving `marginUsage` with `collateralUsd == 0` and asserting the guarded
result. Verify by mutation that removing the guard turns the suite red.

Cheap, and worth doing **before** [W3-08](W3-08-heartbeat-subtask-isolation.md) rather than after —
once subtasks are isolated, a trap here becomes quieter and therefore easier to miss.

## Done when

- [ ] Removing the guard turns `mops test` red
- [ ] The assertion names the heartbeat consequence in a comment

---
## Done — 2026-08-15

One fixture in MarginPools.test.mo: `marginUsage(0, debt, maint)` must
return exactly Fixed.SCALE (fully liquidatable) through the explicit guard,
with the comment naming the heartbeat consequence — without the guard this
is a divide-by-zero trap on the synchronous leaderboard/margin pass, i.e.
permanent maintenance halt until an upgrade (the W3-08 class). Landed
before any further heartbeat-isolation work, per the task's ordering note.

Mutation-verified: deleting the `collateralUsd == 0` line turns
`mops test MarginPools` red (the divide traps in the fixture); restored
tree green.
