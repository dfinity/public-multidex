# W5-18 — The repaired `M0155` ratchet is still inert outside `src/backend`

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** S — **but contains a decision that is yours**

## Context — #21 is closed correctly and this does not re-open it

Both legs really are repaired: the `': error'` detector is gone, replaced by an exit-code gate, and
the restored `MOC_FLAGS` really do make the analysis run. The reporter confirmed with a positive
control — an in-scope break of `src/backend/main.mo` now turns the gate red, which it could not do
before.

The sentence being corrected is: *"the M0155 count is now genuinely 0 rather than blind."* It is
genuinely 0 **for `src/backend`**.

## What's wrong

`scripts/lint-ratchet.sh:160` filters the ratchet's own output through a hardcoded path literal:

```bash
| grep -oE 'src/backend/[^:]+\.mo:[0-9]+' | grep -v '/oql/' | sort -u | wc -l | tr -d ' '
```

So widening the input set is a **verified no-op**. With `OUR_FILES` widened, `moc` reports
`src/bridge/main.mo:287.54-287.77: warning [M0155]` and `:318.52-318.75`, and the gate still prints
`✓ M0155: 0 (at baseline)`.

This is also why rejecting "widen the glob" in #21 was right, and the reporter does not propose it.
The change is **two lines** — the file set **and** the path filter — and it turns the gate red on the
current tree at `✗ M0155: 2 > baseline 0`.

**That is correct behaviour, not a defect in the remedy.**

Separately: `:97` type-checks `src/backend/main.mo` alone, so `src/arb` and `src/bridge` are **never
compiled by the hook**. A syntax error injected into either is pushed green while `moc --check` on the
same file returns 1. The deploy path does build them, so this is an assurance gap, not a live hole.
(This is the coverage half of [W5-05](W5-05-no-await-static-gate.md).)

## The decision that is yours

The two `M0155` sites are `l.confirmed - l.claimed` guarded by `if (l.confirmed > l.claimed)`. The
file's own instructions say to **resolve rather than bump the baseline**, and give both accepted
forms. The reporter deliberately did **not** apply either, because choosing between the clamp and the
type annotation is a claim about the Bridge's accounting invariant — and that claim is yours to make.

- **Clamp** (`SafeMath.subOrZero`) says: underflow is possible and zero is the intended answer.
- **Type annotation** says: the guard makes underflow impossible and the compiler should be told.

Given `SafeMath.mo`'s own header rule (see [W5-12](W5-12-motoko-hygiene-transient-and-subpendingqty.md)),
if the guard genuinely makes it impossible, the annotation is the honest choice and a clamp would
mask a future invariant break.

## Done when

- [ ] The ratchet's file set and path filter cover `src/bridge` and `src/arb`
- [ ] The two Bridge sites are resolved (not baselined), with the choice explained at the site
- [ ] `moc --check` failures in `src/arb`/`src/bridge` fail the hook
- [ ] The gate is red-then-green across the fix, demonstrating it can see these files

---
## Done — 2026-08-15

- **Scope:** OUR_FILES now globs src/backend + src/bridge + src/arb (oql
  still excluded), and the M0155 path filter accepts all three roots — the
  widen-the-glob-only no-op the reporter demonstrated is closed from both
  ends. lintoko inherits the widened set (clean on the current tree).
- **Roots:** the type-check gate is a loop over all four program roots
  (backend/main.mo, ArchiveCanister.mo, bridge/main.mo, arb/main.mo), each
  gated on moc's exit code. A syntax error injected into src/arb/main.mo
  fails the hook — verified live, then removed.
- **The decision:** both Bridge sites are `if (l.confirmed > l.claimed)`
  guarded, so the subtraction is guard-proven non-negative REGARDLESS of the
  global accounting invariant — annotated `((… ) : Nat)` per the file's own
  invariant-backed form, with the why at both sites: a clamp would silently
  absorb a future break of confirmed ≥ claimed, and we want that loud
  (SafeMath's own header rule, same doctrine as W5-12 item 4).
- **Red-then-green:** after widening, before resolving — `✗ M0155: 2 >
  baseline 0` (the gate SEES bridge). After the annotations — `✓ M0155: 0
  (at baseline)`, `lint-ratchet: PASS` end to end (which also re-exercises
  the W5-07 hatch and W5-08 toolchain sections in the assembled script).
