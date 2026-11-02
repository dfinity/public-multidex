# H-02 — Deploy pre-flight (pinned ids + controller set) and post-install posture read-back; posture reader fails closed on non-canonical spellings; merge gate refuses mapping edits

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 0 (operator machine & pipeline (no canister upgrade)) · findings F8 + F20 + F29-scripts · MEDIUM, MEDIUM, LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-high` (pipeline safety) · `touches: deploy, tests`

**Mechanism.** (a) `scripts/deploy.sh:755-758` installs onto whatever `.icp/data/mappings/
{subnet,engine}.ids.json` names; nothing in the tree holds an expected id (`hmxr2…` appears only
in the mapping), no step reads the target's controllers before `inject_ai_keys` (`:645-670`,
`:832`) or `apply_anti_sybil_settings` (`:771`), and no gate reads `ids.json` (`grep -rn
ids.json scripts tests .githooks` → one comment). `factory_guard.sh` (83cf52c) is seat-identity
keyed and does not cover an operator rollout of a poisoned mapping. (b) `scripts/lib/
targets.sh:153-165` `mdx_posture_of` strips `//` only and matches one spacing-exact regex; a
re-spaced real `#dev` plus a canonical block-comment `#play` decoy reads `play` (tested). All
four gates (`factory.sh:211-236`, `deploy_to_*.sh:13`, `deploy.sh:549-566`, hygiene §6b
`:380-410`) share it; the only `getDeployMode` read on the remote path is inside `cloud_seed`
(`:231`) behind the pools guard, and `mdx_assert_runtime_posture_for_target` (`:88-101`) is
wired only to bot start. (c) `cloud_seed`'s probe (`deploy.sh:216-219`) is an UPDATE call with
stderr discarded and `grep -q record`; failure is indistinguishable from "no pools", so a
gateway hiccup during a routine deploy re-runs ~$7.8M of unbacked genesis mints
(`setTestBalance`, `seedAmmPool`, `seedInsuranceFund`) — the `:439-440` audit that called the
probe "exit-status-safe" was wrong.

**Fix criteria.** (1) `targets.sh` gains a per-environment expected-id table (public ids —
committing them is fine) and `mdx_assert_deploy_target <env>`: resolve every canister name via
icp-cli, refuse on mismatch, then `icp canister status backend` and refuse unless the controller
set equals the operator principal set (`deploy.sh:951` already computes `$PRINCIPAL`). Called
from `deploy_to_subnet.sh`/`deploy_to_engine.sh` and `deploy.sh` before `remote_deploy`.
(2) `remote_deploy` reads `getDeployMode` right after `icp deploy backend` (`:756-758`) and dies
before `apply_anti_sybil_settings`/`inject_ai_keys`/frontend legs unless it equals the source
posture the gate accepted, and unconditionally on `dev`. (3) `mdx_posture_of` strips `/* */`
and string literals, counts `let[[:space:]]+DEPLOY_MODE\b` in any spelling, and refuses unless
that count equals the canonical-match count of 1. (4) `factory.sh merge_gate` refuses any diff
under `.icp/data/mappings/*.ids.json` on a seat branch (mapping edits are operator-lane) and
byte-diffs `main.mo:134-136` against primary main. (5) The seed probe becomes `--query`, checks
exit status, surfaces stderr, parses `vec {}` positively, and dies on anything else; seed-step
`#err`s are surfaced per the `mdx_call_ok` doctrine and the summary states what was minted.

**Verify.** Hygiene §6b gains fixtures: two-space/tab/no-space real `#dev` + block-comment decoy,
`//` inside a preceding string literal, decoy in a Text literal — all must yield empty output and
non-zero. `scripts/factory-selftest.sh` gains a branch fixture editing one mapping id and one
carrying the F20 payload — both refused by `merge-lock acquire` without `FACTORY_FORCE`. With one
mapping id changed, `deploy.sh subnet` must abort before any `icp deploy`/`canister call`; with
the probe made to fail (unreachable gateway), the seed must abort, not mint.

