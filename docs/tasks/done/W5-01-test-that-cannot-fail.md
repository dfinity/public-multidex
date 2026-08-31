# W5-01 — `tests/test_market_walks_locked.sh` can never fail

**Issue:** [#28](https://github.com/dfinity/public-multidex/issues/28) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** S

## What's wrong

```bash
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1 — $2"; }     # echoes and nothing else
```

`fail()` increments no counter. The file declares no `pass=0; fail=0`, never calls `finish_test`,
never reads `_TEST_ERRORS`, and does not `set -e`. Its last executed command is an `echo` in
**either** branch, so the exit code is 0 whether the assertion held or not, and `run_all.sh` records
**PASS**.

**What it was guarding:** that the matching engine walks *through* a locked/protected maker and soaks
≥ 9 ETH across immediate fills plus pending matches. If the engine regressed to stopping at the first
protected maker, this test prints `✗` and reports PASS.

**Why it matters beyond one file:** this is the **second** dead check on matching-engine walk-through
behaviour. `tests/MatchingEngine.test.mo` did not compile (M0151) for the same property. Two
independent checks on how the engine traverses protected makers, both non-functional, failing in
different ways — one did not build, one cannot fail.

## Evidence

- `tests/test_market_walks_locked.sh:17` — `fail()` with no counter
- `:48-55` — the verdict region, `echo` in both branches
- `tests/run_all.sh:138` — `if bash "$t"; then rc=0` records PASS

## Fix

One line of harness, using the idiom 36 of the other shell tests already use: add `pass=0; fail=0`,
increment in `fail()`, and end the file with `exit $fail`.

Then **check the assertion actually passes** — a test that has never been able to fail has never
been known to be green for the right reason. Run it against a tree with the walk-through property
deliberately broken and confirm it goes red.

## Done when

- [ ] The file exits non-zero when its assertion fails
- [ ] It is verified red against a deliberately broken walk-through, and green on the shipped tree
- [ ] Landed with [W5-02](W5-02-run-all-discards-failed-count.md), which is why this was invisible

---
## Done — 2026-08-15

Bitrot went far past the dead verdict: the whole file predated integer money
AND the sealed-release model (float64 args, instant-fill assumptions). Full
repair, not a patch: pass/fail counters with `exit $fail`, e8 integer args,
self-contained ETH venue setup, an explicit release phase (setAmmRefPrice +
requoteAmm) between placements, balance-measured outcomes, and ETH balances
zeroed at entry so reruns don't inherit position. Verified red against a
deliberately broken walk-through, green on the shipped tree. Landed with
[[W5-02]] — run_all's discarded fail count was why this stayed invisible.
