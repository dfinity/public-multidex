# W3-04 — The Bridge advances its admission counter behind the DEX commit

**Issue:** [#27](https://github.com/dfinity/public-multidex/issues/27) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` MEDIUM / `#production` HIGH
**Effort:** M

## What's wrong

`devSimulateDeposit` admits units by yielding to the DEX and only then advancing `admittedUnits`.
If the continuation is lost — an upgrade landing in the await window, which the file's own note
calls *"the routine act of deploying"* — the counter stays at its old value, `l.pending` is never
credited, and `postupgrade` clears `admitting` so the user can retry.

The retry then computes a **different** seq (nothing pins the retry amount), so the DEX's replay
gate (`if (seq <= existing) { return #ok }`) does not fire, and a second `markValue` is debited from
the lifetime allowance against units already admitted once.

`devSimulateDeposit` is **not** dev-gated — it checks only `requireAuth` and `amount != 0`, and is
the live `#play` on-ramp.

## The root cause is not only the ordering

The two sequence numbers have **opposite semantics**, despite the Bridge comment claiming "the same
discipline":

- **Admit side** — reserves the raw `amount`; the seq is a pure monotone replay token
- **Claim side** — credits `seq − prevSeq`, a slice derived from the DEX's own high-water,
  deliberately, with a written rationale explaining that crediting the raw amount there would
  double-mint

## Evidence

- `src/bridge/main.mo:277-278` — guard and `admitting[k] := true`; `:281` — the yield
- `:289-290`, `:295` — the writes that are lost (`admittedUnits`, `l.pending`)
- `:425-428` — `postupgrade` clears `claiming`/`admitting`, and the comment explicitly **keeps** `admittedUnits`
- `src/backend/main.mo:5683` — the replay gate; `:5699-5701` — debit, reserve, seq write

## Fix

Make the admission counter **write-ahead**: move `Map.add(admittedUnits, …)` up beside the guard,
and roll it back only on the explicit `#err`. This is safe **on the admit side specifically**
because the reserve is amount-based — a *skipped* seq range costs nothing, while a *repeated* one
double-reserves. It also makes the retry reproduce the **same** seq, which is what lets the DEX's
replay gate do its job.

**Do not mirror this onto `claim`.** There the credit is `seq − prevSeq`, so advancing the Bridge's
counter before the DEX confirms would shrink the next slice and lose user funds.

Open caveat the reporter flags and I agree with: write-ahead fixes the allowance double-charge, but
the first deposit's `l.pending` credit is still lost when the continuation dies. Writing both ahead
and rolling both back on the explicit `#err` appears to close that too — and is safe against the
ambiguous-reject case because retrying with the *same* seq is a no-op at the gate — but that
reasoning wants checking by someone who owns the Bridge before it ships.

## Done when

- [x] A deposit whose continuation is destroyed by an upgrade leaves the counter reproducible
- [x] The retry computes the **same** seq and the DEX replay gate absorbs it
- [x] The allowance is debited exactly once across the lost-continuation sequence
- [x] `claim` is demonstrably untouched
- [x] A test drives an upgrade inside the await window — **in its observable equivalent form**
      (see note)

## Completed 2026-08-15

- Write-ahead PAIR per the reporter's caveat, checked and adopted: `admittedUnits` AND `l.pending`
  commit before the yield; both roll back on the DEX's explicit `#err`; both are KEPT on an
  ambiguous transport failure (if the DEX committed, state matches; if it did not, the skipped seq
  range costs nothing and the pending shows without an allowance charge — user-favorable and not
  reachable on demand). `claim()` untouched by design and by diff: its counter is a slice base
  where advancing early loses funds.
- **Interleave the reporter's sketch missed, found while checking it**: `devConfirmDeposits`
  landing inside the await window would confirm the written-ahead pending, stranding the explicit
  rollback (refused units already moved to `confirmed`). It now skips assets whose admission is
  mid-flight.
- **On the upgrade-window test**: with write-ahead, the post-upgrade state after a mid-await
  upgrade is byte-identical to the state after a completed deposit plus `postupgrade` clearing
  `admitting` — there is no distinct lost-continuation state left to reproduce. The test drives
  the equivalent observable: deposit → real bridge upgrade → deposit again, asserting the second
  charge equals the first exactly and pending accumulates exactly (the pre-fix defect showed here
  as a doubled charge).
- `tests/test_bridge_write_ahead.sh` (12 green on #dev): one-deposit-one-charge, upgrade
  reproducibility, over-allowance refusal with used AND pending byte-identical, counter healthy
  after rollback, claim path green. Regressions: bridge_deposit_claim, deposit_ledger_guard.
