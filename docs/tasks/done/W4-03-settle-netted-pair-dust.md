# W4-03 — `settleNettedPair`'s dust path forgives debt against a rejected write-off

**Issue:** [#15](https://github.com/dfinity/public-multidex/issues/15) item 2 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` LOW / `#production` LOW
**Effort:** S

## What's wrong

When the netted cash value floors to zero, three things happen in sequence and none of them agree:

1. `cash = Fixed.mul(q, mid, false)` floors to **0** (only `q` is guarded, not `cash`)
2. `writeOffLoan(seller, cash = 0)` is **rejected** by `BorrowEngine` — and the result is `ignore`d,
   so the seller loses `q` base for no debt relief
3. `subtractBalance(buyer, 0)` returns `true`, so the rollback that would undo step 1 never fires
4. the buyer's base debt is forgiven by `q` anyway

The caller gates all its bookkeeping on `cash > 0`, so the dust case takes the else branch and
**records nothing** — an unrecorded balance-and-loan mutation, with `poolPositions` drift and no
version bump.

Magnitude is genuinely dust (`cash == 0` implies the base moved is worth less than one ICPUSD unit),
which is why this is LOW. It corrects a clearance in the 1.60 triage's §2, which cleared this
function.

## Evidence

- `src/backend/lib/Liquidator.mo:388` — the `q` guard (present)
- `:389` — `cash = Fixed.mul(q, mid, false)`, floors to 0, **unguarded**
- `:393` — `writeOffLoan(seller, cash)` rejected and `ignore`d
- `:395` — `subtractBalance(buyer, 0)` returns `true`, so no rollback
- `:402` — buyer base debt forgiven by `q`
- `src/backend/main.mo:3672`, `:3689` — caller gates bookkeeping on `cash > 0`

## Fix

Guard `cash == 0` before the mutations and return the zero result, mirroring the existing `q == 0`
guard immediately above.

## Done when

- [x] `cash == 0` performs no balance or loan mutation
- [x] A test drives a sub-unit netted pair and asserts balances and loans are unchanged
- [x] The 1.60 triage's §2 clearance of `settleNettedPair` is corrected — see [W6-01](W6-01-refresh-triage-document.md)

## Completed 2026-08-15 (W4 batch 1)

`if (cash == 0) { return zero }` mirrors the `q` guard immediately above, before any mutation.
Driving a sub-unit netted pair deterministically through a live liquidation is not stageable from
an integration test; the guard is pinned structurally (hygiene §6i, both guards asserted on the
extracted function body). Triage §2 correction deferred to W6-01 as the task planned.
