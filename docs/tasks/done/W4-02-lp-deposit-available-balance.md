# W4-02 — `performLpDeposit` gates on the raw balance, so it spends what a staged order reserved

**Issue:** [#16](https://github.com/dfinity/public-multidex/issues/16) Finding 27 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW–MEDIUM / `#production` MEDIUM
**Effort:** S

## What's wrong

The LP deposit path gates on `Accounts.getBalance` (the **raw** balance) rather than
`getAvailable` (balance − reserved), and then debits against the raw balance too. A depositor with
funds soft-locked by a staged order can therefore spend those reserves into the vault.

The staged order is then **defunded**: it under-fills or is killed at release, and the failure is
reported as a liquidity problem rather than as the accounting error it is. There is no cross-user
theft — the vault receives full value — but the user's own reservation is silently violated.

The sibling paths all get this right: `fundMarginPool`, `stakeInsurance` and `withdraw` all use the
available balance. `gateInitialMargin` does not help here — it is inert for a zero-debt LP.

## Evidence

- `src/backend/main.mo:12187`, `:12191` — the two gates, on `Accounts.getBalance`
- `:12243`, `:12249` — the debits, via `subtractBalance` against raw
- `:1146` — `getAvailable` (balance − reserved), the correct reader
- no `getAvailable` call anywhere in the function

## Fix

Gate **and** debit both legs on `getAvailable(depositor, token)`.

## Done when

- [x] A deposit that would consume reserved funds is refused with a clear message
- [x] A staged order survives an LP deposit made from the same account
- [x] A test stages an order, attempts an LP deposit of the full raw balance, and asserts the refusal

## Completed 2026-08-15 (W4 batch 1)

Both `performLpDeposit` gates read `getAvailable` (balance − reserved) like the three sibling
paths; the debit amounts are thereby available-bounded, so a staged order's reserve can no longer
be spent into the vault. `test_w4_correctness_batch.sh` §2: full-raw-balance deposit refused with
"Insufficient available", staged order intact.
