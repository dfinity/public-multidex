# W5-15 — The only bridge-upgrade test has no oracle for either property its header names

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 5 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** M

## What's wrong

`tests/test_deposit_ledger_guard.sh` §5 is the **only test-side bridge upgrade in the repository**.
It has exactly two assertions, and neither can observe either property the section's own header
names: one reads a **compile-time constant**, and the other queries a key that is **unset with or
without the code it is meant to pin**.

This matters more than a typical coverage gap because the bridge-upgrade window is precisely where
[W3-04](W3-04-bridge-admission-write-ahead.md) lives — a lost continuation during a routine deploy.
The one test that exercises an upgrade cannot see the class of defect that upgrades cause.

## Evidence

- `tests/test_deposit_ledger_guard.sh:138-148` — §5, the two assertions
- The section header names two properties; neither assertion can observe either

## Fix

Give the section a real oracle:

- drive an actual state transition across the upgrade (admit → upgrade → observe), rather than reading
  a constant
- assert on a key that is **set** before the upgrade and must survive it, so the assertion can fail
- add the [W3-04](W3-04-bridge-admission-write-ahead.md) case once that fix lands: a deposit whose
  continuation is destroyed by the upgrade must leave the counter reproducible and the allowance
  debited once

Verify by mutation: revert the code the section claims to pin and confirm the section goes red.

## Done when

- [ ] Each assertion fails when the property it names is broken
- [ ] The section exercises real state across the upgrade boundary
- [ ] It covers the lost-continuation case from W3-04

---
## Done — 2026-08-15

§5 rebuilt around real state crossing the boundary (the old pair — a
compile-time constant and an unset latch key — kept as a tail check, no
longer the only oracle). The section now: binds a FRESH per-run principal
(randomized email — the fixed-email rebind was silently refused by the
anti-sybil hook, found while building this), admits 1.0 BTC at a $100 mark
(the W3-04 write-ahead pending row + the DEX allowance charge = state that
is SET), upgrades the bridge, and asserts: the pending row survives
byte-for-byte, the charge survives exactly-once, a post-upgrade 0.5 BTC
deposit charges exactly its $50 mark value (the ledger still BOOKS, not
just serves), and devConfirmDeposits — driven by the depositor, whose own
rows it iterates — finishes both parked rows exactly-once (1.5 BTC
confirmed, 0 pending). That last leg is the W3-04 lost-continuation
recovery shape: parked mid-flow rows crossing an upgrade and finishing
once, nothing doubled, nothing stranded.

Mutation-verified: `Map.clear(ledgers)` added to postupgrade (the
"clears one map too many" class the header warns about) → deployed → §5
red on exactly the survival + exactly-once assertions; restored + redeployed
→ full suite PASS, invariants green (venue LP debris cleared with a
one-time resetExchange before the runs — the final cold_start reseed is
still owed at session end).
