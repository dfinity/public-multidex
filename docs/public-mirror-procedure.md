# Public mirror procedure — the "de la Vega snapshot"

**Status:** operator procedure, manual. There is no script for it (`scripts/` holds no
mirror helper; `scripts/phase1_snapshot.sh` is the Phase I leaderboard tool, unrelated).
This document records the recipe **as run on 2026-09-01** and the composition rules
ratified on 2026-09-03 (task 1788465053), so the next drop is a repeat, not a rediscovery.

The mirror is `github.com/dfinity/public-multidex`, the community-facing surface where
issues, PRs and private advisories arrive. It is a **downstream snapshot** of this
repository, not a fork with shared history: each refresh is ONE commit carrying the
whole tree, authored by the public house author, with no private history and no private
author identities. It moves only by the operator's hand on an explicit batch
instruction — consumer seats never push to any remote (factory law 8), and `origin`
(the private repository) is a separate, continuously synced remote with its own rule.

## Why it is a snapshot, and why the composition matters

The mirror is where reporters read us. Three things are load-bearing at every drop:

- **Sequencing.** Outward comments must cite public shas and public documents; a
  comment that links a file the mirror does not carry 404s. So: drop first, then the
  outward batch (comments, advisory replies) re-baselined against what the drop made
  public.
- **Privacy.** Per-reporter scores and standings are private (maintainer decision
  2026-08-17). The public `CONTRIBUTORS.md` is the **criteria-only** file; the private
  root `CONTRIBUTORS.md` is the scored internal ledger and must never ship.
- **Disclosure timing.** `SECURITY.md`'s rule — advisories are mirrored publicly once
  the fix ships — applies to our own documents too (below, "The held-primitive rule").

## Recipe as run on 2026-09-01

Private base: `main` at `e60b11d`. Public parent: `public/main` at `585814e`. Result:
`f233d18` ("MULTI/DEX 1.60 hardening drop"), then two single-file follow-ups
(`aac2da9` SECURITY.md, `1fff1d7` dependabot policy). All three: author and committer
`Joseph de la Vega <multidex@dfinity.org>`. History on `public/main` stayed linear
(`0241cba` → `16137cf` → `60f75f6` → `585814e` → `f233d18` → `aac2da9` → `1fff1d7`), so
the push was a fast-forward; no force push was needed.

Steps. Run from the private primary checkout with `main` at the commit being
snapshotted; `<scratch>` is a throwaway directory outside the repository.

1. **Fetch the mirror and open a scratch worktree on its tip** (detached; nothing is
   ever built or deployed there):

   ```
   git fetch public
   git worktree add --detach <scratch> public/main
   ```

2. **Replace the public tree with the private tree** — in `<scratch>`:

   ```
   git rm -r -q .
   git checkout main -- .
   ```

   `git rm -r .` empties the index and working tree so files deleted upstream since the
   last drop disappear too; `git checkout main -- .` restores every path **tracked** on
   private `main`. Untracked files (the outward-reply tracker under `docs/`, rollout
   config, key files) are never carried by construction. Never `git add -A`, here or in
   the primary.

3. **Apply the exclusions** (the standing list below, plus anything the held-primitive
   rule catches at this drop) — in `<scratch>`:

   ```
   git rm -r -q -- docs/tasks/drafts-w6-05 <further held paths>
   ```

   On 2026-09-01 the removed set was 12 paths: `docs/tasks/README.md`, the two W6-05 /
   W6-06 briefs (then still open), `docs/tasks/done/W6-07-pull-private-advisories.md`,
   and the eight files of `docs/tasks/drafts-w6-05/`. The README and the done/ briefs
   are **no longer** excluded as of the next drop — see "Standing inclusions".

4. **Substitute CONTRIBUTORS.md** with the public criteria file — in `<scratch>`:

   ```
   git show main:docs/tasks/drafts-w6-05/CONTRIBUTORS-public-PUBLISHED.md > CONTRIBUTORS.md
   git add CONTRIBUTORS.md
   ```

   The mirror's copy is that draft byte-for-byte (verified: `f233d18:CONTRIBUTORS.md`
   equals the PUBLISHED file). If the public criteria text changes, edit the PUBLISHED
   draft on private `main` first, then substitute; never edit the mirror copy directly.

