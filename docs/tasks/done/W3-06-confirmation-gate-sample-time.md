# W3-06 — The jump breaker judges independence on arrival clocks, and its candidate never ages

**Issues:** [#27](https://github.com/dfinity/public-multidex/issues/27) item 3 (OhShii Labs) ·
[#17](https://github.com/dfinity/public-multidex/issues/17) item 2 (andreij6)
**Status:** #27.3 **PARTIAL** (half landed) · #17.2 **LIVE** — verified at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** M

Two findings from two reporters in the same function; one fix pass.

## Part A — independence measures transport, not the market (#27.3, partial)

**What landed:** `applyFreshAggregate` now rejects any aggregate whose timestamp is at or before the
current mark's — "stale aggregate: sampled at or before the current mark". That closes the
stale-overwrite case.

**What did not:** the independence gate itself is unchanged. `acceptOrPendPrice` still compares
`now - pending.firstSeenNs` against the confirmation gap, where both are **continuation clocks**. The
oracle fires its outcalls in parallel and responses return in an order the canister does not
control, so an observation drawn from an *older* sample can arrive later and be treated as the
independent confirmation of a newer jump.

Two honest caveats:

- `PriceFeed.Reading.fetchedAtNs` — the genuine per-sample field — is written at four sites and
  **read nowhere** in the backend. The data the fix needs is already collected and thrown away.
- The new guard's comment claims monotonicity in *sample* time, but `agg.timestamp` is itself
  stamped `Time.now()` in the refresh continuation, so it is really monotonic in
  *aggregate-completion* time. **The comment overstates what the code does and should be corrected
  as part of this task.**

## Part B — the confirmation candidate never ages (#17.2, livelock)

The "doesn't confirm — replace pending" branch unconditionally rewrites `firstSeenNs = now`. The
too-soon-confirm branch deliberately preserves the clock, but the >50 bps replacement resets it. So
during a sustained fast move the candidate is replaced faster than the confirmation gap elapses and
**never ages to the 30 s gate** — the breaker never confirms, and the mark stays frozen exactly when
it is moving.

## Evidence

- `src/backend/main.mo:13629` — `acceptOrPendPrice`, `now - pending.firstSeenNs` on continuation clocks
- `:13646-13651` — the replacement branch, unconditional `firstSeenNs = now`
- `:13827-13829` — `applyFreshAggregate`'s landed stale-overwrite guard (and its overstated comment)
- `src/backend/lib/PriceFeed.mo:66` — `fetchedAtNs` declared; written ×4 in `main.mo`, read nowhere
- `:380` / `main.mo:13904` — `agg.timestamp` stamped at aggregation

## Fix

1. Judge independence on the **stored per-sample times** (`fetchedAtNs`), not on arrival.
2. Discard any reading whose sample time predates the last accepted one (the second clause of the
   reporter's original fix direction).
3. Preserve the original `firstSeenNs` on a **same-direction** replacement so a candidate can age;
   reset only on a direction change.
4. Correct the `applyFreshAggregate` comment to say completion time, or make it true.

## Done when

- [x] Two samples 30 s apart in *sample* time confirm; two samples that merely *arrived* 30 s apart do not
- [x] A sustained >1 %/min move confirms rather than livelocking
- [x] `fetchedAtNs` has a reader
- [x] No comment claims a guarantee the code does not provide

## Completed 2026-08-15 — landed with W3-07 as one oracle pass

- `aggSampleNs(agg)` — the oldest `fetchedAtNs` among the readings that entered the sample —
  computed in main.mo rather than stored on the Aggregate (`lastAggregates` persists Aggregate
  values; extending the type was tried and correctly refused by the RTS as a stable-layout change).
  `fetchedAtNs` now has its reader.
- `applyFreshAggregate`'s monotonic guard and both mark stamps use the SAMPLE clock — the guard's
  comment now says what the code does because the code now does what the comment said. The breaker
  (`acceptOrPendPrice`) takes `sampleNs` (aggregate sample / anchor effective time) and ages the
  candidate on it.
- Part B: a >50 bps candidate replacement keeps `firstSeenNs` when the move direction (vs the
  standing mark) is unchanged, and resets only on a flip — a sustained move now ages to the gate
  and confirms.
- `setTestPendingJump`/`setTestXrcRate` gained a trailing `opt ageSecs` (backdating) so the gap is
  testable without wall-clock sleeps; every existing 2-arg call site was migrated (the icp CLI
  enforces arity against the fresh did).
- `tests/test_oracle_time_bases.sh` §3 pins both directions of the livelock fix, driven
  deterministically through the XRC-fallback route (`setTestMinSources` + `setTestXrcRate`).
  Regressions: xrc_fallback 13/0, breaker_widening 7/0, fallback_band, amm_staleness,
  margin_staleness, sealed_model, margin_collateral_escape 11/0, position_accounting.
