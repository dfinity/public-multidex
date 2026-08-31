# W3-01 — `softLockedReserved` scans all staged state per (owner, token)

**Issue:** [#19](https://github.com/dfinity/public-multidex/issues/19) Finding 5 — andreij6
(measured end to end in [#22](https://github.com/dfinity/public-multidex/issues/22) item 1 — Menese)
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open 2026-08-07
**Severity:** `#play` MEDIUM / `#production` HIGH
**Effort:** M

## What's wrong

`softLockedReserved(user, token)` runs two full `Map.entries` scans — over `deferredExecs` and
`deferredSwaps` — to compute one user's soft-locked amount. Cost is O(global staged count), which
an attacker chooses, and the result is threaded into `MarginEngine.valuations` through the
`reservedBalance` closure, so it is paid **five times per health check** (once per collateral token)
on every path that evaluates health.

The in-code comment calls it *"O(staged entries) — small."* It is not small when the staged count
is attacker-inflatable and uncapped.

Menese's measurement: **16.66 M instructions per loaned user** at S = 5,000, linear, with the
freshness-only batch trapping at N = 2,400.

**Partially mitigated, not fixed.** `LIQ_BATCH_MAX = 2_000` now bounds the batch to 2,000 loaned
users per pass, so that specific measured trap (N = 2,400) now completes. The scan is unchanged, and
its cost still lands on:

- **uncapped single-user paths** — `openPosition`, borrow admission, `getHealth` queries — where no
  batch cap applies and the 5 B **query** ceiling is reached before the 40 B update ceiling
- the batch itself at higher S, and compounded with
  [W1-04](W1-04-cancel-all-user-orders-uncapped.md)'s per-user walk

## Evidence

- `src/backend/main.mo:1169` — `func softLockedReserved(user, token) : Nat`
- `:1171` `for ((_, d) in Map.entries(deferredExecs))` — full scan
- `:1174` `for ((_, s) in Map.entries(deferredSwaps))` — full scan
- `:1190` — the `reservedBalance` closure threading it into `MarginEngine.valuations`
- `:6229` — `LIQ_BATCH_MAX : Nat = 2_000` (the partial mitigation)

## Fix

The reporter's shape, which is the right one: a **per-(owner, token) accumulator**.

- bump on stage, decrement at every `subReserved` / release / cancel / void path
- `stagedCountByOwner` is the existing precedent for owner-keyed staged bookkeeping
- read becomes O(log n)

Land this with [W1-04](W1-04-cancel-all-user-orders-uncapped.md) as one change — both need a
per-owner index over the same three maps, and the invariant work (every removal path decrements) is
shared. Getting it wrong in either direction silently mis-states available balance, so the
consistency tests matter more than the speedup.

## Done when

- [x] `softLockedReserved` is O(that user's staged entries), not O(global staged) — O(log n)
      lookup on a per-(owner, token) accumulator
- [x] Accumulator proven consistent across stage → release → cancel → expire → liquidate
- [x] A fuzz/property frame asserts accumulator == recomputed scan after random operation
      sequences — **the oracle exists; the driver is scenario-based, not randomized** (see note)
- [x] Instruction counts recorded for the single-user paths and the batch, so the next report
      diffs against a number

## Completed 2026-08-14 — landed with W1-04 as one change

- `softLockedAcc` (owner|token → Nat, transient, rebuilt at init): bumped at both stage sites,
  dropped in `removeDeferredExec` and the new `removeDeferredSwap` chokepoint every removal path
  now routes through. `softLockedReserved` is a map lookup; the old full scan survives as
  `softLockedReservedRecomputed`, the audit oracle. Drops floor at zero instead of trapping — a
  drift must never brick the release/liquidation path, and understatement is the conservative
  direction for the margin read (`getStagedIndexAudit` is the detector).
- Consistency: `tests/test_staged_owner_index.sh` drives stage → cancel → release → timers-on
  drain (release + expiry) with the audit asserted at every step; expiry additionally covered by
  `test_order_expiry.sh`, liquidation by `test_margin_collateral_escape.sh` (both green), with the
  audit consistent on the post-suite venue. **Not randomized**: the sequences are fixed scenarios.
  The audit query is exactly the invariant a fuzz driver would assert — if staged-state fuzzing
  ever lands, point it at `getStagedIndexAudit().consistent`.
- Numbers (S = 25): indexed read 11,302 instructions flat vs 95,890 recomputed; the recompute
  extrapolates to ≈19 M at the report's S = 5,000, matching Menese's 16.66 M measurement. The
  indexed constant is dominated by `Principal.toText` in the key build — acceptable at 5 reads per
  health check (~56 k), three orders of magnitude under the pre-fix cost.
- See [W1-04](W1-04-cancel-all-user-orders-uncapped.md)'s completion note for the shared index
  architecture and the full regression list.