**done 2026-09-04** (task `1788467590`, branch claude/seat-1, on top of `4ef9053`, code commit `d1fb0ea`, merged `a800be8`): scripts + tests only — no canister change, no candid change, no stable-layout change; the bookkeeping half landed in a second seat pass once the H-wave corpus was committed (`59906ee`, task `1788470219`). **Fix 1 (F8, pre-flight)**: `scripts/lib/targets.sh` gains `mdx_expected_id <env> <name>` — the 8 PUBLIC canister ids per remote env (subnet + engine), `mdx_expected_extra_controllers <env>` (ships EMPTY — the deployer alone), and `mdx_assert_deploy_target <env> <identity>`: diffs `.icp/data/mappings/<env>.ids.json` against the table BEFORE any icp call, then resolves every canister via `icp canister status` and refuses unless the id matches and the controller set equals {deployer} ∪ extras; called from `deploy_to_subnet.sh` / `deploy_to_engine.sh` and from both of `deploy.sh`'s remote branches before `remote_deploy`, which itself refuses without `MDX_TARGET_VERIFIED`. **Fix 2 (F20, read-back)**: `deploy.sh` `assert_deployed_posture` reads `getDeployMode --query` right after `icp deploy backend` and dies before `apply_anti_sybil_settings` / `inject_ai_keys` / the frontend legs on `dev`, on a CLI failure, and on any mismatch with the gated source posture. **Fix 3 (F20, reader)**: `mdx_mo_code_image` strips `//`, nested `/* */` and `"…"`/`'…'` literals; `mdx_posture_of` refuses unless the canonical-match count AND the `let DEPLOY_MODE` any-spelling count are both exactly 1. **Fix 4 (merge gate)**: `factory.sh merge_gate` byte-diffs the `DeployMode..IS_DEV` block of both `main.mo` files against main and refuses any `.icp/data/mappings` diff on a seat branch (mapping edits are operator-lane). **Fix 5 (F29-scripts, probe)**: `seed_probe_pools` is a `--query` with exit status checked, stderr surfaced and `(vec {})` parsed positively, dying on anything else; every seed mint goes through `seed_mint` (exit-status gated, failures surfaced and counted) and the summary states what was minted — a failed step fails the seed. **Verified**: `test_deploy_hygiene` RED 56 ✗ on the pre-fix tree → PASS 324 — §6b F20 fixtures (two-space/tab/no-space real `#dev` + block-comment decoy, `//` inside a preceding string literal, Text-literal decoy, multi-line and nested blocks, char-literal quote: 11 read `play` pre-fix, all refused after), §6u the end-to-end `deploy.sh subnet` in a throwaway tree copy against a recording icp stub (a poisoned mapping aborts before ANY canister/deploy call — pre-fix it went straight to `deploy backend`; a clean control reaches the stubbed deploy; a foreign controller and CLI id drift abort), §6v the read-back matrix (8 cases + the diagnostic surfaced), §6w the probe (empty / seeded / failure / junk + the old-shape negative control that mints); `scripts/factory-selftest.sh` 7 FAIL pre-fix (mapping edit, F20 payload, `IS_DEV := true` beside `#play`, a benign edit elsewhere accepted) → ALL PASSED; `deploy.sh local` on the seat venue exit 0 (venue reads dev + seeded). Full `run_all.sh` on the merged tree (`a800be8`, seat #dev venue): 99 passed · 3 failed — `test_walk_scan_budget` a venue-freshness red (green alone after a reseed), `test_bridge_deposit_claim` §14 and `test_market_walks_locked` pre-existing on main (H-02 touches no canister code), filed as `1788485999` and since fixed on main (`915249f`, both fixture physics). Posture: `#play` restored before merge. **Deferred / follow-ups**: the REMOTE rollout half (engine/subnet run of the merged pre-flight) is NOT a seat's — DEFERRED to the operator's folded hardening-wave deploy sitting (`1788469062`); before that first post-H-02 rollout the operator pins the OBSERVED remote controller sets into `mdx_expected_extra_controllers` (`1788482118`, operator lane) or the pre-flight refuses by design. Bookkeeping: brief → done/, README row struck, plan §10 F8/F20/F29-scripts rows + §11 filed row marked done; merged from claude/seat-1.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags (scripts + tests only — no canister, candid or stable change)
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS (99/3 on the merged tree — the 3 reds pre-existing / freshness, see the note; fixed on main since)
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
