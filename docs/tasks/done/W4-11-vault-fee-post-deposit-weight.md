# W4-11 — The vault deposit fee is priced at the pre-deposit weight

**Issue:** [#16](https://github.com/dfinity/public-multidex/issues/16) Finding 3 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` LOW–MEDIUM
**Effort:** M

## What's wrong

The deposit fee is computed from a **pre-deposit** vault snapshot: `vaultBefore = currentVaultValue()`
is taken first, and `depositMultiplier(token, vaultBefore)` reads only the snapshot's *current*
weight — it never sees the deposit size. `feeMultiplier` short-circuits to 1.0 whenever the current
weight is at or under target.

So a single deposit made from an at-or-under-weight state pays **zero concentration fee however far
it skews the vault**, while the sibling guard `depositRejectsConcentration` correctly computes the
**post**-deposit weight.

Bounded by that concentration cap and by the 40 bp exit fee, and there is no theft — the vault
receives full value. It is an incentive/risk-policy defect, and a perverse one: chunking a deposit
costs *more* than making it in one shot, which is the opposite of the intended incentive.

## Evidence

- `src/backend/main.mo:12216` — `vaultBefore = currentVaultValue()` (pre-deposit)
- `:12264-12265` — fee uses `depositMultiplier(token, vaultBefore)`
- `:13294` — `depositMultiplier` reads only the snapshot weight, never the deposit size
- `src/backend/lib/VaultMath.mo:32` — `feeMultiplier` short-circuits to 1.0 at/under target
- `:13315` — `depositRejectsConcentration` **does** compute post-deposit `wPost` — the form to reuse

## Fix

Price the fee on the **post-deposit** weight, reusing the `(cur + legAdd) / (T + totalAdd)` form
`depositRejectsConcentration` already computes, rather than the pre-deposit snapshot.

Check the incentive direction after the change: the fee should make a skewing deposit more
expensive than a balancing one, and chunking should not be cheaper than a single deposit.

## Done when

- [x] A large skewing deposit from an under-weight state pays a non-zero fee
- [x] Chunking the same total is not cheaper than depositing it at once
- [x] `amm-vault-design.md` matches the implemented rule
- [x] A test compares fees for balancing vs skewing deposits of equal size

## Completed 2026-08-15 (W4 batch 2)

Fee priced at the MIDPOINT weight `(cur + legAdd/2)/(T + totalAdd/2)` — the discrete integral, so
single-shot and chunked deposits price out the same (second-order) and the chunking-costs-more
perversity is gone along with the free single-shot skew. Callers pass leg/total USD; the dashboard
view passes 0/0 = the marginal multiplier. `amm-vault-design.md` updated. `test_w4_batch2.sh` §2:
from an at-target state, a $100k skewing deposit pays per-USD while a $200 one is ≈free — pre-fix
both were free.
