# W6-04 — A README sentence no gate maintains

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` INFO / `#production` LOW
**Effort:** S (minutes)

## What's wrong

`README.md:97-98` says the backend "is kept free of compiler warnings". It emits **10** — 8 × M0194
and 2 × M0217 — and `lint-ratchet.sh:106` prints the count as information and exits 0.

The gate is **not wrong**: its own comment says warnings are surfaced as info deliberately. **The
sentence is wrong.**

## Fix

Fix the text, not the code. Turning M0194 into an error fails the tree today, and that is a separate
decision with a real cost.

Reword to what is actually true and enforced — something like: the backend is type-checked on every
push, the M0155 count is ratcheted at zero, and remaining compiler warnings are surfaced as
information.

While here, check the same paragraph for other claims no gate maintains — this is the class, and a
sentence is cheaper to fix than a gate.

## Done when

- [ ] `README.md` describes what the gate actually enforces
- [ ] The claim is specific enough that a future reader can check it
- [ ] If the ambition is genuinely zero warnings, that becomes its own task rather than a sentence

---
## Done — 2026-08-15

Text fixed, not the code (per the task: making M0194 an error is a separate
decision with a real cost — not taken up as a task; the ambition on record
is the ratchet, not zero warnings). The README paragraph now enumerates
exactly what the pre-push gate enforces — four-root type-check, lintoko
zero, M0155 hard zero across backend+bridge+arb, mops.lock SHA-256
integrity, candid freshness/subtype — and states plainly that non-M0155
warnings are surfaced as information with a printed count. Each claim maps
to a named section of lint-ratchet.sh, so a future reader can check it
(current warning count at close: 14 non-M0155 across the widened root set,
printed by the gate itself). Checked the rest of the paragraph for the same
class: the deploy-entry-point and seeding claims match deploy.sh's current
behaviour (including the new gen-did step from W5-20).
