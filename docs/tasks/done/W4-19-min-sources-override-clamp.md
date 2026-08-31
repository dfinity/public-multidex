# W4-19 — `_minSourcesOverride` can pin the source floor below the robustness floor

**Source:** 1.60 triage §6 (found during verification, not reported)
**Status:** **LIVE** at `01d2b23` (2026-08-14) — recorded as deferred, never clamped
**Severity:** `#play` LOW / `#production` LOW–MEDIUM
**Effort:** S

## What's wrong

`_minSourcesOverride` sets the minimum number of price sources required, and nothing clamps it
against `PriceFeed.MIN_ROBUST_SOURCES` (3). A value of 1 or 2 defeats the n ≥ 3 guarantee that the
whole MAD-trim rework (the #17.1 fix) exists to provide: below three samples the median has no
breakdown point worth the name, and the trim cannot reject anything.

It is dev-gated and today's only caller **raises** it, so nothing is broken right now. The hook can
still defeat the guarantee, and the guarantee is load-bearing for every mark the venue publishes.

## Evidence

- `src/backend/main.mo:5433` — `_minSourcesOverride := n`, no clamp
- `:13513` — `transient var _minSourcesOverride : ?Nat = null`
- `:13509` — `PRICE_MIN_SOURCES : Nat = PriceFeed.MIN_ROBUST_SOURCES` (= 3)
- `src/backend/lib/PriceFeed.mo:329` — `MIN_ROBUST_SOURCES : Nat = 3`
- `:333` — `isRobustSourceCount(n) = n >= MIN_ROBUST_SOURCES`
- `:217` — the comment explaining why a rejected sample costs against this floor

## Fix

Clamp the setter: `_minSourcesOverride := ?Nat.max(n, PriceFeed.MIN_ROBUST_SOURCES)`, or refuse the
call with an `#err` naming the floor. Refusing is better than silently raising — a caller who asked
for 2 should learn that 2 is not available.

## Done when

- [x] The override cannot lower the effective floor below `MIN_ROBUST_SOURCES`
- [x] An attempt to do so is refused (or clamped) visibly, not silently
- [x] A test asserts the floor holds for an override of 1 and of 2

## Completed 2026-08-15

`setTestMinSources` REFUSES (traps, naming the floor) any value below `PriceFeed.MIN_ROBUST_SOURCES`
— refusal chosen over silent clamping per the task's own reasoning. Floor unoverridable for 1 and 2
by construction; the only remaining values are ≥ the robustness floor.
