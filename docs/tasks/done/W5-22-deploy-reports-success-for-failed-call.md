# W5-22 — `deploy.sh` prints `ok` for a canister call that returned `#err`

**Issue:** internal red-team round 2 — found while verifying R5; **not in the report**
**Status:** VERIFIED at `d8f4c58` (2026-08-17)
**Severity:** `#play` LOW / `#production` MEDIUM (a deploy gate asserting a false success)
**Effort:** S

## What's wrong

`scripts/deploy.sh:791`:

```bash
if icp canister call backend fundArbitrageur "($(e8 "${ARB_USD:-1281250}"):nat)" ... >/dev/null 2>&1; then
  ok "arb funded: \$${ARB_USD:-1281250} ICPUSD working capital"
else
  warn "fundArbitrageur failed — fund it manually before enabling"
fi
```

The `if` tests the **CLI exit status**. A Candid `#err` return is a *successful* call — the method
returned a value — so `icp canister call` exits 0 and the `ok` branch runs. `fundArbitrageur`
returns `#err` on `IS_PRODUCTION` (`src/backend/main.mo:5288`), so on a `#production` deploy the
script prints a **false** `ok "arb funded: $1281250 ICPUSD working capital"` and `:799` then calls
`setEnabled(true)` regardless.

The posture gate at `:536` accepts `production` as well as `play` for a non-local target, so the
path is reachable. The balance probe at `:789` uses `getTestBalance`, which traps on `#production`,
so `arb_bal` is empty and the fund branch always runs.

## Severity, honestly

The consequence is a misleading deploy log plus an enabled-but-inert arbitrageur, **not** value loss
— `extMarketSwap` also hard-`#err`s on `IS_PRODUCTION` (`:5372`), so the enabled arb cannot trade.
But this is exactly the class W5 exists for: *a gate that certifies a fix is blind*. A deploy script
that reports success for a failed call is the kind of thing that is harmless until the day the
underlying call matters.

It also contradicts the rule stated at `icp.yaml:62-64`.

## Fix

Parse the returned variant, not the exit status — the pattern already used elsewhere in the repo for
`#ok`/`#err` returns. Then audit the whole script for the same `if icp canister call …; then ok`
shape; this is unlikely to be the only instance.

Separately decide whether the arb-wiring block should run at all on a `#production` target, or be
gated to `play` explicitly.

## Done when

- [x] The fund step gates on the VARIANT via the new shared `mdx_call_ok` predicate; a refusal
      now warns loudly with the actual returned text
- [x] Audit complete, recorded in the predicate's comment: `:216` getAmmPools pipes to its own
      grep (safe), `:633`/`:646` set*ApiKey return `()` (no #err arm), `:363` seedInsuranceFund
      converted (same class as the fund site)
- [x] Posture scope explicit at the site: fundArbitrageur's `#production` refusal is in-canister
      by design and now surfaces as the warn instead of a false ok
- [x] Hygiene §6m drives the REAL predicate (sliced from deploy.sh) with four fixtures — #ok
      passes, #err and CLI-error refuse — plus structural pins that the two calls gate on the
      variant and no exit-status-tested fund/seed call returns

---
## Status 2026-08-17 — CLOSED
