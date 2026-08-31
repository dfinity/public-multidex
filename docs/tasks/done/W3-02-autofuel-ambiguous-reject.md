# W3-02 — The self-funding loop re-enters after an ambiguous ledger reject

**Issue:** [#23](https://github.com/dfinity/public-multidex/issues/23) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` INFO (mock ledger, play money) / `#production` HIGH
**Effort:** S — **the reporter supplies a compile-tested patch**

## The invariant

However many times a stage-2 transfer ends ambiguously, the treasury must not spend a second
tranche until the first is reconciled.

## What holds it

Nothing. `_fuelPendingNotify` is the only interlock in the saga, and the catch path deliberately
does **not** set it — correctly, because on an ambiguous failure the transfer may or may not have
landed and arming the notify slot would assert a block index the canister does not have. But
nothing else is armed either: no journal, no attempt record, and `created_at_time` is `null` on the
transfer, so the ledger's own dedup window is not engaged.

Sequence: the trigger fires when headroom is low → `fuelStage2` debits up to
`AUTO_FUEL_ICP_TRANCHE` (100 ICP) and yields → the call is rejected (no attacker needed: the NNS
subnet is unavailable, or this canister cannot reserve the outgoing call while sitting just above
its freezing limit — *exactly the condition the trigger selects for*) → the debit is **kept**,
deliberately and with a written rationale (re-crediting a transfer that **did** land would inflate
the internal claim past its chain backing, which is the insolvent direction — that reasoning is
right) → 600 s later the cooldown expires, headroom is still low, the interlock is still null, and
another tranche is debited.

**Not a double-spend** — each window's transfer carries its own intent, and any ICP that reaches the
CMC subaccount is genuinely converted. The defect is the **unbounded re-entry** and the absence of
any record that would let an operator reconcile afterwards.

## Evidence

- `src/backend/main.mo:10878-10889` — the catch: keeps the debit, writes one log line, arms nothing
- `:10867` — `created_at_time` still `null`
- `:10963` `tickAutoFuel`; `:10971` — cooldown armed; `:10952-10953` — 10-minute cooldown, 100-ICP tranche
- `Error.isCleanReject` / `Error.code` / `_fuelAmbiguous` appear **nowhere** in `src/`
  (18 uses of `Error.message`, zero of `Error.code`)

## Fix

Classify the failure instead of collapsing it. The pinned stdlib already ships the predicate
(`mo:core/Error` `isCleanReject`, and `mops.toml` pins `core = "2.5.0"`):

```motoko
} catch (e) {
  if (Error.isCleanReject(e)) {
    // Library guarantee: no state change on the callee side — provably not sent.
    Accounts.addBalance(accounts, treasury, "ICP", icpE8s);
    return #err("ledger transfer not sent: " # Error.message(e));
  };
  // Genuinely ambiguous: the transfer MAY have landed. Keep the debit and BLOCK re-entry.
  _fuelAmbiguous := ?{ icpE8s; atNs = Time.now(); msg = Error.message(e) };
  return #err("ledger transport, ambiguous — reconcile on-ledger: " # Error.message(e));
};
```

`fuelStage2` then refuses while `_fuelAmbiguous != null`, exactly as it already refuses while
`_fuelPendingNotify != null`, plus an operator lever to clear it after off-chain reconciliation.

**Direction of the guarantee, easy to invert:** `isCleanReject == true` ⟹ safe to re-credit.
`false` does **not** mean it landed — it means you may not assume it did not. Keeping the debit
*and* blocking re-entry is the conservative branch.

## Done when

- [x] A clean reject re-credits the debit and leaves no interlock
- [x] An ambiguous reject keeps the debit, arms `_fuelAmbiguous`, and blocks the next window
- [x] An operator endpoint clears the interlock after reconciliation, and logs who/when
- [x] Consider `created_at_time` on the transfer so the ledger's dedup window also helps — done

## Completed 2026-08-15 — landed with W3-03 as one change

- The reporter's remedy taken as supplied (per the Notes warning): `Error.isCleanReject`
  classification in the stage-2 catch — clean rejects re-credit (library guarantee: callee saw
  nothing), everything else keeps the debit, arms stable `_fuelAmbiguous`, and both `fuelStage2`
  (manual entry) and `tickAutoFuel` (the re-entering trigger) refuse while it is armed.
  `created_at_time` is stamped so the ledger's own dedup window engages.
- `adminClearFuelAmbiguous` (controller): logs who cleared and what was pending; refuses when
  nothing is recorded. `getFuelStatus` exposes the interlock + the daily counters.
- `tests/test_autofuel_guards.sh` (11 green on #dev): clean reject via a nonexistent ledger
  (destination_invalid) → byte-identical re-credit, no interlock; ambiguous via a new fuel-mock
  `setTrapTransfers` hook (canister_error = the not-clean class) → debit kept, interlock visible,
  second spend refused, operator clear re-enables, healthy burn completes. Hygiene §6d pins the
  structural properties. `test_fuel_topup` 17/0.

## Notes

The reporter type-checked the snippet with this repository's own toolchain and flags, and validated
the harness against a known-positive first. Take the suggested remedy seriously rather than
improvising a cleverer one — §6 of the 1.60 triage records a regression caused by exactly that.
