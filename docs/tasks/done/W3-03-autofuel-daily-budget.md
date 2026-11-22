# W3-03 — The auto-fuel trigger extrapolates burn with no clamp and no absolute ICP budget

**Issue:** [#23](https://github.com/dfinity/public-multidex/issues/23) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` INFO / `#production` MEDIUM
**Effort:** M

## What's wrong

The trigger fires when
`Cycles.balance() <= _freezingLimitCycles + max(AUTO_FUEL_HEADROOM_MIN, _burnPerDay)`, and
`_burnPerDay` is derived by extrapolating an observed short-window burn across a day. There is a
7:3 EMA smoother, which is **not** a clamp, and there is no absolute ceiling on ICP spent per day —
only `AUTO_FUEL_ICP_TRANCHE` (100 ICP) per action and a 10-minute cooldown.

The consequence is a coupling that is not obvious from either side: **any cycle-drain primitive
becomes a treasury-ICP drain.** The uncapped cross-caller cycle burn (#5.5) and caller-controlled
per-call cost (#5.2) both price their damage in cycles and availability; through this trigger they
also price it in ICP. A sustained artificial burn raises `_burnPerDay`, which raises the floor,
which keeps the loop armed.

Deliberately conservative on severity: the ICP is converted at the CMC's XDR rate, so this is a
**forced conversion on an attacker's schedule**, not a loss of value — and on a healthy venue the
burn sample reflects real load. It matters because it is the mechanism that turns a cycle-cost
finding into a treasury finding, and because combined with
[W3-02](W3-02-autofuel-ambiguous-reject.md) the same trigger is what keeps re-entering.

## Evidence

- `src/backend/main.mo:10969` — the floor: `Nat.max(AUTO_FUEL_HEADROOM_MIN, _burnPerDay)`
- `:6573` — `closeBurnWindow`, EMA blend (`perDay * 3/10`) — a smoother, not a clamp
- `:10952-10953` — cooldown and tranche are the only limits
- no daily ICP budget variable exists

## Fix

- clamp the extrapolation to a configured multiple of the **trailing median** rather than a single
  window
- add an **absolute per-day ICP budget** alongside the per-action tranche, with the trip logged
- `_fuelCooldownUntil` is already stable and deliberately so — a daily budget belongs in the same
  place

## Done when

- [x] A single anomalous burn window cannot move the floor by more than the configured multiple
- [x] A day's ICP spend is hard-capped regardless of trigger frequency
- [x] The budget trip emits an event (today the analogous arb trip returns before any log)
- [x] Interaction with [W3-02](W3-02-autofuel-ambiguous-reject.md)'s interlock is covered by a test

## Completed 2026-08-15 — landed with W3-02 as one change

- `clampBurnSample` in `closeBurnWindow`: one window's extrapolation is clamped to ≤ 4× the
  trailing median (ring of the last 5 samples, stable) BEFORE the 7:3 EMA; the ring stores the
  CLAMPED value so repeated attack windows cannot ratchet the median faster than the clamp allows.
  Sustained real load still moves it, as it should.
- `AUTO_FUEL_ICP_DAILY_MAX` (500 ICP/day) enforced in `tickAutoFuel` before each tranche, with the
  trip LOGGED; stable `_fuelSpentTodayE8s`/`_fuelDayStartNs` roll daily and count every stage-2
  debit that stuck (ambiguous keeps count; clean rejects do not) — manual break-glass burns count
  for observability but are not capped. Counters exposed in `getFuelStatus`.
- W3-02 interaction covered by `test_autofuel_guards.sh` (the counter tracks the kept ambiguous
  debit; the interlock gates the trigger); the clamp + budget guard are pinned structurally in
  hygiene §6d (driving real burn windows deterministically is not something a local test can do).