5. **Audit what is about to become public.** In `<scratch>`, the diff against private
   `main` must be exactly the exclusion list plus the one CONTRIBUTORS substitution:

   ```
   git diff --name-status main            # expect: D <each excluded path>, M CONTRIBUTORS.md
   git status --short                     # nothing untracked, nothing unstaged
   ```

   Then the verification greps (below). Read the hits; do not skim the counts.

6. **Commit as the public house author** — in `<scratch>`:

   ```
   git -c user.name='Joseph de la Vega' -c user.email='multidex@dfinity.org' \
       commit -q -m '<drop title>' -m '<what this drop carries, in public terms>'
   git log -1 --format='%an <%ae> | %cn <%ce>'   # both halves must read de la Vega
   ```

   The scratch worktree inherits the global git identity, so the override is
   mandatory on every mirror commit (the `-c` pair or the `GIT_AUTHOR_*` /
   `GIT_COMMITTER_*` environment — the 2026-09-01 run's exact mechanism is not
   recorded; the result is what the log check verifies). The message describes the drop
   in public terms: public issue numbers and public docs are fine; factory task ids,
   private shas and private names are not.

7. **Push — operator act, explicit go only:**

   ```
   git push public HEAD:main
   ```

   Expect a fast-forward. A non-fast-forward means the mirror moved (a merged PR, as
   `60f75f6` once was): stop, fetch, rebuild the snapshot on the new tip; never force.

8. **Follow-up single-file syncs between drops** (how `aac2da9` and `1fff1d7` landed):
   in `<scratch>`, `git checkout main -- <path>`, commit as in step 6, push as in
   step 7. Reserve this for small public-facing files (SECURITY.md, `.github/`), and
   only for content that would pass the same audit.

9. **Clean up:** `git worktree remove <scratch>` from the primary (and
   `git worktree prune`). The 2026-09-01 scratch worktree was left in place; it is
   harmless but it is not the mirror's source of truth — `public/main` is.

## Standing exclusions

Held from every drop until the rule that holds them is lifted:

| Path / class | Why | Mechanism |
|---|---|---|
| root `CONTRIBUTORS.md` | the private scored ledger (per-reporter figures and standings are private) | **substituted** with `docs/tasks/drafts-w6-05/CONTRIBUTORS-public-PUBLISHED.md` (step 4) |
| `docs/tasks/drafts-w6-05/` | scoring figures, evidence maps and reply drafts | `git rm` (step 3) |
| the untracked outward-reply tracker under `docs/` | unposted replies and dispositions | untracked, so never carried (step 2); do not `git add` it |
| any file holding a score figure | same privacy decision | the score grep (below) — hits are excluded or the figure moved to the private ledger first |
| any triage document or task brief carrying a **working primitive** for an end-user-exploitable-pre-fix class whose fix has not shipped on the mirror | the held-primitive rule (below) | `git rm` at this drop; carried at the drop that ships the fix |

Rollout config (`scripts/.subnet.conf`, `scripts/.cloud-engine.conf`) and API-key files
are gitignored/untracked and cannot ride a snapshot; they are listed here only so the
audit remembers to confirm `git check-ignore` still covers them.

## Standing inclusions (as of the next drop)

Ratified 2026-09-03: the drop **carries** `docs/tasks/README.md` and the completed
briefs under `docs/tasks/done/`, W6-05 and W6-06 included — their figures were moved to
the private ledger on 2026-09-03 (commit `915041a`), so the tracked briefs are
score-free. The 2026-09-01 drop had held README, W6-05, W6-06 and the W6-07 done brief;
that hold is lifted for the README and for done/ briefs generally. Each done/ brief still
passes the held-primitive check at composition time — a brief for a fix that IS in the
drop carries its primitive legitimately, a brief for a fix that is not yet on the mirror
does not.

## The held-primitive rule (ratified 2026-09-03)

`SECURITY.md`: *"The same rule applies to our own triage documents and task briefs: any
that carry a working primitive for that class are held from the public mirror until the
fix ships."* The class is SECURITY.md's private-advisory class — working exploits on
sign-in / delegation / custody flows, or de-anonymisation of a specific person.

