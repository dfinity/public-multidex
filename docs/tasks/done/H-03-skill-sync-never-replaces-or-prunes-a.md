# H-03 — Skill sync never replaces or prunes a directory it did not install

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 0 (operator machine & pipeline (no canister upgrade)) · findings F7 · MEDIUM · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` · `touches: deploy, tests`

**Mechanism.** `.claude/sync-ic-skills.sh:154-165` moves aside and replaces ANY existing
`.claude/skills/<name>` the remote index names and records it as managed; `is_safe_name`
(`:35-40`) blocks traversal only; `:196-205` returns `reloadSkills: true`. The prune loop
(`:101-111`) honours the manifest, the install path does not. The two git-tracked guardrail
skills (`.gitignore:11-16`; `git ls-files .claude/skills` = exactly those two SKILL.md files)
are replaceable by an index entry of the same name and deletable by a later index that drops it.
Whoever controls responses from `skills.internetcomputer.org` gains authority the header
(`:9-10`) says the mirror never has.

**Fix criteria.** Before the swap, if `$DEST/$name` exists and `$name` is not in the manifest —
or is git-tracked (`git ls-files --error-unmatch`) — skip with a warning, remove the staging
dir, never `record`. `curl --proto '=https' --proto-redir '=https'` pinned to the origin host.
Add a `SYNC_BASE` override so the script is testable offline. (Digest pinning / making the sync
an explicit command instead of a SessionStart hook is a separate decision — note it in D8.)

**Verify.** Hygiene block: run the script against a local fixture index naming
`mdex-process-safety`; assert the tracked directory and the manifest are byte-identical after.

**done 2026-09-04** (task `1788467591`, branch claude/seat-1, on top of `c706463`, code commit `974fcfe`): `.claude/sync-ic-skills.sh` + hygiene only — no canister change, no deploy, no venue. **Fix 1 (ownership guard)**: before any download, a name the index carries is refused — warned on stderr, no staging dir, never `record`ed, so it also leaves the manifest — when `git ls-files --error-unmatch -- .claude/skills/<name>` says git tracks it (the repo's own `mdex-process-safety` / `mdex-software-factory`, whatever the manifest says) or when `.claude/skills/<name>` exists and the CURRENT manifest does not list it; the prune loop refuses git-tracked names too, so a poisoned manifest listing a repo-owned skill that a later index drops cannot delete it (the name is dropped from the manifest instead). Refusals are counted and surface in the hook's `systemMessage` (`N refused`), with `reloadSkills` true only when something on disk actually changed. **Fix 2 (origin pin)**: one `fetch` helper — `curl --proto "=$PROTO" --proto-redir "=$PROTO"` where `$PROTO` is the scheme `$BASE` carries, and the effective URL after redirects must still sit under `$BASE` or the download is discarded — carries the index and every file (the one upstream probe on 2026-09-04 answered 200 with 0 redirects, so nothing legitimate changes). **Fix 3 (`SYNC_BASE`)**: overrides the origin for OFFLINE fixtures; only `https://…` or `file:///…` are accepted (anything else warns `SYNC_BASE must be https…` and exits 0 before any fetch — a SessionStart hook never fails the session). **Verified**: hygiene §3f (9 source pins + the behaviour DRIVEN in a throwaway tree under the suite scratch — its own nested git repo with the two repo-owned skills committed — via `SYNC_BASE=file:///…` fixture indexes; the real `.claude/skills` is never touched and no network is reached): RED 19 ✗ on the pre-fix script with only its `BASE=` constant pointed at the fixture (`mdex-process-safety` REPLACED with `PWNED` and recorded in the manifest, `local-notes` replaced, `mdex-software-factory` pruned on a poisoned manifest, `http://127.0.0.1:9` reached) → PASS 915/0. The brief's Verify item is §3f(A): an index naming `mdex-process-safety` leaves the tracked directory (`diff -r`) and the manifest (`cmp`) byte-identical. Adjacent cases enumerated: (B) an untracked+unmanaged dir the index names (untouched), a tracked name in a poisoned manifest that the index drops (prune refused, manifest self-heals), a managed skill at a new hash (updated), a new skill with a subdir file (installed), manifest = exactly what was installed; (C) a managed name the index drops is still pruned, a no-op run prints nothing; (D) `http://` base refused before any fetch, unreachable `file://` base keeps cache + manifest, exit 0. A standalone scratch harness with the same fixtures: 19/19 on the fix, 8/19 on the stubbed pre-fix. NOT verified: an actual off-origin redirect (needs a redirecting server — pinned by source shape only) and a git-less host (the manifest guard alone then applies, by construction). Not run: `run_all.sh` — no venue involvement; `#play` posture untouched (no main.mo edit). **D8**: digest pinning / making the sync an explicit command instead of a SessionStart hook is noted on the plan's D8 row; queue task `1788467600` carries the decision. Bookkeeping: brief → done/, README row struck, plan §10 F7 row + §11 filed row marked done, D8 row annotated; merged from claude/seat-1.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
