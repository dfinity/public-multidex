# W3-10 — Minimum notional and a zero-mint guard on the three fee-free liquidity doors

**Issue:** internal red-team round 2, finding R3 (the reported half; the backpressure half is
[W1-08](W1-08-ship-queue-backpressure.md))
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17) — extends
[W6-07](done/W6-07-pull-private-advisories.md) / GHSA-458x-24rf-g96f, which patched only `(0,0)`
**Severity:** `#play` LOW–MEDIUM / `#production` MEDIUM
**Effort:** S

## Why this is W3 and not W1

R3 argues these writes are permanent because "by design nothing can prune" the archive. **That is
true only on `#production`.** `resetExchange` deletes the entire archive chain including every prior
season's segments (`main.mo:15787-15797`) — but the branch is guarded `else if (not IS_PRODUCTION)`
(`:15779`). On the committed `#play` posture there is an operator remedy; on `#production` there is
not, and `setBlackholeAtSeal` makes it irreversible by design.

Quantitatively the tape harm is modest: ~595–608 stored bytes per event (the archive re-encodes the
full Candid type table per event — a ~6.8× amplification over the ~88 bytes the same event costs
inside a ship batch), ~3 events per call, and `_archiveCapEvents = 10_000_000` (`:7485`), so ~3.3M
successful calls to force one archive roll — ≈$22 one-off plus ≈$30/yr in perpetuity. Real,
permanent, not High.

## Corrections to the finding

- **`fundMarginPool` is not open to arbitrary pools.** `if (not ownsPool(msg.caller, poolId))` at
  `:10363` and `:10382`; `MAX_POOLS_PER_OWNER = 64` (`:3932`). You can only fund your own pool.
- **"Two `poolTransfer` records" is misleading.** `recordPoolTransfer` (`:4060-4063`) uses
  `appendCapped(..., EPISODE_RETENTION_CAP)` — a bounded 200-per-owner ring (`:4039`), not permanent
  tape. It is not part of the unbounded growth.
- **`#insShareDelta` / `#lpShareDelta` are not per-call.** They come from `drainClaimLedgers`' shadow
  diff (`:7900-7960`), once per heartbeat — N spam calls in one beat collapse to one row. Real cost
  is 3 events/call for doors (i) and (iii), 2 for door (ii), not 4.

## Confirmed, and worth more than the bloat

`performLpDeposit` (`:12989`) guards only `baseAmount == 0 and quoteAmount == 0` (`:13003`). A
`(0,1)` deposit transfers one base unit, mints 0 (`VaultMath.mintAmount` floors —
`lib/VaultMath.mo:21-27` — and share value exceeds 1.0 in the normal state because fees and
`LP_EXIT_FEE_BPS` accrue without minting), no-ops `addVaultLp` (`:13898-13899`), emits `#lpDeposit`
unconditionally (`:13112`) and returns `#ok(0)`. Its sibling `stakeInsurance` **does** refuse this,
with 13 lines of comment justifying it (`:11850`). The asymmetry is undefended.

**The sharper consequence, not in the report:** `vaultCostBasis += depositValueUsd` runs at `:13109`
**regardless of mint**, so repeated zero-mint dust deposits inflate the LP cost basis and corrupt
`gainLossPct` for **every** LP. That is a correctness bug affecting honest users, and the zero-mint
guard fixes it as a side effect. Relatedly, `LP_MIN_FIRST_DEPOSIT_USD` ($1000, `:14091`) is gated on
`vaultLPSupply == 0` (`:13058`) — it protects the first depositor only, never the 2nd through Nth.

`seedAmmPool` (`:13116`) and `depositLp` (`:15208`) are identical two-line wrappers over the same
helper, so both are entry points to the same primitive.

Doors (ii) and (iii) confirmed as described: only `amount > 0` plus an availability check
(`:10362`, `:10381`), and the insurance zero-mint guard does not bite at share value ≈1.0.

Rate limiting: `lib/RateLimit.mo` has exactly **one** call site in the backend — `aiComplete`
(`:13442`, `:13445`, `:13566`). None of these methods is throttled. The codebase already has the
discipline they lack: `MIN_ORDER_ICPUSD = 10 ICPUSD` (`lib/Types.mo:275`) is enforced on
`placeOrder` (`:12056`) and `swap` (`:12252`).

## Fix

1. **Zero-mint refusal in `performLpDeposit`**, mirroring `:11850` verbatim — inserted after the
   `minted` computation at `:13104`, before any state write, so `vaultCostBasis` is not touched
   either. ~4 lines.
2. **Minimum notional** on `depositLp` (on `depositValueUsd`), `fundMarginPool` (`:10362`) and
   `stakeInsurance` (`:11769`), mirroring the `MIN_ORDER_ICPUSD` discipline, with the same
   spend-all exemption the order path uses.

**Do not** add a floor to `withdrawMarginPool` / `unstakeInsurance`. They are exit-set methods, and
capping exits is exactly the hazard `main.mo:8880-8891` warns about.

## Done when

- [x] `depositLp(0, 1)` refused loudly (min-notional floor fires pre-transfer; the zero-mint
      backstop behind it unwinds both legs, mirroring the failed-quote-leg path)
- [x] `vaultCostBasis` cannot move on a deposit that mints nothing (refusal precedes it)
- [x] Three entry doors floored (depositLp/seedAmmPool via the shared helper, stakeInsurance,
      fundMarginPool — all spend-all exempt, mirroring placeOrder); both exit doors untouched
- [x] `seedAmmPool` inheritance asserted (structure pins in the test cover all four guards)
- [x] `test_ghsa_round4.sh` §1 extended — **verified red pre-fix on a fresh scratch venue**
      ((0,1) returned `ok = 0`, dust stake returned `ok = 1000` — the literal finding), then
      **12/12 green post-fix**; fixture made venue-shape agnostic (dynamic market, insurance
      bootstrapped past its own $100 first-stake floor)
- [x] Posture note: the `#play` remedy is `resetExchange`; `#production` has none (and
      `setBlackholeAtSeal` makes the tape irreversible by design) — the guard is load-bearing
      only there. Recorded here and in the header's "Why this is W3"

---
## Status 2026-08-17 (final) — CLOSED, red/green verified live

---
## Status 2026-08-17 — implemented; red/green cycle in flight on the scratch venue

Landed in the working tree: zero-mint refusal in performLpDeposit (after the
mint calc, WITH two-leg unwind mirroring the failed-quote-leg path — the
transfers happen before the mint, contra the task's "before any state
write"); MIN_ORDER_ICPUSD floor (spend-all exempt, mirroring placeOrder) on
depositLp/seedAmmPool (shared helper), stakeInsurance, fundMarginPool; exits
untouched. test_ghsa_round4.sh §1 extended: (0,1) + dust-stake + spend-all
exemption + 4 structure pins, fixture made venue-shape agnostic (dynamic
market, insurance bootstrapped past its own $100 first-stake floor).
RED runs confirmed the pre-fix build accepts the dust cases; final red/green
on a fresh scratch venue in progress. The #play remedy note (box 6): the
posture asymmetry is recorded in the task header's "Why this is W3" — the
guard is load-bearing only on #production, where resetExchange cannot prune.
