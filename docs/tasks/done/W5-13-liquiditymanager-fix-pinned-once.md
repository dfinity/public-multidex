# W5-13 — The Nat-underflow fix exists at three sites and is pinned at one

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 4 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** S

## What's wrong

The 2026-07-09 fix — replacing a subtracting `excess -= orderValue` with `excess := 0` in the
below-minimum cancel branch — exists at **three** sites in `src/backend/lib/LiquidityManager.mo`.

Reverting one turns `mops test` red. Reverting **either of the other two** leaves all 15 files green,
and neither surviving mutant is equivalent — so two thirds of the fix is unguarded, and a future
refactor can undo it silently.

Same shape as the fix-applied-to-one-of-N pattern in [W5-18](W5-18-m0155-ratchet-scope.md), different
subsystem; this one is a **test** gap rather than a gate gap.

## Evidence

- `src/backend/lib/LiquidityManager.mo` — three occurrences of the `excess := 0` below-minimum branch
- Mutation result: site 1 → red; sites 2 and 3 → green, non-equivalent

## Fix

Add assertions covering the other two sites, driving each branch's below-minimum condition
specifically. Verify by mutation: revert each site in turn and confirm the suite goes red for all
three.

## Done when

- [ ] Reverting any one of the three sites turns `mops test` red
- [ ] Each assertion names which site it guards

---
## Done — 2026-08-15

Two new fixtures in LiquidityManager.test.mo drive the previously-unguarded
copies, each named for its site:

- **adjustSellOrders (~:428):** balance 1.0 BTC (qty cap 2.5×), sells
  1.0+1.0+0.41+0.30 = 2.71 → excess 0.21; newest 0.30 > excess, post-shrink
  0.09 @ $100 = $9 < $10 → whole-cancel + `excess := 0`.
- **enforceCrossMarketBidCap (~:231):** the geometry here is that the
  below-min branch fires only when the SURVIVORS land within $10 of the
  3.0×cash maxGross (the shrink fills exactly to cap; first attempt with two
  markets could never get closer than $55 — the residual equals cap minus
  survivors). Three markets: $245 + $47 survive = $292 vs $300 cap → room
  $8. Walk: $92 clean-cancel, then $95 post-shrink $8 < $10 → whole-cancel
  + `excess := 0`.

The pre-existing fixture (renamed to say so) covers adjustBuyOrders' step-2
walk. Mutation-verified: reverting `excess := 0` → `excess -= …` at EACH of
the three sites in turn makes `mops test LiquidityManager` red (Nat
underflow trap in the fixture's branch); restored tree green.
