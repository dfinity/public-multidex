# W6-12 — Closing a task must check the adjacent case, not just the reported one

**Issue:** internal red-team round 2 — the pattern across R2, R3, R4, R9, R12
**Status:** Process change
**Severity:** Process — this is why round 2 exists
**Effort:** S (a checklist line + two test-shape rules)

## The observation

Five of round 2's twelve findings are **gaps in fixes that landed in `d8f4c58`**, the commit that
closed the 54-task W1–W6 queue:

| Finding | Lands on | What the fix did | What it missed |
|---|---|---|---|
| R2 → [W4-22](W4-22-sweep-fee-role-and-maker-attribution.md) | W4-18 volume credit | credited swept makers | credited them in the **taker role** |
| R3 → [W3-10](W3-10-minimum-notional-and-zero-mint.md) | W6-07 / GHSA-458x | refused `depositLp(0,0)` | `(0,1)` behaves identically |
| R4 → [W1-07](W1-07-repoint-order-identity-reverse-scan.md) | W4-07 sweep repoint | carried expiry, relinked ids | introduced an O(100k) scan per swept order |
| R9 → [W5-21](W5-21-finish-deferredexecs-owner-index.md) | W5-19 uncapped sweeps | indexed six walks | **five** reader paths still full-scan |
| R12 → [W4-23](W4-23-clamp-amm-half-spread.md) | breaker widening | capped staleness at 2500 bps | left `breakerBps` and `volRegime` uncapped |

None of these is a careless fix. Each closed its stated `Done when` boxes honestly. The failure is
structural: **the boxes described the reported instance, not the property.**

## The two test shapes that let it through

Worse than the gaps themselves, the covering tests *pass on the wrong behaviour*:

- `tests/test_volume_credit.sh:67-84` exercises the AMM sweep, calls the user "the swept maker", and
  then asserts only the **role-agnostic** `lifetimeVol` badge. The role bug is invisible to it. The
  test proves volume arrived; the task was about *whose* volume it was.
- `tests/test_ghsa_round4.sh:25-28` asserts `depositLp(0,0)` is refused. It never tries `(0,1)` —
  the boundary one unit away, which the same guard was conceptually meant to cover.

Both assert a **proxy that aggregates away the thing the fix changed**.

## The change

Add to the task-closing routine — `docs/tasks/README.md` and the security-review checklist:

1. **Enumerate the adjacent cases before closing.** For a guard: the zero case *and* the
   one-unit case *and* the boundary the guard's sibling already handles. For a call site: `grep` the
   *mechanism*, not the reported line, and list every hit with a verdict — the W5-19 table is the
   model, and R9 shows it works only if the grep is re-run rather than inherited.
2. **Assert on the specific series the fix claims to move**, never a proxy that aggregates it away.
   If the fix is about maker volume, assert `myMakerVolUsd`, not a lifetime-volume badge.
3. **When a fix adds a new helper, cost it.** W4-07 introduced a full-map scan inside a per-item
   loop in the same commit as an audit whose subject was uncapped scans. A new function on a hot
   path needs the same instruction-cost note W5-19 requires of the ones it bounded.

## Done when

- [x] The three rules are in `docs/tasks/README.md` ("Closing a task", right under the wave
      ordering), each citing its round-2 worked example
- [x] `docs/security-review.md` references them at its closing-a-fix paragraph
- [x] The two named tests fixed and cited: `test_ghsa_round4.sh` §1 now walks the adjacent cases
      ((0,1), dust stake, spend-all exemption — W3-10) and `test_volume_credit.sh` §2 asserts
      `myMakerVolUsd` — the specific series — plus a §3 post-only end-to-end pin (W4-22)

---
## Status 2026-08-17 (final) — CLOSED

Both worked examples are green: `test_ghsa_round4.sh` 12/12 (adjacent cases
walked, red-verified) and `test_volume_credit.sh` 5/5 (`myMakerVolUsd`
asserted, red-verified at 0 pre-fix). The rules are load-bearing in the
queue README and the security-review checklist.
