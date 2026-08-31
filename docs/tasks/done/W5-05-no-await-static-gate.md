# W5-05 — The property that closes the reentrancy/double-spend class is pinned by nothing

**Issue:** [#41](https://github.com/dfinity/public-multidex/issues/41) item 3 — OhShii Labs
**Status:** **Property holds; gate absent** at `01d2b23` (2026-08-14)
**Severity:** `#play` INFO / `#production` MEDIUM
**Effort:** S — **best value-per-line in Wave 5**

## The property

`docs/security-review.md:143` closes an entire vulnerability class in six words: **"no `await` in any
user value path"** → no IC reentrancy double-spend.

**It is true today**, and I verified it: `lib/BorrowEngine.mo`, `lib/Liquidator.mo` and
`lib/Accounts.mo` contain zero `await`s; `mixins/UserAccount.mo`'s four occurrences are all inside a
single comment block. Every user value path commits as one message. In IC terms that is the strongest
guarantee available — not a lock that can be taken with the wrong key, but a property that holds by
construction.

And the reasoning is already written down where it matters: `UserAccount.mo` says the withdrawal body
is synchronous today, that chain-key custody will make it `debit → await transfer`, that **at that
point it must become a saga**, and that adding an in-flight guard now would be dead code protecting
nothing. That reasoning is right — which is exactly why this is a finding rather than a compliment.

## What's wrong

**Nothing in the repository will notice if the premise changes.** `scripts/lint-ratchet.sh` is the
only gate over Motoko source and it names exactly one file, `src/backend/main.mo` — none of the four
files where the property lives. No test asserts the absence. `tests/test_concurrency.sh` is a runtime
test, and for this class a runtime test cannot distinguish "the race is impossible" from "the race
did not happen this run" — both are green.

Failure mode: someone adds an `await` to a settlement path for an ordinary reason — a price lookup,
an archive call, a metrics ping — and silently removes the thing that closes the class, while
`security-review.md` still says it is closed.

## Evidence

- `src/backend/lib/BorrowEngine.mo`, `lib/Liquidator.mo`, `lib/Accounts.mo` — zero `await`
- `src/backend/mixins/UserAccount.mo` — four, all in one comment block
- `scripts/lint-ratchet.sh:97` — type-checks `src/backend/main.mo` alone
- `docs/security-review.md:143` — the claim

## Fix

Four files, one assertion, mutation-verifiable in one line. Add a static gate asserting `\bawait\b`
(and `await*`) absence in those four files.

**Pin `\bawait\b` rather than `await ` with a space**, or `await*` walks under it. Strip comments
first, or the `UserAccount.mo` comment block trips it.

When custody lands and the property genuinely changes, the gate is the thing that forces the saga
conversation instead of letting it be skipped.

## Done when

- [ ] Adding an `await` to any of the four files turns the gate red
- [ ] The `UserAccount.mo` comment block does not trip it
- [ ] `await*` is covered
- [ ] The gate names `security-review.md:143` in its failure text, so the next person finds the rationale

## Notes

The reporter conceded in a follow-up comment that one leg of this finding — that `lint-ratchet.sh`
names only one `.mo` file — was already filed as #36, and that `#41.3` should have said so. The
*property* is genuinely new; see [W5-18](W5-18-m0155-ratchet-scope.md) for the coverage half.

---
## Done — 2026-08-15

Hygiene §8: each of the four value-path files (lib/BorrowEngine, lib/Liquidator,
lib/Accounts, mixins/UserAccount) is comment-stripped (mo_code) and asserted
free of `\bawait\b` — which also catches `await*` at the t/* boundary. A
missing file is itself a failure (the gate cannot vouch for what it cannot
read). The failure text names docs/security-review.md:143 and points at
UserAccount.mo's custody comment: the gate exists to force the saga
conversation, not to be deleted when custody lands.

Verified: an `ignore await foo();` appended to EACH of the four files turns
the suite red with the §8 message; `await*` form also red; UserAccount's
4-line await comment block does not trip it; restored tree green.

**Incident during verification, resolved:** the first mutation loop (a) read
only stdout while the suite prints ✗ to stderr — misreading all four kills as
misses — and (b) restored via `git checkout --`, which destroyed the
uncommitted W4-03 `cash == 0` guard in Liquidator.mo. The §6i hygiene pin
caught the loss immediately; the guard was reconstructed byte-identical from
the session transcript and the full suite re-verified green. Lesson recorded
in session memory: mutation restores come from scratchpad copies, never
`git checkout`, and transcript audits must search full Bash heredoc text.