Why it exists: private advisory GHSA-63hp-3pxg-9mcc recorded, correctly, that our own
triage document published the delegation-page callback primitive (#11.4) on the mirror
on 2026-08-07, against the still-unfixed page, 24 days before the fix shipped in the
2026-08-31 drop — the reporters had withheld the reproduction themselves. The mechanism
is the exclusion list, **not redaction**: a held file is simply not carried until the
drop that ships its fix, and then it goes out whole. At each drop the composition step
asks, per triage document and per brief: does this carry a working primitive for that
class, and is the fix in this drop? "Yes / no" means hold.

## Verification greps (run in `<scratch>` before step 6)

Every grep is a read, not a count — open each hit and decide.

```
# absolute private paths and machine-local scratch locations
grep -rn -E '/(Users|home)/|/private/tmp' --exclude-dir=.git --exclude-dir=node_modules .

# private identities: every author name and email on private main that is not the
# house author must be absent from the TREE (they may exist in the private history only)
git log --format='%an%n%ae' main | sort -u | grep -v -i 'de la vega\|multidex@dfinity.org' \
  | while read -r ident; do grep -rn -F "$ident" --exclude-dir=.git --exclude-dir=node_modules . ; done

# score figures and standings
grep -rn -i -E '\b(score|scored|points|pts|standings?)\b' CONTRIBUTORS.md docs/ | grep -E '[0-9]'

# the private drafts directory and the untracked tracker must be absent
test ! -e docs/tasks/drafts-w6-05 && ! git ls-files | grep -q -i 'outward-reply' && echo ok

# the held-primitive class: every private-advisory id named in the tree must be one
# whose fix is in this drop (compare against the advisory list on the tracker)
grep -rn -o -E 'GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}' --exclude-dir=.git . | sort -u

# secrets: key files are ignored, never tracked
git ls-files | grep -i -E 'api-key|\.conf$' ; git check-ignore -v scripts/.anthropic-api-key
```

The exact grep set run on 2026-09-01 was not recorded in the repository; the set above
is the standing one from this drop on, and the audit of a drop records which were run
and what they hit in the drop's factory/operator note.

## Record of drops

| Mirror commit | Date | Content | Private base |
|---|---|---|---|
| `0241cba` | 2026-08-01 | first public snapshot | — |
| `16137cf` (merged as `60f75f6`, PR #30) | 2026-08-07 | MULTI/DEX 1.60 | — |
| `585814e` | 2026-08-17 | `CONTRIBUTORS.md`, criteria only (committed under the maintainer's own identity, before the house-author rule was standing) | `ffe2bef` era |
| `f233d18` | 2026-08-31 | 1.60 hardening drop, 227 files; 12 `docs/tasks/` paths held, CONTRIBUTORS substituted | `e60b11d` |
| `aac2da9` | 2026-09-01 | SECURITY.md public-by-default policy (single-file sync) | `5799839` |
| `1fff1d7` | 2026-09-01 | dependabot version-update PRs off (single-file sync) | `5425683` |
| `a225a74` | 2026-11-02 | MULTI/DEX 1.75 drop, 519 files; the 8 `docs/tasks/drafts-w6-05/` paths held, CONTRIBUTORS substituted; `docs/tasks/README.md` + the done/ briefs INCLUDED for the first time; the GHSA-h888 row rides it (round-18 outward batch posted the same sitting) | `9dd48f5` |
| `7bcdde6` | 2026-11-04 | MULTI/DEX 1.80 drop, 519 files; same composition as 1.75 (8 drafts paths held, CONTRIBUTORS substituted, README + done/ briefs included); re-cut on the final main after both targets were verified | `63307e2` |

Next drop: the operator says when; composition per the sections above.

**Pushing from the scratch worktree (learned 2026-11-02):** the repository's `pre-push` hook
(`.githooks/pre-push`, `core.hooksPath`) runs `scripts/lint-ratchet.sh` in the pushing worktree.
In a detached scratch its candid breaking-change gate cannot read its `origin/main` baseline and
FAILS the whole ratchet ("could not read origin/main's contract"), blocking the push. The snapshot
tree is `origin/main`'s minus the audited exclusions, and `origin/main` passed the ratchet at every
merge-land, so the check is environmental: verify
`cmp <(git show origin/main:candid/backend.did) candid/backend.did` in the scratch (identical),
then `git push --no-verify public HEAD:main`. Record the bypass and the cmp in the drop's note.
