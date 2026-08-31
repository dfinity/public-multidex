# W5-09 — One `.mjs` in `scripts/` is run by a gate and the other is not

**Issue:** [#37](https://github.com/dfinity/public-multidex/issues/37) item 7 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** M

## What's wrong

`disableTimeVerification` has exactly two code sites. `src/frontend/src/ledger.js` is pinned by
`tests/frontend_security.test.mjs`. `scripts/verify_ledger.mjs` — **the tool the docs page hands to
users who do not want to trust the site** — is opened by **no gate in the repository**.

`tests/test_deploy_hygiene.sh:126` iterates `for f in scripts/*.sh scripts/lib/*.sh` — `*.sh` cannot
match `.mjs`, which is also why a name-grep could never establish this. The census that can:
`grep -rn 'node scripts/'` over `tests/ scripts/ ops/ .github/` returns exactly two hits — the
execution at `lint-ratchet.sh:262` (`node scripts/check-badge-sync.mjs`) and a usage line inside a
comment in `verify_ledger.mjs` itself.

**This is a missing gate, not an over-claiming one.** The frontend suite's charter says *frontend*,
and the 1.60 triage §1.1 is titled for the in-browser verifier, naming the CLI only as *"the pattern
to port"*. The suite is complete over its remit. But the pin's own failure string cites
`verify_ledger.mjs:430-435` as the reference **while never opening the file**.

## Evidence

- `tests/test_deploy_hygiene.sh:126` — `scripts/*.sh scripts/lib/*.sh`, cannot match `.mjs`
- `scripts/lint-ratchet.sh:262` — the only gate that runs a `.mjs`
- `tests/frontend_security.test.mjs:114` — cites `verify_ledger.mjs` in a failure string without reading it

**Note from W2-02 (2026-08-15):** the fixes landed and were verified against the reporter's stub
by hand — expected exits are now: no-cert **1**, bad-cert **1**, good-cert+empty-tape **1**
(zero-progress rule), good-cert+withhold-2 **0**. Two things the gate must carry over: (a) the
stub's `canonical()`/`hashEvent()` slice window must be **marker-based** (`const enc = ` …
`const eq = `), not the gist's hardcoded 60f75f6 line numbers — W2-02 already shifted them; (b) the
stub treats a **defined-but-empty** `MDX_STUB_WITHHOLD` as "withhold everything" — the gate's
runner must unset, not blank, the scenario variables between runs.

## Fix

Add a gate that **runs** `verify_ledger.mjs` against a fixture — ideally the reporter's offline stub
(<https://gist.github.com/rvnt9999/a5cbbd482a9dbdd8dc803743c6e70896>), which impersonates the gateway,
opens no socket, and slices `canonical()`/`hashEvent()` out of the real file at runtime so the fixture
cannot drift from what it tests.

The gate should cover, at minimum, the [W2-02](W2-02-standalone-verifier-hardening.md) cases: all-`[]`
tail, missing certificate, bad certificate, and the honest one-event skew that must keep passing.

**Disclosed by the reporter and worth knowing:** deleting the CLI's time-verification waiver
outright — the strictly safest fix — turns the *existing* suite red, because `timeLines.length > 0` is
inherited from the `ledger.js` pin where the flag's presence is wanted. So W2-02 and this task need to
land together or the suite contradicts itself.

## Done when

- [ ] A gate executes `verify_ledger.mjs` against fixtures on every run
- [ ] The four W2-02 cases are covered, with the honest-skew control passing
- [ ] The `ledger.js` time-flag pin no longer forces the CLI to keep its waiver

---
## Done — 2026-08-15

The reporter's offline hostile-host stub is vendored under
tests/fixtures/verify-ledger-stub/ (attribution kept), and
tests/test_verify_ledger_gate.sh — auto-discovered by run_all's test_*.sh
glob — EXECUTES scripts/verify_ledger.mjs against it on every suite run:
a temp harness gets a copy of the real verifier beside a stub @icp-sdk/core,
MDX_REAL_VERIFIER points the stub's marker-based canonical()/hashEvent()
slice at the repo file (annotation (a): markers, not the gist's 60f75f6 line
numbers — already true of the W2-02 copy), and scenario env vars are UNSET
between runs via `env -u`, never blanked (annotation (b): defined-but-empty
MDX_STUB_WITHHOLD means "withhold everything"). All four W2-02 verdicts pin
green on first run: no-cert 1, bad-cert 1, good-cert+all-[] 1
(zero-progress), good-cert+withhold-2 0 — with output-text assertions so a
stub-side import throw cannot masquerade as an expected failure, and the
pass case additionally requires the stub's "[stub] Certificate.create
reached" breadcrumb.

Box 3: frontend_security.test.mjs gains an absence-tolerant CLI pin — every
`disableTimeVerification` line in verify_ledger.mjs must be LOCAL_HOST-
guarded, but ZERO occurrences passes (deleting the waiver is the strictest
posture and stays green — verified by mutation). Unguarding the waiver
verified red. Suite: PASS 75.
