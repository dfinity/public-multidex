# W4-09 — `adminReplayStep` has no single-flight guard, so a double-click fakes a reserve alarm

**Issue:** [#26](https://github.com/dfinity/public-multidex/issues/26) item 5 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` MEDIUM
**Effort:** S

## What's wrong

`adminReplayStep` is the executable proof-of-reserves audit: it folds the archived tape forward and
compares the result against live balances. `_replayCursor` is read **before** the await and advanced
only in the continuation, and there is no in-flight guard.

Two overlapping controller calls — a double-click on an ops page, or a retry after a slow reply —
both read the same cursor, both fold the same page, and the tape is double-counted. The output is a
**false reserve alarm on a healthy venue**, which is the worst possible failure mode for an
integrity check: it burns operator trust in the one mechanism meant to detect real divergence.

Controller-only, which is why it is not higher — but the harm is to the credibility of the audit
tool, not to funds.

## Evidence

- `src/backend/main.mo:7891` — `adminReplayStep`; no `_replayInFlight` exists anywhere
- `:7903` — loop condition reads `_replayCursor`; `:7904` — `archiveForSeq(_replayCursor)`
- `:7917` — `await a.getEventsRange`
- `:7950` — cursor advanced, in the continuation only
- `:7608` / `:7814-7816` — `tickShipEvents`' correct guard-and-`finally` pattern to copy

## Fix

Guard with a flag set **before** the first await and cleared in a `finally`, exactly as
`tickShipEvents` does — that is the repository's one `finally` and it earns it. Additionally, either
advance the cursor optimistically and roll it back on the error arm, or carry the expected cursor
into the response so a stale fold is detectable by the caller.

## Done when

- [x] Two concurrent `adminReplayStep` calls cannot both fold the same page
- [x] The guard clears on the error path (hence `finally`, not a bare assignment)
- [x] A test issues overlapping calls and asserts the fold total is not double-counted

## Completed 2026-08-15 (W4 batch 2)

`_replayInFlight` set before the first await, cleared in `finally` (the tickShipEvents pattern);
an overlapping call returns the current cursor snapshot and logs a warn naming the refusal.
`test_w4_batch2.sh` §1 fires two overlapping steps, drives the fold to done, and asserts ZERO
mismatches — the pre-fix false reserve alarm cannot happen.
