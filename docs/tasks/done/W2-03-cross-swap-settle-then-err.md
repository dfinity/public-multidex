# W2-03 — `executeSwapCross` settles the sell leg, returns `#err`, and skips the fill-capture hooks

**Issue:** [#13](https://github.com/dfinity/public-multidex/issues/13) item 1 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` MEDIUM / `#production` HIGH
**Effort:** M

## What's wrong

The cross-token swap settles the sell leg — a real balance mutation — and then returns `#err` from
two points below that settlement, with **no rollback**. Every fill-capture hook sits under those
returns.

Two distinct harms:

1. **The caller is told the swap failed while holding the proceeds.** A client that retries on
   `#err` double-sells. The `#err` contract is "nothing happened"; here something did.
2. **The settled fills never reach the hash-chained archive.** `refreshRolling24h` is the sole call
   site of `emitFillEvents`, and it sits below the returns — so real fills are permanently absent
   from the tape. Under the transparency doctrine that is a correctness defect in the public
   record, not a cosmetic gap.

## Evidence

`src/backend/main.mo`, `func executeSwapCross` at `:11596`:

- `:11609` — sell leg settles via `MatchingEngine.executeMarketOrderProtected` (balances mutate)
- `:11618` — reads back the credited ICPUSD
- `:11621` — `return #err("No liquidity on " # buyMarket)` ← **below the settlement, no rollback**
- `:11624` — `return #err("Invalid price")` ← same
- `:11629-11636` — `updateStatsAfterTrades`, `refreshRolling24h` (×2), `adjustAffectedUsers`
  ← **below both returns**

## Fix

Two shapes, pick one:

- **Preferred — make the failure representable.** On the two post-settlement failure paths, run the
  sell-leg hooks and return a success variant that reports partial execution
  (`#ok { fullyFilled = false; … }`), so the caller learns what actually happened and the tape gets
  its fills.
- **Alternative — settle nothing until the last failure point.** Restructure so the buy leg's
  liquidity and price are resolved *before* the sell leg commits. Cleaner contract, larger change.

Do **not** simply move the hooks above the returns without deciding what the caller is told — the
double-sell risk lives in the return value, not in the hooks.

## Done when

- [x] No path can return `#err` after the sell leg has settled
- [x] Every settled fill reaches `emitFillEvents` / the archive, including on the failure paths
- [x] A test drives "sell settles, buy market has no liquidity" and asserts both the return shape
      and the presence of the fills on the tape
- [x] Retry semantics documented for the partial case

## Completed 2026-08-15

- Took the task's ALTERNATIVE shape, which turned out to be the small one here: both post-settlement
  refusals depend only on the buy market's book, which nothing in the sell leg can touch inside a
  single message — so the buy ask is resolved (existence + non-zero price) BEFORE the sell commits.
  `#err` is literal again: nothing settled, safe to retry verbatim. No `#err` return exists below
  the settlement any more, so the fill hooks (incl. the sole `emitFillEvents` call site) run on
  every settled path by construction. Retry semantics documented at the `#ok` return: it is a
  settlement report — `fullyFilled=false` means real partial movement; retry from balances with a
  NEW swap, never by resubmitting.
- The staged-release path (`releaseCrossSwap`) was checked for the same class and is already safe —
  it sizes leg 1 to leg 2's absorbable capacity before selling.
- New `tests/test_cross_swap_atomic.sh` (8 green): buy book empty → `#err` naming the market with
  the seller's balance BYTE-IDENTICAL (the regression pin — pre-fix the sell settled first); thin
  buy ask → honest `#ok` partial with `fromAmount>0`, `fullyFilled=false`, balances moved, and the
  sell fill present in the event journal. Regressions: cross_swap 4/0, swap_outcome 5/0,
  cross_swap_sizing 4/0.
