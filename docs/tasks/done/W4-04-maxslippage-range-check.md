# W4-04 — `swap()` / `quoteSwap()` never range-check `maxSlippage`

**Issue:** [#13](https://github.com/dfinity/public-multidex/issues/13) item 3 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` LOW / `#production` LOW
**Effort:** S

## What's wrong

`swap()` validates amount, token, balance, notional and margin — but never `maxSlippage`. Both it
and `quoteSwap()` then compute `Fixed.SCALE - slip` unguarded, which **Nat-underflows and traps**
for a sell leg above 1e8.

A trap rolls back, so there is no state damage — but the caller gets an opaque canister trap instead
of the structured `#err` that **four sibling endpoints already return**, and `quoteSwap` is the
read-only preview the UI calls, so a bad input breaks the quote path rather than returning a
message.

## Evidence

- `src/backend/main.mo:11465` — `swap()`, no `maxSlippage` validation
- `:11412` — `quoteSwap()`, unguarded `Fixed.SCALE - slip`
- `:11568` — `executeSwapDirect`, same shape
- `:9813`, `:9990`, `:10080`, `:11282` — the four siblings that **do** range-check and return `#err`

## Fix

Add the sibling guard at the top of `swap()` and clamp/validate `slip` in `quoteSwap()`:

```motoko
if (maxSlippage < 1_000_000 or maxSlippage > 25_000_000) { return #err("maxSlippage out of range") };
```

Use whatever bounds the four siblings already use, so the four-plus-two set is consistent.

## Done when

- [x] Out-of-range `maxSlippage` returns `#err`, not a trap, on `swap` and `quoteSwap`
- [x] The bound matches the sibling endpoints
- [x] A test asserts the structured error on both paths

## Completed 2026-08-15 (W4 batch 1)

`swap()` (marketOrder arm) and `quoteSwap()` (non-zero values; 0 keeps meaning "default 5%") apply
the sibling 1%–25% range check and return the sibling `#err("Slippage must be 1%–25%")`.
`test_w4_correctness_batch.sh` §1 asserts the structured error at 900% on both paths.
