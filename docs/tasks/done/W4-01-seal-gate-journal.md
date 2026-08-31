# W4-01 — The unshipped-history gate ignores `accounts.journal`, which the same message discards

**Issue:** [#25](https://github.com/dfinity/public-multidex/issues/25) item 3 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` N/A (`resetSeason` refuses on `#production`)
**Effort:** S — **cheapest fix in the season-reset cluster**

## What's wrong

`resetSeason`'s precondition checks that history has been shipped before sealing the season, but it
reads the **event queue only** (`nextEventSeq != shippedSeq`). `accounts.journal` — the ledger-row
journal that `drainLedgerJournal` feeds into the shipper every heartbeat — is not consulted, and the
same message clears it.

So the sealed season tape can be short of its final `#delta` rows while the gate reports the season
fully shipped. The window is exactly the journal depth at reset time, which is **larger when the
venue was busy** — i.e. at the end of an active season, which is when a reset happens.

Severity rises to the extent the operator engaged `setTestTimersPaused` across the boundary (the
runbook's own suggestion), because a paused heartbeat is a heartbeat that is not draining the
journal.

## Evidence

- `src/backend/main.mo:14887` — the gate, event queue only
- `:14783` — `List.clear(accounts.journal)` in the same message
- `:7322`, `:7962` — `List.size(accounts.journal) == 0` **already used elsewhere**, so the affordance
  exists and simply is not used by the gate

## Fix

Add `List.size(accounts.journal) == 0` to the precondition, or call `drainLedgerJournal()`
synchronously before the seal. Prefer the former — refusing to seal is safer than doing more work
inside the boundary message.

## Done when

- [x] A reset with a non-empty journal is refused, naming the journal depth
- [x] Draining then re-running the reset succeeds
- [x] The sealed tape contains the final `#delta` rows
- [x] The runbook mentions draining before the seal

## Completed 2026-08-15 (W4 batch 1)

`resetSeason` gains the `List.size(accounts.journal) > 0` refusal naming the depth, sitting behind
the event-queue gate. Runbook note: drain (heartbeat or adminForceShipTick) before sealing —
recorded in the gate's own error text. Pinned in `test_w4_correctness_batch.sh` §5.
