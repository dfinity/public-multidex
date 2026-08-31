# W4-13 — `performWorldWipe` clears a single-flight flag it does not own

**Issue:** [#25](https://github.com/dfinity/public-multidex/issues/25) item 4 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` LOW–MEDIUM / `#production` N/A (reset refuses on `#production`)
**Effort:** M

## What's wrong

`tickPriceRefresh` owns `_priceRefreshInFlight`: it checks it, sets it, and clears it in a `finally`.
`performWorldWipe` **also clears it** — while a refresh may be parked mid-fan-out across the
oracle's parallel outcalls. The next tick's single-flight check then passes and two refreshes run
concurrently, which is the precondition for the stale-overwrite class in
[W3-06](W3-06-confirmation-gate-sample-time.md).

The sibling path in the same file does this correctly and is worth copying rather than reinventing:
the ship path uses an **epoch bump** (`_captureEpoch`), so in-flight work discovers it belongs to a
dead epoch and abandons itself, instead of another owner reaching in and clearing its flag.

## Evidence

- `src/backend/main.mo:14613` — `performWorldWipe` clears `_priceRefreshInFlight`
- `:14023-14024` — `tickPriceRefresh` checks and sets it; `:14061` — clears it in `finally`
- `:13879-13935` — `refreshMultiSourcePrice`, no epoch guard
- no oracle epoch variable exists (`_captureEpoch` is archive-only and unread by the oracle path)

## Fix

Bump an **oracle epoch** in the wipe, and have `refreshMultiSourcePrice` discard a result whose
epoch no longer matches — rather than clearing another function's flag. Mirror `_captureEpoch`.

## Done when

- [x] A wipe during an in-flight refresh cannot produce two concurrent refreshes
- [x] The in-flight refresh abandons itself on epoch mismatch rather than writing a result
- [x] `_priceRefreshInFlight` has exactly one writer
- [x] A test wipes mid-refresh and asserts the stale result is discarded

## Completed 2026-08-15 (W4 batch 3)

`performWorldWipe` bumps a transient `_oracleEpoch` instead of clearing `tickPriceRefresh`'s flag;
the refresh captures the epoch before its fan-out and abandons the result (before applying) when
it moved, clearing its own flag in its own `finally` — the `_captureEpoch` shape. The flag now has
exactly one clearing writer, pinned in hygiene §6j (count == 1) along with the epoch pair; the
wipe-mid-refresh race itself is timing a test cannot stage deterministically.
