# W4-16 — An archive spawn is unrecorded across its own await, and the cleanup swallows the principal

**Issue:** [#26](https://github.com/dfinity/public-multidex/issues/26) item 4 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` LOW
**Effort:** M

## What's wrong

Two related lifecycle leaks at the same three spawn sites.

**(a) Unrecorded spawn.** `archive0 := ?fresh` / `_archiveNext := ?fresh` happen only in the
*continuation* of `await Archive.Archive(...)`. The canister exists the moment the call returns; the
record of it exists only if the continuation runs. An upgrade landing in that window leaks a
3T-cycle canister that main controls but can no longer fund (`allArchivePrincipals` never learns of
it), list, or delete.

**(b) Swallowed cleanup.** When a reset races a spawn, the epoch guard destroys the orphan with
`try { await ic00.stop_canister(…); await ic00.delete_canister(…) } catch (_) {}`. A bare swallow: if
either call fails, the principal — which exists only in that continuation — is lost with no trace
on-chain and no log line.

Related but distinct from #2 item 3 (Menese), which is about the *settings* the child is created
with (memory limit, threshold, `lowmemory()`). Applying memory settings at creation still leaks the
canister; persisting the principal before the await still ships a 3 GiB/threshold-0 archive. Both
fixes are wanted.

## Evidence

- `src/backend/main.mo:7496` → `:7507`/`:7512` — `emergencyRollArchive`: await, then assign
- `:7655-7656` → `:7673` — `tickShipEvents` initial spawn
- `:7748` → `:7757` — successor spawn
- `:7504`, `:7667-7670`, `:7751-7754` — the three bare `catch (_) {}` cleanups
- no `_pendingSpawn` exists anywhere

## Fix

- Write the intended principal to a `_pendingSpawn` field **before** the await — under enhanced
  orthogonal persistence a plain `var` is already stable, so this is a small change — and have a
  heartbeat subtask reconcile it (adopt it, or stop-and-delete it).
- Replace each bare `catch (_) {}` with a log line **carrying the principal**, so an operator can
  recover by hand even when the automated cleanup fails.

## Done when

- [x] A spawn interrupted by an upgrade leaves a reconcilable record
- [x] A failed epoch-race cleanup logs the principal
- [x] The reconciler is idempotent and cannot adopt someone else's canister
- [x] A test drives spawn-then-lost-continuation and asserts the principal is recoverable

## Completed 2026-08-15 (W4 batch 3)

Spawns are TWO-STEP (`spawnArchive`): `create_canister` first, the principal recorded in stable
`_pendingSpawn` the moment the create replies — before the install await — then the actor-class
`#install`. All three sites use the helper (hygiene §6j pins that no one-shot spawn remains). A
heartbeat reconciler (60s, isolated) stops-and-deletes a recorded orphan older than 5 minutes —
idempotent, and it can only ever touch principals it recorded itself. The three epoch-race
cleanups log the principal on failure instead of swallowing it. The upgrade-mid-await scenario
itself cannot be staged deterministically from a test; the structure is pinned and the reconciler
path is exercised by inspection (`_pendingSpawn` null in steady state).
