# W5-07 — The Candid breaking-change hatch opens from the working tree, and downward

**Issue:** [#37](https://github.com/dfinity/public-multidex/issues/37) item 6 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** S

## What's wrong

`scripts/lint-ratchet.sh` states the design, and the design is good:

```
# The hatch is the version itself, not a flag or an env var: bumping the
# MAJOR of MM_API_VERSION is a visible, reviewable, committed act that the
# policy already requires for a breaking change. You cannot take the hatch
# without also making the declaration — which is the point.
```

Two lines below, `api_major_of()` takes *"a git ref, or `""` for the working tree"* — and the NEW
side is called with `""` while the BASE side reads a **committed** ref. So the comparison is
**working tree against committed base**, and you *can* take the hatch without making the declaration.

Executed by the reporter: commit a public-method removal with `MM_API_VERSION` untouched →
`✗ BREAKING interface change`, RC=1. Then edit the version **in the working tree only** and re-run →
`✓ apiVersion major 2 → 3 — breaking changes ALLOWED`, `lint-ratchet: PASS`, RC=0, while `git status`
shows the file modified and the commit still carries `"2.0.0"`. **What reaches `origin/main` is the
breaking change with no declaration anywhere in the history.** The ordinary path there is clerical:
bump, remove, push, forget to `git add`.

Separately, the comparison is `!=` rather than `>`, so **lowering** the major also opens the hatch,
and the message files a downgrade under *"Major bumps so far"*.

## Evidence

- `scripts/lint-ratchet.sh:198-201` — the stated design
- `:202-206` — `api_major_of()` accepting `""` for the working tree
- `:208` — `NEW_MAJOR=$(api_major_of "")`; `:209` — `BASE_MAJOR=$(api_major_of "$BASE_REF")`
- `:210` — `!=`

## Fix

- Read the NEW side from the **committed** ref (`HEAD`, or the ref being pushed) rather than the
  working tree, so the declaration must actually be committed.
- Use `-gt` rather than `!=` so a downgrade does not open the hatch.

The reporter flags their own remedy for the second half as **fix direction, not tested**: an
arithmetic test changes fallthrough for non-numeric majors, and `-gt` closes the downgrade and the
leading-zero case but not a digit-increase typo. Handle the non-numeric case explicitly.

## Done when

- [ ] A working-tree-only version bump does **not** open the hatch
- [ ] A committed bump does
- [ ] Lowering the major does not open it
- [ ] A non-numeric major fails loudly rather than falling through

## Notes

While in this file, fix the stale table-of-contents line `:42-46` that still documents *"Without didc
the subtype half skips"* — the behaviour 1.60 existed to remove, and which `:233-236` replaced with
*"Refusing to treat 'could not check' as 'compatible'"*. Two lines; belongs with this change and
[W5-18](W5-18-m0155-ratchet-scope.md).

---
## Done — 2026-08-15

The hatch now reads the NEW side from **HEAD** (`api_major_of "HEAD"`), so
the declaration must be committed — with a clerical-path hint when the
working tree bumps the major but HEAD lacks it ("commit the bump to take
it", the forgot-to-git-add case the reporter named). Comparison is `-gt`:
a committed DOWNGRADE is loudly refused (majors are monotonic) and an
unreadable/malformed major at either ref fails loudly instead of falling
through to look compatible (digits-or-empty is guaranteed by the extraction
grep, so "empty while base ref exists" = malformed constant). The stale TOC
lines (":42-46 didc-era 'subtype half skips'") now describe the 1.60
refusal behaviour.

Verified in a scratch clone (never the real repo — commits required):
baseline RC=0; (a) working-tree-only bump → hatch SHUT + hint, RC=0;
(b) committed bump → "major 2 → 3 — breaking changes ALLOWED", RC=0;
(c) committed downgrade → "✗ DOWNGRADED 2 → 1", RC=1; (d) committed
non-numeric major → "✗ unreadable", RC=1. Harness note for the ledger:
`git reset --hard` between cases reverted the copied fixed script and two
cases initially ran the OLD code (visible as `!=`-era output); re-copied
after each reset and re-verified. Lesson appended to session memory.
