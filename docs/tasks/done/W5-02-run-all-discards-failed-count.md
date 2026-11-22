# W5-02 — `run_all.sh` computes the failing-assertion count and then discards it

**Issue:** [#28](https://github.com/dfinity/public-multidex/issues/28) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` LOW
**Effort:** S

## What's wrong

```bash
passed=$(LC_ALL=C grep -ac '✓' "$log" || true)
failed=$(LC_ALL=C grep -ac '✗' "$log" || true)
...
if [ "$rc" -eq 0 ]; then
  echo -e "  ${GREEN}PASS${NC} (${dur}s · ${passed} assertions)"    # `failed` never read
```

On the PASS branch, `failed` is never consulted. A test that prints `✗` lines but exits 0 — i.e.
[W5-01](W5-01-test-that-cannot-fail.md) — is reported as `PASS`, with the evidence of its own failure
sitting in a shell variable one line above.

This is not the cause of W5-01; it is **the reason W5-01 was invisible**. That is the more important
property: the suite prints a total, and the total gets believed.

## Evidence

- `tests/run_all.sh:268-269` — `passed` / `failed` computed
- `:279` — the verdict gates only on `rc -eq 0`
- `:280-290` — the PASS branch never reads `failed`
- `:292`, `:302`, `:311` — `failed` used only on the FAIL branch and in the JSON

**In fairness to the harness**, and checked before filing: `tests/_lib.sh`'s `finish_test` is correct
(it reads `_TEST_ERRORS` and exits 1); the 36 tests using self-contained counters end with
`exit $fail`, which is correct; `run_all.sh` discovers tests dynamically so there is no drift list;
and it gates correctly on `mops test`'s exit code.

## Fix

Two one-line assertions on the PASS branch:

- downgrade to FAIL when `failed -gt 0`
- flag a test that asserted **nothing** (`passed -eq 0`) — that catches the next W5-01 before it needs
  its own issue

## Done when

- [ ] A test printing `✗` but exiting 0 is reported FAIL
- [ ] A test asserting nothing is flagged
- [ ] The suite's totals are trustworthy enough to quote in a release note

## Notes

Context, not a finding: there is no `.github/` CI configuration and `package.json` declares no `test`
script, so every gate in this repository runs only when a human remembers to run it. That is the
precondition that lets a dead test and a red suite persist.

---
## Done — 2026-08-15

run_all.sh's PASS branch now consults `failed` (the ✗ grep count) instead of
throwing it away: a suite that prints failures but exits 0 is reported
`PASS?` with the count, flagged as a zero-assertion/self-contradiction
suspect, and the run total goes red. This is the harness half of the
[[W5-01]] pair — the repaired walks test is the proof body (its ✗s now
count even where an exit code lies).
