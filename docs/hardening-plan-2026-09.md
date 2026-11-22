# Hardening plan — scan findings of 2026-09-02 (48 findings → 37 tasks in 6 waves)

Source: `~/Downloads/dfinity-multidex-main-findings-2026-09-02.md` — 48 findings from the
claude.ai security scan of `dfinity/multidex@main`, dated 2026-08-22 (18) and 2026-09-01 (30).
**Every finding was re-verified against the working tree at `f3fbcf6` (2026-09-03) by symbol
lookup, not by trusting the scan's line numbers** (the scan's anchors drifted 10–60 lines; every
anchor below is the current tree's). Both scan dates postdate the 2026-08-20 fix wave
(`d9c9a1f`…`dc8df8e`, tracker §5), so none of these is a stale re-report of that wave. Where a
finding is *adjacent* to a merged fix or a recorded decision, the relation is stated in the task.

**Headline: all 48 confirmed; none already fixed; none refuted.** Three verdict nuances:

| Finding | Nuance |
|---|---|
| F25 sweep shield-off | The shield bypass is a *recorded decision* (W4-22, `main.mo:2455-2460`); the maker/maker user-vs-user fee consequence was acknowledged in the W4-22 record but never analysed. Needs a decision, not just a fix |
| F18 leaderboard join | Acknowledged in `docs/issue-triage-2026-08.md:246-247, 355-357` as "verification could not close"; no W4-21-style DECISION record existed. Undecided, not unknown — **decided 2026-09-05 (b)** via D9, recorded `bfef256` |
| F45 recycled pool ids | Latent on live: `_seasonArchives` only exists since `d8f4c58` (2026-08-15), *after* the one Phase I→II reset, so Phase I archives are not federated yet. Becomes live at the **next** `resetSeason` |
| F12 exit-set flood | The #52.2 decision (`tasks/archive/1787182539.md`, 2026-08-20) ratified the size-only L3 shear on the premise that "admission throttles USER inflow"; the W1-05 exit-set carve-out (`main.mo:9663-9687`) is exactly what breaks that premise. Reopens a decision with a new fact |
| F41 Bridge interlock | Held one round-trip per call; the operator's retry can slip between two attacker calls — a probabilistic denial, not a hard lock. Still worth the fence |
| F20 posture gate | **Confirmed by test**: `transient let DEPLOY_MODE  : DeployMode = #dev; /* …#play; */` (two spaces) yields `play` from the real `mdx_posture_of` on a scratch fixture; the Text-literal decoy variant alone is refused |

Severity as filed: 4 HIGH · 19 MEDIUM · 25 LOW. F35 (FOK gate has no maker budget) was verified
implicitly by two independent passes over `walkFillable` (no scan budget, no maker budget;
`FOK_SIM_MAKER_BUDGET` exists only on the engine path staged FOKs never reach).

---

## 1. Why the waves are cut by deploy unit

The August queues (`docs/tasks/README.md` W1–W6) were cut by theme. This plan is cut by **what
has to be upgraded together**, because that is now the binding constraint:

1. **Both live targets carry an ACTIVE one-shot migration.** The fossil-sweep migration rolled
   through engine and subnet on 2026-09-03 (task `1788285793`); the *next* upgrade of either
   target **must** be the retirement build (queued `1788285811`) or the upgrade refuses IC0503
   by design. Every backend task below is therefore `after: 1788285811`, and **no wave may
   introduce a new one-shot migration** until that retirement has rolled through both targets.
   None of the 37 tasks needs one — the schema changes are all additive.
2. **EOP refuses stable-field drops and class flips.** Additive stable fields are fine
   (`eop-stable-field-drops-refused`); the four tasks that add one are flagged `stable: +field`
   so their wave is rehearsed on a scratch replica (`stable-migration-rehearsal`). Never add a
   field to an existing stable *record type* (e.g. `DeferredSwap`) — use a side map.
3. **`MM_API_VERSION` is `5.0.0`, additive-only within a major.** Two tasks widen a query
   return type (additive → minor bump); none changes an existing type.
4. **Backend and Bridge upgrade separately**; archive canisters are actor classes and sealed
   archives cannot be re-keyed, so archive-side fixes apply to new spawns only (none needed here).
5. **Season boundary.** F32, F45, F41 only help if they land *before* the next `resetSeason`.
   They form Wave 3 together with the Bridge upgrade.
6. **Scripts-only fixes need no canister upgrade** — but they protect the operator machine and
   the pipeline that performs every later wave, so they are Wave 0 and start now.
7. **Verifier + frontend fixes** are an asset deploy plus a CLI script, independent of the
   backend cadence, and are *requirements* under the transparency doctrine — a parallel track.

Per-wave rollout law (unchanged): seats fix on `#dev` seat venues with red/green pins; full suite
green on `#dev`; posture restored to `#play` before merge; the operator rolls engine first, then
subnet (`never-deploy-prod-unasked`), running each wave's post-deploy checks.

## 2. Wave summary

| Wave | Deploy unit | Tasks | Lead findings | Gate to start |
|---|---|---|---|---|
| **0** | scripts/tests only — no upgrade | H-01…H-04 | F15/F17 keychain, F8/F20/F29 deploy gates, F7 skill sync, F24 tmp names | now; **H-01 includes an immediate operator action** (revoke the existing `unsigned:` grants) |
| **1** | backend upgrade #1 — solvency & book poisoning | H-05…H-17 | F1, F4(+F35), F3, F13, F16, F23, F31, F46, F22a/b, F26, F5-DEX, F30-backend, F29-backend | `1788285811` merged and rolled |
| **V** | frontend asset deploy + CLI (parallel with 1–2) | H-18…H-19 | F9, F10, F11, F21, F30, F44 | now (H-18's tiling rule accepts both `#gap` shapes so it can land before or after H-16) |
| **2** | backend upgrade #2 — matching fairness & release pacing | H-20…H-25 | F14, F19+F38, F22c+F28, F6+F27+F39, F2+F25 | decisions D1, D2 recorded; Wave 1 rolled |
| **3** | Bridge upgrade + backend #3 — season boundary & state growth | H-26…H-36 | F40+F41, F5-Bridge, F32, F45, F37+F43, F47, F48, F12, F36, F42, F33 | decisions D3–D6; **must roll before the next `resetSeason`** |
| **4** | backend upgrade #4 — oracle fan-out | H-37 | F34 | H-11 (F16) rolled; dev stall hook designed |
| **D** | operator decisions (continuous) | D1–D8 | F2/F25, F12, F42, F18, F36, F33, F28 breaker scope, F6 release-info exposure | now |

Priority order *within* a wave is the listing order. The 37 tasks map to the factory's bands as:
H-05, H-06, H-08, H-09, H-01, H-02 → band 01 (security high / pipeline safety);
H-18, H-10–H-17, H-20–H-24, H-26–H-28 → band 02; decisions → band 03; the rest → band 30.

---

## 3. Wave 0 — operator machine & pipeline (no canister upgrade)

### H-01 · Rewrite the keychain helper: no password on argv, no `unsigned:` grant, controller identities excluded — and REVOKE the grants already applied  *(F15 + F17 · MEDIUM ×2)*
`class: security-medium` · `touches: deploy, tests` · `lane: operator` (the revocation half; the rewrite is consumer work)

**Mechanism (current).** `scripts/fix_icp_keychain_prompts.sh:24` reads the login password with
`read -s`, then `:34` loops every identity from `icp identity list` and `:49-53` runs
`security set-generic-password-partition-list -S 'apple-tool:,apple:,unsigned:' -k "$PASS" …`
per item — 200+ spawns (`:18` "~10 seconds") with the password in each child's argv, readable
via `ps`/`KERN_PROCARGS2` by any same-user process and by other local accounts. The `unsigned:`
partition lifts the code-signature gate on every icp-cli item — including the funded
controller/wallet identity `SN_IDENTITY`/`CE_IDENTITY` (`scripts/deploy.sh:943-951`,
`scripts/lib/targets.sh:71-78`) that `docs/deploy-to-subnet.md:96-100` names as sole
controller, deploy identity, archive owner, LP and insurance holder. Triage #10.3
(`docs/issue-triage-2026-08.md:266-267`) records the helper as having been run against that
identity on the operator Mac. The launchd bot fleet does need a prompt-free path for the
*fleet* identity (`targets.sh:127-134`), which is why the helper exists.

**Fix criteria.** (1) The password is never an argv element: drive one `security -i` process
over stdin (or omit `-k` and let it prompt once with the keychain pre-unlocked). (2) Replace
`unsigned:` with the icp binary's designated requirement / `teamid:` partition or an explicit
trusted-application ACL for the resolved `icp` path. (3) Identities are an explicit allow-list;
`SN_IDENTITY`, `CE_IDENTITY`, `WALLET` are excluded unless `--include-controller` is passed.
(4) The script prints the consequence before mutating anything. (5) **Operator action, now,
independent of the rewrite:** re-run the partition-list command against every currently
granted item with the narrowed list so the standing `unsigned:` grant on the controller key is
revoked; then verify an unrelated unsigned process reading an icp-cli item triggers the dialog.

**Verify.** `tests/test_deploy_hygiene.sh` gains `src_lacks '-k "$PASS"'`, `src_lacks 'unsigned:'`
on the script; during a full run `ps -eo args` never contains the password (manual check on the
operator machine, recorded in the task log).

### H-02 · Deploy pre-flight (pinned ids + controller set) and post-install posture read-back; posture reader fails closed on non-canonical spellings; merge gate refuses mapping edits  *(F8 + F20 + F29-scripts · MEDIUM, MEDIUM, LOW)*
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

### H-03 · Skill sync never replaces or prunes a directory it did not install  *(F7 · MEDIUM)*
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

### H-04 · Integration suites stop using fixed sticky-`/tmp` names; hygiene census covers `tests/`  *(F24 · LOW)*
`class: hygiene` · `touches: tests`

**Mechanism.** `tests/test_ai_prompt_guard.sh:59-97` writes `/tmp/aiguard_*.did` with `>` and
reads them back as `--args-file` signed by `alice` (a local controller, exempt from the
`aiComplete` registration gate and rate limiter); `tests/test_oql_guard.sh:47-211`,
`tests/test_archive_hop_isolation.sh:79-80`, `tests/test_concurrency.sh:91-107` same shape. No
`mktemp`, no `noclobber`, no errexit (`tests/_lib.sh:33` sets pipefail only). `scripts/lib/
runfiles.sh:6-24` documents why sticky `/tmp` plants are persistent; hygiene §2 (`:194-201`)
censuses deploy scripts only.

**Fix criteria.** Every scratch file goes under `$MDX_RUN_DIR`/`.run/` (source `runfiles.sh`) or
`mktemp` with a trap; write with `set -o noclobber` or an `[ ! -e ]` check and abort on failure
before any read. Extend §2's census to `tests/*.sh tests/_lib.sh` (exempt `mktemp` templates).

**Verify.** Pre-plant a regular file, a FIFO and a symlink at each old name; the suites neither
follow nor read them and the argument observed by the local replica is the suite's own.

---

## 4. Wave 1 — backend upgrade #1: solvency & book poisoning

All Wave 1 tasks: `after: 1788285811`; `touches: backend, tests` unless stated. No stable-field
changes and no candid changes in this wave, so it can roll as a plain UPDATE on both targets.
Post-deploy checks: `getDeployMode == play`; `test_initial_margin.sh` §F, `test_fok_market.sh`,
`test_unfunded_maker_notice.sh` green on a seat venue built from the rolled sha.

### H-05 · A pool's exposure-reducing fill is bounded so post-fill equity at the worst-case price stays ≥ 0; pool market orders get the taker price bound everyone else has  *(F1 · HIGH)*
`class: security-high`

**Mechanism.** `closePosition` (`main.mo:11563-11620`) stages a `#market` close as the pool for
`|poolNetSize|` at `mark × (1 ∓ maxSlippage)`, 1–25% (`:11589`), with no health gate and
`priceBandCheck` only on the `#limit` branch (`:11585`); the "NO new guards" doctrine
(`:11594-11602`) claims the close "re-defers" — false for pools (see H-07). At release the only
margin gate is `clampToInitialMargin` (`:10161-10245`), whose de-lever escape (`:10203-10216`,
`if (deLeverQty >= quantity) { return #full }`) is *magnitude*-qualified since #49.1
(`d9c9a1f`) but price-blind; the #3a ladder-edge cap is gated on `isSpotMarket` which excludes
pool principals (`:3098-3124`); the users-only ±2% clamp fires only when the AMM is sidelined
(`:3028-3040`). `parkDeferred` sizes an under-funded short close at the cap price
(`:2599-2609`). Liquidation only below 1.15 while a 25% adverse fill exceeds equity below 1.25
(short) / 1.20 (long) — `Types.mo:413-416`. Residual → `deleveragePool` (`:5357-5375`) →
`tryLiquidate` → `#insolvent` → `absorbBadDebt` (`:6932-6949`) against insurance then LPs.
Attack requirement the scan understates: the alt must first take the AMM ladder (~6% of vault
value per side); still within `PLAY_DEPOSIT_CAP_USD` for small vaults. Pinned today by
`tests/test_initial_margin.sh:72-75` §D ("Risk-REDUCING close is always allowed") — which asserts
`#ok` only, so an equity bound does not break it.

**Fix criteria.** (1) In `clampToInitialMargin`, the de-lever portion is released only up to the
quantity for which, at `effLimit`, `collateral_after − debt_after ≥ 0` (fees included); the
remainder re-defers (pool market orders gain the spot re-defer path — coordinate with H-07 so a
re-deferred pool order's pre-borrow lifecycle survives `MAX_REDEFER`). (2) Pool `#market`
orders are subject to the #3a ladder-edge / `mid ± USERS_ONLY_CLAMP_PCT` cap like every other
taker, or `maxSlippage` is derived from current health so the close cannot realise a loss beyond
equity. Closing must stay *always available* (D-none: this is the #52.1 doctrine) — bounded in
price, never refused outright.

**Verify.** `test_initial_margin.sh` §F: pool at health 1.17, AMM side emptied, colluding ask at
the 25% edge, `closePosition(25%)` → either not released or released at a quantity/price
leaving no residual debt; `absorbBadDebt` never reached from a voluntary close
(`test_insurance_fund.sh` assertion). Existing §D stays green.

### H-06 · Any debt-increasing pool action requires fresh marks for the whole collateral basket; the release clamp fails closed on a missing or stale price  *(F23 · MEDIUM)* — `after: H-05`
`class: security-medium`

**Mechanism.** `openPosition` gates `marginPriceFresh(baseToken)` only (`:11229-11231`, the sole
call site) while `BorrowEngine.borrowCheck` (`BorrowEngine.mo:155-202`) values the whole basket
through age-blind `marginPriceLookup` (`:6956-6964`); `clampToInitialMargin` returns `#full` on
`null`/zero oracle (`:10166-10167`). `withdrawMarginPool` (`:11189`) and liquidation
(`:4217`) already use the basket-wide `userMarksFreshAt` (`:4175-4184`) — the gap is an
inconsistency, not a decision (`tests/test_margin_staleness.sh:7-12` pins the F1 contract for the
traded market only).

**Fix criteria.** `openPosition` requires `userMarksFresh(poolPrincipal) and
marginPriceFresh(baseToken)`; `clampToInitialMargin` returns `#none` on a missing/zero/stale
oracle **for the re-levering (`excessQty`) path only**, keeping the de-lever pass-through so
closes remain available on stale marks (H-05's doctrine).

**Verify.** `test_margin_staleness.sh` §5: collateral token A stale-frozen, market B fresh →
`openPosition` on B refused until A refreshes; a staged open whose mark goes stale before release
is clamped `#none`, not `#full`.

### H-07 · A pool order that ends with no staged and no resting remainder repays its idle pre-borrow  *(F31 · LOW, invariant restore)*
`class: security-medium` (it feeds H-05 and H-08)

**Mechanism.** `releaseDeferred`'s `#market` drop arm (`:3265-3278`) calls only
`recordReleaseRejection`; the post-switch repay (`:3296-3300`) is gated on `relQty < d.qty`,
which a `#full` clamp never satisfies; the comment at `:3125-3131` attributing the repay to
`recordReleaseRejection → deleveragePool` is wrong. Every sibling kill path calls
`repayIdlePoolBorrow` (`:4446-4454`). A zero fill at the 1% minimum cap is a real state (AMM
half-spread 20 bps + 0.5 × volRegime, bounded at 50%; users-only fallback with an empty book).
`docs/limit-order-positions-design.md:14-18` says "Cancel repays it" and assumes fills deleverage
— nothing pins the strand as intended.

**Fix criteria.** On any release leaving a pool order with no staged and no resting remainder —
zero fill, or partial fill whose tail is dropped — call `repayIdlePoolBorrow`/`deleveragePool`;
fix the comment. Optionally a periodic reconcile in `runLiquidationBatch` (`:4187ff`) repaying
any pool debt covered by free, non-earmarked funds (this also gives the owner a way out today —
there is no user-facing repay endpoint, `:11035-11040`).

**Verify.** `tests/test_borrow_unwind.sh` new §: `openPosition` `#market` at 1% cap with the
half-spread widened past 1% (or users-only fallback, empty book) → after release `loans` empty,
vault balance restored; a partial fill leaves debt equal only to the filled leg.

### H-08 · The swap `#limitOrder` path enforces `priceBandCheck` like every sibling limit path  *(F3 · HIGH, one line)*
`class: security-high`

**Mechanism.** `executeSwapDirect`'s `#limitOrder` branch (`:13375-13396`) checks
`limitPrice == 0`, `validateNewOrder` (`:13382`), `openOrderCapCheck` (`:13391`, added by
fc89d2c) and parks — no `priceBandCheck` (`:10369`; 100× band + 5% `MARKETABLE_BAND_BPS`
collar, `:10353`), which `placeLimitInner` calls at `:10405`. At release a `#limit` entry under
the fresh ctx executes at its raw limit (`effLimit = d.limitPrice`, `:3027`; #3a excludes
`#limit`). Two accounts print trades at arbitrary prices, set last price / 24h stats, buy
leaderboard rank and level-ladder privileges, and re-poison book depth beyond 100×.

**Fix criteria.** Insert `switch (priceBandCheck(marketId, side, limitPrice)) { case (?e) return
#err(e); case null {} }` before `validateNewOrder` at `:13382` (mirror `placeLimitInner`'s
order). Better: fold the two placement paths onto one choke point.

**Verify.** `tests/test_swap.sh` new §: `swap({mode:#limitOrder})` marketable outside the collar,
and any price outside 100×, rejected with the same string `placeLimitOrder` returns.

### H-09 · Every book-walking simulator has a scan budget; the FOK gate counts every maker it passes and fails closed; public depth queries are bounded  *(F4 · HIGH + F35 · LOW)*
`class: security-high`

**Mechanism.** `crossableDepth` (`:2665-2690`) and `walkFillable` (`:2747-2903`, loop at
`:2795`) iterate `OrderBook.findBestMatchExcluding` (`OrderBook.mo:526-546`, "O(log K +
entries skipped)" *per call*) with a growing exclude set and no scan counter — O(N²) in resting
orders inside the cap, a count attackers inflate (no reservation on resting orders, W4-24; 100
per owner; spend-all placements exempt from min notional). Sinks: `getTakeableDepth` public
query (`:2936-2944`, `#all` budget, caller-chosen `capPrice`), `quoteSwap` (`:13177`), the FOK
gate (`:3053-3055`), the post-only probe (`:3079`, `#base(1)` walks every unfunded maker),
`releaseCrossSwap` (`:3556`). `tickAmm` and `finaliseExpiredPending` are bare self-sends
(`:7560-7561`), not under `hbReady`/`hbRun`; a trap rolls back `removeDeferredExec` so the same
entry re-traps at full cadence — the sibling pass was capped after 2,970 orders trapped 40B
(`:3365-3374`). Separately (F35), the FOK gate compares *depth* only: the engine spends one of
`MAX_MATCH_ITERATIONS_PER_CALL = 256` per maker touched (fills, skips, unfunded cancels), so
~250 unfunded dust makers ahead of real depth pass the gate and the FOK partial-fills — the
outcome `MatchingEngine.mo:153-164` forbids. 6940dcf added ctx exclusions to the walker but no
budget.

**Fix criteria.** (1) `WALK_SCAN_MAX` counter in `walkFillable` and `crossableDepth` counting
every entry visited (skipped, unfunded, shielded, self); the walker returns a `truncated` flag.
(2) The FOK gate's budget equals the engine's per-call iteration cap (the
`FOK_SIM_MAKER_BUDGET` shape): a gate that hits the budget before reaching `d.qty` KILLS (fails
closed), never passes. (3) `getTakeableDepth`/`quoteSwap` clamp the walk to a band around
`refPrice` or the scan cap. (4) Dispatch `tickAmm` and `finaliseExpiredPending` through an async
variant of `hbReady`/`hbRun` (the `armLiquidationDispatch` pattern at `:7564`) so a repeated
trap backs off — record as an extension of W3-08 (D7).

**Verify.** Junk-band fixture (several thousand unfunded resting orders inside the cap): one
release pass and one `getTakeableDepth`/`quoteSwap` complete within a bounded instruction count
(`devSweepCostProbe`); a staged FOK over >256 small funded makers, and over ~250 unfunded makers
ahead of sufficient AMM depth, records a kill with no trade settled (`test_fok_market.sh`);
an injected trap in one market's release leaves other markets serviced on the next beat
(`test_heartbeat_isolation.sh` gains `amm`/`finalise`).

### H-10 · A swept resting order whose owner cannot fund one slice is cancelled with the unfunded-maker notice, and every balance-reducing action re-validates resting orders  *(F13 · MEDIUM)*
`class: security-medium`

**Mechanism.** `ammSweepResting` (`:2367`) cancels a crossed resting order (`:2478`) and
re-submits it as an aggressor with the ORIGINAL timestamp and `null` budget (`:2479-2484`),
then `repointOrderIdentity` (`:2492`); `adjustAffectedUsers` runs only `if (tradesArr.size() >
0)` (`:2503-2509`). The engine treats an unfunded aggressor that is not `best.owner` as a normal
partial — `break matchLoop` with no notice (`MatchingEngine.mo:868-884`) — and re-creates the
full quantity under a fresh id with the old timestamp (`:1020-1024`), which re-passes the
anti-snipe gate. `withdraw`, `fundMarginPool`, `stakeInsurance` never re-validate (all
`adjustAffectedUsers` callers are fill paths). Result per 2 s requote: 100 cancel/create cycles
per account, 50 `stagedReleasedAs` links/s collapsing the 20k retention window
(`STAGED_LINKS_CAP`, `:466-477`), 100 permanent `#orderClosed` rows per reaper pass ≈ 4.3M
archive rows/day per account — feeding H-32's sink. W4-24's own doctrine says an unfunded maker
is removed at first match attempt; this is the one fill path that re-rests it instead.

**Fix criteria.** (1) In `ammSweepResting`, pre-check the swept owner's funding for one slice at
the AMM price (`availableBalance`) and cancel + `onUnfundedMakerNotice` instead of re-submitting;
and/or the engine treats an unfunded aggressor under `aggressorIsMaker` as an unfunded maker
(cancel, no re-rest). (2) `adjustAffectedUsers` runs over the swept-owner set even with zero
trades. (3) `withdraw`/`fundMarginPool`/`stakeInsurance` either run `LiquidityManager.
adjustUserOrders` or `getAvailable` excludes value committed to resting orders — pick per D-none
(W4-24 says no reservation; re-validation on debit is the doctrine-consistent choice).

**Verify.** `test_unfunded_maker_notice.sh` §: an unfunded crossing order is removed on its first
sweep, the owner gets one release-rejection notice, the reaper seals exactly one closure; after
moving the whole balance out, the user's resting orders are shrunk/cancelled.

### H-11 · A USD-quote group that is not itself robust cannot override the pooled aggregate  *(F16 · MEDIUM)*
`class: security-medium` · `touches: backend, tests, docs`

**Mechanism.** `PriceFeed.aggregateByQuote` (`PriceFeed.mo:406-441`) aggregates the two `#usd`
sources (coinbase, coingecko) separately; with n ≤ 2 `trimOutliers` is a no-op and the median is
the mean, so one USD print ~2% off (~1% if the other USD source is 429ing) exceeds
`USDT_DEPEG_ALARM_BPS = 100` (`main.mo:14982`) and the branch returns `{ aggUsd with readings }`
— sourceCount 1–2, below `PRICE_MIN_SOURCES = 3` (`:15539`) — so `applyFreshAggregate`
(`:15925`, `:15953-15973`) falls to the XRC anchor, which `play_start.sh:147-150` leaves
unwired on the shipped posture → `#rejected(… refPrice frozen)` for as long as the misprint
lasts. Frozen mark: no sealed releases, AMM quoting at a stale mid for 60 s then widening, margin
opens refused, liquidations deferred (bad debt accrues), LP deposits refused after 60 s. W3-05
(`docs/tasks/done/W3-05…md`) and `docs/oracle-xrc-fallback-design.md` (Quote-bases bullet)
explicitly assumed an anchor; `tests/PriceFeedQuotes.test.mo:48,62` pin the attacked shape.

**Fix criteria.** The diverged branch may override only when `aggUsd.sourceCount ≥
MIN_ROBUST_SOURCES`; otherwise return the pooled MAD-trimmed aggregate with `diverged = true` so
`refreshMultiSourcePrice` still logs the alarm. Update the design bullet and the W3-05 record.

**Verify.** `PriceFeedQuotes.test.mo`: seven agreeing readings + one USD reading 2% off (other USD
`ok=false`) → priceable aggregate with `sourceCount ≥ 3`; a genuine three-source USD divergence
still overrides. `test_oracle_xrc_fallback.sh`, `test_oracle_time_bases.sh` green.

### H-12 · The direct-swap market cap anchors to the AMM/oracle mid, not the book's best resting order  *(F46 · LOW, trivial half of the anchoring class)*
`class: security-medium`

**Mechanism.** `executeSwapDirect` `#marketOrder` (`:13323-13330`) sets `refPrice =
OrderBook.findBestMatch(…).price` with no pool-mid fallback; `placeMarketOrder` (`:13063-13079`)
was changed to mid-anchor for exactly the "stranded far quote when the ladder is pulled" case
and `quoteSwap` (`:13158-13160`) shows a mid band. For a non-FOK swap the #3a cap re-clamps;
for a FOK swap `isSpotMarket` excludes it (`:3098`) and the users-only clamp never fires on
`processDeferred`, so the FOK executes at the raw far cap. #48.5 (8ad94b6) changed sizing only.

**Fix criteria.** Replace `:13323-13330` with the `placeMarketOrder` pattern (`p.enabled and
p.refPrice > 0 → p.refPrice`, book-best only for markets without an enabled AMM). Optionally
extend #3a to FOK with kill-if-short (touches #48.5 invariants — do it in H-20 instead).

**Verify.** `tests/test_slippage_anchor.sh` gains a `swap(noPartialFill=true)` section: AMM side
empty, one far resting order → the swap cannot fill beyond `mid × (1 ± slippage)`.

### H-13 · Staged cross-swaps count toward the per-owner staged cap and the shed-floor depth  *(F22 a/b · MEDIUM, the cheap half)*
`class: security-medium`

**Mechanism.** `executeSwapCross`'s staged branch (`:13478-13490`) reserves, allocates an id and
inserts into `deferredSwaps` with no `stagedCountOf`/`STAGED_CAP_PER_OWNER` (`:912`, applied in
`parkDeferred` `:2570`) and no `incStagedCount` (`:1036`); `recomputeShedFloor` (`:7377-7378`)
keys on `Map.size(deferredExecs)` only — the shed-floor comment (`:7360-7363`) assumes "the
per-owner staged cap already bounds each caller". ~10,000 staged cross-swaps per account at the
$100k cap, soft-locked and refundable.

**Fix criteria.** Cap check + `incStagedCount` keyed on `scorecardKeyOf` (matching `parkDeferred`,
see `:1030-1033`) in the staged branch; `decStagedCount` in `removeDeferredSwap`;
`recomputeShedFloor` sums `deferredExecs + deferredSwaps`; `getStagedIndexAudit` reconciles both
maps. Document that `getMyStagedCount` now includes cross-swaps (no signature change).

**Verify.** 33 cross-swaps from one account → the 33rd refused, audit consistent; staged
cross-swap depth alone raises `_shedFloorShip`/the staged floor (`test_ship_backpressure.sh`
pattern).

### H-14 · Uptime samples credit only depth the owner could honour at sample time  *(F26 · LOW, cheap)*
`class: hygiene`

**Mechanism.** `sampleUptime` (`:7301-7332`) sums `(quantity − filled) × price` per side from
the order record (`:7316-7317`) with no `availableBalance` check; a player stages $500/side at
±0.9%, waits for release, moves the whole balance into an insurance stake, and keeps L4's
behavioural half (0 bps maker fee + the shield) forever on quotes that can never fill.
`docs/market-maker-program.md:227-231, 298-299` lists the proximity rework as unshipped; the
funding gap is unanalysed.

**Fix criteria.** Cap each side's credited value at the owner's available quote balance (bids) /
available base × price (asks) per market — no walk needed. (The proximity-weighted sampler is a
separate product decision; do not bundle.)

**Verify.** Tier fixture: an account whose available balances cannot back its ±1% quotes never
records a PASS sample, cannot reach L4, and loses L4 once backing moves away.

### H-15 · DEX side of the unbounded-Nat relay: ceiling on `amount`/`seq` before valuation; refusal text never formats a caller-sized bignum  *(F5-DEX · MEDIUM)*
`class: security-medium`

**Mechanism.** `playDepositReserve` (`:6798-6835`) and `creditAndRegister` (`:6409-6436`)
bound only `amount == 0` and format `Nat.toText(v / 100_000_000)` (`:6822-6824`,
`:6420-6423`) plus `Nat.toText(amount)/Nat.toText(seq)` in the divergence refusal
(`:6387-6390`). `.mops/core@2.5.0/src/Nat.mo:30` is `Int.toText` — the per-decimal-digit
bignum loop (`Int.mo:37-60`), Θ(bits²) — so the scan's "unverifiable" dependency assumption is
now verified. A ~100 KB Nat relayed by the Bridge makes the DEX burn its full 40B budget (~20
DTS rounds during which nothing else runs) and trap; the Bridge's catch keeps the write-ahead
(H-27 fixes that side). Reachable by any email-bound player.

**Fix criteria.** Both entry points refuse `amount`/`seq` above a fixed ceiling (2^128, or the cap
in units) before valuation, in instructions independent of bit length; refusal messages clamp
the formatted value to a display ceiling or omit it. Fixing either canister alone closes the
stall; do both (H-27 carries the Bridge half).

**Verify.** `tests/test_play_deposit_cap.sh`: a 100 KB Nat → `#err` in bounded instructions
(`devSweepCostProbe`-style measurement); existing HUGE probe (`:227-236`) stays green.

### H-16 · A merged shed emits a `#gap` event covering the coalesced range  *(F30-backend · LOW)*
`class: security-medium` (tape integrity)

**Mechanism.** `recordGap` (`:8733-8742`) coalesces adjacent tuples, but `shedOldestEvents`
(`:8796-8842`) emits one `#gap {fromSeq; toSeq}` per shed; two L2/L3 sheds inside one archive
outage (spawn blocked, `:8930-8937` retry) leave the archive list with ONE coverage jump
`[g1from, g2to)` and two `#gap` events — and, worse than reported, shed 2 can drop shed 1's
`#gap` event itself (it sits at the front of the post-shed queue; the baseline-bisect loop
`:8811-8818` extends the drop). Both verifiers' exact-range rule then rejects the honest tape
permanently. No test sheds twice (`test_archive_failover.sh` C/F shed once).

**Fix criteria.** When `recordGap` merges, emit `#gap {fromSeq = prev.0; toSeq = gapTo}` (payload
shape unchanged → no candid, no hash-format change). H-18's verifiers accept exact match,
adjacent tiling, or a superset ending at the same `to`, so old tapes still verify.

**Verify.** `test_archive_failover.sh` gains a two-consecutive-sheds-then-verify case: CLI exit 0,
browser green, with the chain-declared gap reported as documented, not tampering.

### H-17 · `#play` refuses repeated genesis mints once the venue is live  *(F29-backend · LOW)*
`class: hygiene`

**Mechanism.** Only `injectHistoricalTrades` is latched on `_ammEverEnabled` (`:797`, `:14312`,
`:17262-17268`); `seedInsuranceFund` (`:12896-12912`) and seed-time `setTestBalance` accept a
repeat. `seedAmmPool` (`:14260-14268`) is also the sanctioned live LP-deposit path for scripts —
do **not** latch it.

**Fix criteria.** Bind `seedInsuranceFund` and the seed-time `setTestBalance` (or a split-out
seed-only method) to the same genesis window; a repeated deploy-time seed then adds no unbacked
supply even when H-02's script guard fails.

**Verify.** On a live seat venue, a second `seedInsuranceFund` returns `#err`; `test_ghsa_round4.sh`
and the seed path in `play_start.sh` stay green.

---

## 5. Wave V — verifier & frontend track (asset deploy + CLI; parallel with Waves 1–2)

### H-18 · Verifier anchoring rework, both mirrors: origin 0 by default, no unanchored exit 0, every segment's certificate must verify, every re-anchor must be justified, tiled `#gap`s accepted  *(F9 + F10 + F11 + F21 + F30-verifier · MEDIUM ×4 + LOW)*
`class: security-medium` · `touches: verifier, frontend, tests, docs`

**Mechanism.**
- F9: `verify_ledger.mjs:466-472` / `ledger.js:275-279` default the origin to the active head's
  `chainStartSeq`, which `ArchiveCanister.mo:197,218-219` sets to that canister's own first seq;
  the successor is anchored at `_activeFirstSeq := shippedSeq` (`main.mo:8778, 9107`). On any
  rolled chain (the live one: g24jr → g55pf) `archives[0].firstSeq > ORIGIN` is inert, so a list
  that omits every sealed segment passes. The stub models `chainStartSeq: 0` with `firstSeq: 2`
  (`tests/fixtures/verify-ledger-stub/stub-agent.js:134,145-150`) — a shape the canister never
  produces — so `test_verify_ledger_gate.sh:94-98` is green against fiction. The honest origin
  is a constant: `performWorldWipe` resets `nextEventSeq := 0` every season.
- F10 (CLI only): the tail-skew concession (`--last` `:437-455`, `--full` `:516-533`) `continue`s
  past the head comparison (`:536-538`) and `validateArchiveCert` (`:542`); `classifyEmptyPage`
  (`:364-376`) skips every probe when the empty seq is the head seq; the genuine certificate is
  then validated and VALID printed, exit 0 — over a walked window never compared to anything
  certified. `test_verify_ledger_gate.sh:79-84` pins `WITHHOLD=2` as the passing control. W2-02
  chose "bound, don't remove"; the bound is on the wrong axis.
- F11 (browser only): `ledger.js:169-174` maps every `Certificate.create` exception to
  `ok:null`; the sealed loop (`:320-327`) throws only on `ok === false`; the verdict
  (`:355-361`) depends on the active head alone. After a real re-anchor (seed `null` at
  `:305-309`) a pre-gap segment is vouched only by its own certificate — which can be garbage.
  The CLI twin `validateArchiveCert` (`verify_ledger.mjs:250-253`) fails hard.
- F21 (both): coverage-jump and re-anchor justification are guarded on
  `archives[i-1].lastSeq.length` (`mjs:489,506`; `ledger.js:292,305`); a served list with an
  unsealed non-final entry makes the tentative re-anchor final with nothing to justify; the CLI
  concession keys on `!a.lastSeq.length` (`:516`), not on being last.
- F30 (both): exact-range rule at `mjs:551` / `ledger.js:331`.

**Fix criteria.** (1) Default `ORIGIN = 0`; a first archive with `firstSeq > 0` must be justified
by a chain-committed `#gap [0..firstSeq)` or an explicit `--expect-start`/`opts.expectStart`;
fix the stub so the successor's head reports `chainStartSeq == firstSeq`; correct the verdict
copy, `docs.js:1375-1380` and the W2-04 record. (2) CLI: on truncation, re-fetch
`getCertifiedHead` (bounded retries) and require the readable tape to reach `headSeq`, or anchor
at a fresh certified head inside the readable window (compare the recomputed hash *at that seq*,
validate *that* certificate); otherwise exit a distinct non-zero "inconclusive" code and never
print VALID / "chain links verified" as covering the walk; both `--full` and `--last`.
(3) Browser: off `isLocalReplicaOrigin()`, any `Certificate.create` exception is `ok:false`
(hard fail) for every segment; green requires `segCertsOk === heads`; `null` reserved for local.
(4) Both: reject a served list where any non-final entry has `lastSeq null` or ranges are not
strictly ascending; push a justification whenever `seed` is nulled at `i > 0` regardless of the
predecessor's shape; limit the CLI concession to `i === archives.length − 1`. (5) Both: accept a
discontinuity equal to one `#gap`, exactly tiled by adjacent `#gap`s, or covered by a single
`#gap` superset ending at the same `to`.

**Verify.** `test_verify_ledger_gate.sh`: realistic stub (successor `chainStartSeq == firstSeq`)
with truncated-list still exit 1; fabricated prefix + withheld head under a genuine certificate
→ non-zero; honest-skew control passes only once anchored (stub "catches up on retry" mode);
unsealed-predecessor + gap tuple → both verifiers fail; `#gap[a,b)+#gap[b,c)` with jump `[a,c)`
verifies, `[a,c)` with only `#gap[a,b)` fails. `frontend_security.test.mjs` gains the
per-segment fail-closed pin. Existing `fabricated-gap`, `bad-cert`, `MDX_STUB_TAIL=1` controls
stay green. Live: `verify_ledger.mjs --full --fold` against the subnet venue exits 0.

### H-19 · CSV exports neutralise leading formula characters; pool names are restricted to a benign charset  *(F44 · LOW)*
`class: hygiene` · `touches: frontend, backend, tests` (the backend filter rides Wave 3)

**Mechanism.** `explorer.js:760-767` `dxToCsv` and `main.js:7880-7905` `archExport` apply
RFC-4180 quoting only. The pool name (`createMarginPool` `:11109-11125`, `MAX_POOL_NAME_LEN =
64` at `:4366`, no charset filter) is the sole player-authored OQL field; `pool`/`position` are
`#controllerOrScoped`, so a controller exporting either entity opens a player's
`=HYPERLINK(...)` in a spreadsheet.

**Fix criteria.** In both CSV builders, cells matching `/^[=+\-@\t\r]/` get a leading `'` and
are always quoted. Backend: `createMarginPool` rejects a leading `=`, `+`, `-`, `@` and control
characters (Wave 3).

**Verify.** Create such a pool, export `pool` rows as a controller, confirm literal text in
Excel/LibreOffice/Sheets; a hygiene `src_has` on the guard regex in both files.

---

## 6. Wave 2 — backend upgrade #2: matching fairness & release pacing

All: `after: 1788285811`, plus the listed intra-wave order. H-23 adds one stable field
(additive) → rehearse this wave on a scratch replica. H-23 widens `getAmmPool` (additive →
`MM_API 5.1.0`). Post-deploy: `test_cross_swap*.sh`, `test_geptor_inflight_guard.sh`,
`test_sealed_model*.sh` green on a seat venue at the rolled sha; live `getReleaseInfo` shows
releases still landing within the staging window.

### H-20 · Every cross-swap leg executes under an absolute cap anchored to that market's mid; sell sizing never divides by the book's best bid  *(F14 · MEDIUM, + F46 release-side)*
`class: security-medium`

**Mechanism.** `releaseCrossSwap` (`:3514`): `buyRef` is mid-anchored with the placeMarketOrder
rationale (`:3546-3554`) but `sellBestBid = OrderBook.findBestMatch(…).price` (`:3557-3560`),
`sizedSellQty = min(amount, absorbUsd / sellBestBid)` (`:3561-3563`), and the sell leg calls
`executeMarketOrderProtected(…, s.maxSlippage, …)` (`:3574-3576`) whose band comes from
`findBestMatch` inside the engine (`MatchingEngine.mo:248-256`). The immediate path
(`:13424-13426`, `:13443-13445`) has no mid anchor on either leg. Any player rests a funded
lowball bid (non-marketable, admitted down to mark/100); whenever the AMM bid side is absent
(cash floor, `_bidsGone`, users-only fallback, no pool, or the ladder consumed earlier in the same
GEPTOR message since `processDeferred` runs before `processDeferredSwaps`) the victim's sell leg
prints at the attacker's price. 2e5384d changed buy-leg sizing only.

**Fix criteria.** `MatchingEngine.executeMarketOrderProtected` gains an optional absolute cap
argument (or callers pre-compute `minPrice`/`maxPrice` from mid) — signature change touching the
five callers (`:3574, :3591, :13424, :13443`, rebalancer ~`:3895`); `releaseCrossSwap` derives
`sellRef` from the sell market's `p.refPrice` (book-best only without an enabled AMM), sizes with
it, and applies the users-only ±2% / ladder-edge clamp when the AMM is sidelined on that side.
If H-21 stages the immediate path, its two anchor sites disappear.

**Verify.** A `test_slippage_anchor.sh` mirror for cross-swaps: AMM bids withdrawn, one far
lowball user bid, a cross-swap released → the lowball bid untouched, outcome "no liquidity within
slippage". `test_cross_swap_sizing.sh`, `test_cross_swap_budget.sh` green.

### H-21 · No player-reachable taker settles inside the caller's own message: the all-or-nothing cross-swap is staged and FOK-checked at release  *(F19 + F38 · MEDIUM + LOW)* — `after: H-20`
`class: security-medium`

**Mechanism.** `executeSwapCross`'s `noPartialFill = true` branch (`:13414-13472`) runs both legs
synchronously under `buildProtectionCtx` (`:13415`), whose `isNonTakeable` (`:10275-10277`)
excludes only the AMM — no fresh-price gate, no sweep-before-release, no tier ordering, no L4
shield (SPEC.md:327 "Nothing matches synchronously"). And the flag is not FOK: both engine calls
pass `noPartialFill = false` (`:13425`, `:13444`), the staged branch has no FOK field, and
`tests/test_cross_swap_atomic.sh` §2 pins a partial `#ok` — a W2-03 atomicity pin, not a
semantics pin (`docs/swap-limit-orders-design.md:73` says "opt-in all-or-nothing"). A naive
`true` on the buy leg after a settled sell would re-open W2-03's settle-then-err.

**Fix criteria.** Remove the immediate branch. Stage with a FOK flag in a **side map**
`swapFok : Map<Nat, Bool>` (mirroring `deferredFok` at `:341`; never a new field on the stable
`DeferredSwap` record at `:514`). At `releaseCrossSwap`, simulate both legs under the release ctx
and budget (`fokFillableDepth` / `crossableDepth(excludeAmm)` on both books) before any balance
moves: full fill of `amount` and full spend of the proceeds, or `#err` with byte-identical
balances. `SwapResult.swapOrderId` is already `?Nat` → no candid change. The client-side
"No partial fulfillment" guard is documented as advisory; the backend is the enforcement point.

**Verify.** Rewrite `test_cross_swap_atomic.sh` §2: thin user-side book on either leg with
`noPartialFill=true` → `#err`, no balance change, no fills on the tape; with a resting user bid
on the sell market, `swap(noPartialFill=true)` returns a staged id and the bid owner's balances
are unchanged until the next GEPTOR pass; `test_sealed_model.sh` green.

### H-22 · Both release passes are paced (per-pass release cap + fill budget, resume next tick) and the requote/release dispatch sites sit behind a failure-streak breaker  *(F22c + F28 · MEDIUM + LOW)* — `after: H-09` (shares the walker's `truncated` flag)
`class: security-medium`

**Mechanism.** `processDeferred` (`:3308-3358`, loop `:3338-3344`) and `processDeferredSwaps`
(`:3495-3510`) release every due entry in one message with no cap, unlike
`processDeferredExpiry` (`MAX_EXPIRY_RELEASES_PER_PASS = 256` at `:540`, `EXPIRY_PASS_FILL_BUDGET`
at `:550`, rationale `:3363-3373`). `processDeferred` runs at the end of `ammRequote` (`:2340`),
called for EVERY pool inside one `tickAmm` message (`:3961-3997`) and in `geptorFetchAndSweep`'s
continuation right after `applyFreshAggregate` (`:3697-3703`), so a trap discards the fetched
mark. Cohort size = identities × `STAGED_CAP_PER_OWNER` (32, one `placeLimitOrdersBulk` each);
the L0/L1 shed floors (2,000/5,000 staged) are the only aggregate bound. No controller method
cancels a single staged swap; only a wipe clears `deferredSwaps`.

**Fix criteria.** One shared budget helper: `processDeferred` and `processDeferredSwaps` stop
after N releases / M settled fills, leave the remainder staged in priority order with the GEPTOR
re-armed, and complete within a bounded instruction count independent of N. `tickAmm` and
`finaliseExpiredPending` dispatched through the async breaker from H-09 (D7). Consider running
the release pass *after* the mark and requote are committed (separate self-send) so a trap never
discards a fetched mark.

**Verify.** Due cohorts of several thousand entries (bulk-staged from ~100 seat identities)
release across passes with nothing dropped; an injected trap in one market's release leaves other
markets' ladders and the fetched mark committed and backs the retry off
(`test_heartbeat_isolation.sh`).

### H-23 · The sealed model keys on fetch DISPATCH time: the anti-snipe gate, the sweep gate, the cross-swap freshness predicate and the owner commit lock all read it  *(F6 + F27 + F39 · MEDIUM + LOW + LOW)* — `stable: +field` on `AMM.Pool` (additive) · `candid: getAmmPool additive → MM_API 5.1.0`
`class: security-medium`

**Mechanism.** `fetchFromSource` stamps `fetchedAtNs = Time.now()` *after* `await
IC.http_request` (`:14450-14451`); `aggSampleNs` is the minimum arrival (`:15895-15903`);
`applyFreshAggregate` writes it to `refPriceUpdatedNs` (`:15947`); `processDeferred` releases on
`d.ts < refPriceUpdatedNs` (`:3339`), `ammSweepResting` the same. The dispatch round is recorded
in `_geptorInFlight` (`:3663`, `armedAt` param of `geptorFetchAndSweep` `:3675`) but never used
for the mark, so an order staged after the providers served the price but before the first
response is delivered releases against a pre-order ladder (F27). `deferredCommitted`
(`:563-567`, 3 s wall clock; premise "~1–2 s release" at `:555-562`) and the inline cross-swap
checks (`:10623`, `:13814`) never consult the arm, so whenever the slowest of eight outcalls
outlasts ~1.5–2 s (the code's own notes: `:3640-3643`, `:15571-15576`) the owner has a free
look and cancels adverse outcomes (F6). `processDeferredSwaps` (`:3502-3505`) checks
`refPriceUpdatedNs > s.ts` but `tickPriceRefresh` (`:16160-16170`) advances the mark without
requoting, and `finaliseExpiredPending` runs before `tickAmm` in the beat (`:7560-7561`), so a
cross-swap can release against a stale ladder (F39) — the comment at `:13482-13484` states the
requote intent. W3-06 chose arrival stamps for the *staleness* walls (correct); for the anti-snipe
purpose the conservative reference is dispatch.

**Fix criteria.** (1) Record the dispatch time (Time.now() before the fan-out's first await; the
GEPTOR's `armedAt`; `tickPriceRefresh` gets its own) and store it in a new additive field on
`AMM.Pool` (`AMM.mo:50` neighbourhood) — the release reference — threaded through
`withRefPrice`, `processDeferred`, `ammSweepResting`, `processDeferredSwaps`,
`isMMShieldedFresh`; the staleness walls keep using arrival stamps. (2) `deferredCommitted` and
the two inline checks refuse cancellation while a `_geptorInFlight` arm with `armedAt > d.ts`
is live within `GEPTOR_INFLIGHT_TTL_NS` (either leg for a cross-swap); cancel is permitted again
once that fetch completes without releasing the entry, the TTL lapses, or expiry passes.
(3) `processDeferredSwaps` requires `p.lastRequoteNs ≥ <release reference> > s.ts`
(`lastRequoteNs` is stamped at `AMM.mo:343`). Whether `getReleaseInfo`'s exposure of the fetch
state should be narrowed is D6 (transparency doctrine likely says keep it).

**Verify.** `test_oracle_time_bases.sh` §4: an entry with `ts` greater than the dispatch time is
held to the next fetch even when responses arrive after it was staged. `test_geptor_inflight_guard.sh`
(`devPoisonGeptorInFlight` plants an arm of chosen age): a cancel 3+ s after staging while the
market's fetch is in flight is refused; the stall exit and the 15 s expiry refund still work;
`test_staged_cancel_refund.sh` adjusted to plant an expired arm. Cross-swap: stamp both legs via
`setAmmRefPrice` without `requoteAmm`, `adminRunDeferredSwaps` → still staged; `requoteAmm` both
→ released. Rehearsed upgrade on a scratch replica (negative control not needed — additive).

### H-24 · L4 shield: a maker's quotes are non-takeable only while a genuine repricing intent is in flight; shielded depth earns neither display weight nor uptime; the sweep honours the shield for non-AMM makers and rates the aggressor maker only against the AMM  *(F2 + F25 · HIGH + LOW)* — `after: D1`, `after: H-14`
`class: security-high` · `stable: +map` if a cumulative shield budget is chosen

**Mechanism.** `placeLimitInner` stamps `mmQuoteStamp`/`mmOwnerStamp` on ANY staged L4 limit
(`:10426-10429`) — no size, price or relevance condition; `isMMShieldedFresh` (`:1173-1178`,
`stamp > refNs`) and `isMMShieldedStale` (`:1180-1185`, bare `MM_STAMP_TTL_NS = 30 s` at `:911`)
gate every release ctx (`:3329`, `:3396-3398`); `clearMmShield` (`:1161`) fires on kills and
cancels only — a landed intent keeps its shield by design (`:2996-2998`; `test_mm_shield_kill_exits.sh`
§E is a *positive* control for landing). A $10 dust limit far from mid always lands, so one
staging per <30 s renews the owner shield forever and one per ~1 s (refPriceUpdatedNs is the
sample time, W3-06) keeps `stamp > refNs` at every pass. `getTakeableDepth` (`:2936-2943`) passes
`null` excl and `sampleUptime` counts shielded quotes, so the phantom book also sustains L4.
`docs/market-maker-program.md:300-302` already lists "staged-then-cancelled orders stamp
freshness (free shield refresh) — charge or exclude them" as unshipped. F25: `sweepCtx`
(`:2444-2471`) sets `isNonTakeable = false` (W4-22 DECISION, `:2455-2460`) and `aggressorIsMaker
= true` (`:2468`) for a *full taker walk* at the swept order's limit (`:2482-2486`), so a
user-vs-user sweep fill settles maker/maker (no taker leg, 2× maker volume both sides —
contradicting the wash guardrail at `MatchingEngine.mo:876-879` and
`docs/market-maker-program.md` guardrail #1) and can take a shielded L4 quote before its staged
reprice lands; W4-22's record (`done/W4-22…md:91-93`) knew the walk "can also hit other users"
and guarded only the resting leg's rate.

**Fix criteria (per D1).** (1) The stamp is written only for an intent that could reprice the
shielded book (notional/price-proximity commensurate with the owner's resting depth on that
market) and lapses when the intent lands, **or** total shielded time per owner/market is bounded
by a cumulative budget per window (new stable map). (2) `getTakeableDepth` threads
`isMMShieldedFresh` into `excl`; `sampleUptime` skips shielded quotes (with H-14). (3) The sweep
walk honours the shield for non-AMM makers (`isNonTakeable = not AMM(o) and isMMShieldedFresh(…)`)
— preserving W4-22's price-improvement rationale for the AMM leg — and the aggressor is
fee-rated maker only when the counterparty is the AMM (ctx predicate replacing the Bool at ctx
field 52; five construction sites `:2444, :3315, :3381, :3522, :10253`); a user-vs-user sweep
fill carries a taker leg with the swept order as taker.

**Verify.** A bot staging dust limits at any cadence cannot keep `isMMShieldedFresh`/`Stale` true
across more than one release pass beyond each intent's landing; a fully shielded two-sided book
reports zero takeable depth and fails the uptime sample; a crossed user-vs-user book re-homed by
the sweep produces no trade with maker roles on both sides and never fills a shielded L4 quote
(`test_mm_shield_kill_exits.sh` §E re-decided per D1; `test_po_sweep_fee.sh`,
`test_volume_credit.sh`, `test_release_priority` green).

### H-25 · The `tickAmm`/`finaliseExpiredPending` breaker and pacing constants are documented as an extension of W3-08  *(docs half of H-09/H-22)*
`class: docs` · `touches: docs` — one paragraph in `docs/tasks/done/W3-08…md` and
`docs/access-prioritization-design.md` recording D7.

---

## 7. Wave 3 — Bridge upgrade + backend #3: season boundary & state growth

**Must roll before the next `resetSeason`.** Bridge tasks (H-26, H-27) are a separate canister
upgrade and can roll first. H-30 adds an additive stable map; H-26 adds a stable `Bool` on the
Bridge → rehearse both. Post-deploy: `test_bridge_write_ahead.sh`, `test_play_deposit_cap.sh`,
a season-reset rehearsal on a seat venue (`resetSeason` completes under a sustained unbound-
principal `devSimulateDeposit` loop; first post-reset pool principal not indexed in any season
archive).

### H-26 · Bridge: a refused admission leaves the stable maps identical to their pre-call state; a wipe-pending fence lets the season wipe complete against a sustained admission stream; ineligible callers never occupy the interlock  *(F40 + F41 · LOW ×2)* — `stable: +Bool` (Bridge)
`class: security-medium` · `touches: bridge, tests`

**Mechanism.** `devSimulateDeposit` (`bridge/main.mo:358-411`): `Map.add(admitting, k)` at
`:370` before any eligibility check (which lives DEX-side in `playBucketFor`, `main.mo:6503`);
write-ahead `admittedUnits`/`ledgerOf` get-or-create (`:169-175`, `:387-389`); the `#err`
rollback (`:397-400`) restores values but deletes no rows — contradicting `:353-354` ("a
refused deposit is never created") — so every unbound keypair leaves two permanent zero rows
per asset. `adminSeasonWipe` (`:443-456`) vetoes on `Map.size(claiming) > 0 or
Map.size(admitting) > 0` (`:451-453`) and `resetSeason` aborts on `#err` (`main.mo:17139-17144`);
a loop of unbound principals holds the venue-global interlock (probabilistically — one round
trip per call). Only `adminSeasonWipe` reclaims rows, destroying every real player's Bridge state.

**Fix criteria.** (1) On the DEX's explicit `#err`, delete an `admittedUnits` row whose restored
value is 0 and a Ledger row that is all-zero (or defer the inserts until `#ok` while keeping the
W3-04 seq semantics); provide a controller purge for already-leaked zero rows. (2) A `wipePending`
stable flag armed by `adminSeasonWipe` refuses NEW claims/admissions and lets the wipe proceed
once the in-flight ones settle; cleared on completion. (3) Eligibility that the Bridge can check
locally is checked before the guard is taken. Do not mirror any of this onto `claim()`'s counter
semantics (W3-04).

**Verify.** `test_bridge_write_ahead.sh` §: `devSimulateDeposit` from an unbound identity on
`#play` leaves `ledgers`/`admittedUnits` sizes unchanged (stats query); a test keeps
`devSimulateDeposit` in flight from an unbound identity while `resetSeason` runs and asserts the
reset completes within a bounded number of attempts.

### H-27 · Bridge: caller-supplied `amount` above a ceiling is refused before any write and no DEX call is made; the catch arm rolls the write-ahead back on a callee-side failure  *(F5-Bridge · MEDIUM)*
`class: security-medium` · `touches: bridge, tests`

**Mechanism.** `:364` bounds `amount == 0` only; `:404-406` keeps the write-ahead on every reject
on W3-04's assumption (`done/W3-04…md:69-71`) that the branch is "not reachable on demand" —
H-15 shows it is. After a trap-kept write-ahead, `devConfirmDeposits` moves N into `confirmed`
and every later `claim` relays N into `creditAndRegister`'s `toText` → the key is wedged until
`adminSeasonWipe`.

**Fix criteria.** Refuse `amount > CEILING` (2^128 or the cap in units) before any state write;
in the catch arm, distinguish `#canister_error`/`#canister_reject` (callee committed nothing →
roll back both writes) from ambiguous transport failures (keep, as today) via `Error.code`.

**Verify.** A 100 KB Nat → `#err` from the Bridge with `pending`/`admittedUnits` unchanged and no
DEX call; an admission whose DEX call traps leaves both at their prior values and a later
`claim` on the key is unaffected (`test_bridge_write_ahead.sh` §4).

### H-28 · The season seal is atomic with its preconditions  *(F32 · LOW)*
`class: security-medium`

**Mechanism.** `resetSeason` (`:17097-17185`): the three completeness gates (`:17103-17124`)
run before `await br.adminSeasonWipe()` (`:17137-17148`); the continuation captures
`finalEventSeq = nextEventSeq`, `chainHead = _chainHead` (`:17151-17178`) from post-await state
and `performWorldWipe(true)` (`:17179`) discards `userEvents`, the journal and both cursors
without shipping. Any player update landing in the Bridge round trip appends events the archive
never receives; the `SeasonRecord` claims a head no archive can reproduce; no `_ledgerGaps`
entry records the loss. No reentrancy guard on `resetSeason`. (The scan's claim that the current
deploy leaves `_bridgePrincipal` null was not re-verified; the race exists on any deployment
wired via `setBridge`.)

**Fix criteria.** A transient `_seasonSealing` flag set before the await makes `emitEventRaw` and
the journal-writing entry points refuse for the duration, cleared on every exit path; the three
gates are re-evaluated after the await and the reset aborts (Bridge wipe documented as
idempotent/retryable) if violated; alternatively capture and wipe in a message with no
intervening await. Any event that cannot be shipped before the seal is refused or recorded as a
ledger gap in the `SeasonRecord`.

**Verify.** Pocket-ic test with a stalled mock Bridge: emit a trade between the Bridge call and
the wipe; assert `SeasonRecord.finalEventSeq == archive headSeq + 1` and `chainHead` equals the
archive's certified head (`test_w4_correctness_batch.sh` neighbourhood).

### H-29 · Pool principals are unique for the lifetime of the archive set; season-archive federation passes only principals the caller owned in that season  *(F45 · LOW, latent → live at the next reset)* — `stable: +map` (fix 2)
`class: security-medium`

**Mechanism.** `performWorldWipe` resets `nextPoolId := 1` (`:16844`) in both arms;
`MarginPools.poolPrincipal` (`MarginPools.mo:57-66`) is a pure function of the id
("globally unique", `:52`); `getMyArchivedEvents` (`:8360-8391`) and `archiveExecute`
(`:17537-17567`) build the caller's principal set from the CURRENT registry and forward it to
any `_seasonArchives` segment, whose `userIndex` (`ArchiveCanister.mo:124-128`) still maps
`poolPrincipal(k)` to the prior season's pool #k `#delta`/`#debtDelta` rows. The comment at
`:8368-8369` ("only ever returns the caller's OWN rows") is false for recycled ids. Live: the
Phase I→II reset (2026-08-01) predates `_seasonArchives` (`d8f4c58`), so Phase I archives are
not federated *yet*; the next reset makes it live.

**Fix criteria.** (1) Delete the `nextPoolId := 1` reset (the counter is already a stable `var`;
64-bit id space) — never fold an epoch into `poolPrincipal` (re-keys live pools, breaks
`poolByPrincipal`). (2) When federating to a `_seasonArchives` segment, pass the human principal
plus only pools recorded as owned by the caller in a frozen per-season owner map (new additive
stable field written by `performWorldWipe(forSeason)`); keep Phase I archives out of the registry
unless that map exists for them.

**Verify.** After `resetSeason` on a seat venue, the first new pool's principal is indexed in no
season segment; create pool #k in season N+1 under a different identity than owned it in season N
and assert `getMyArchivedEvents`/`archiveExecute` against the season-N archive return no rows for
`poolPrincipal(k)`.

### H-30 · Unregistered principals are admitted only to the pre-registration method set; state-writing methods require registration; dead-man fires are capped per pass; the five per-user pool scans use the owner index  *(F37 + F43 · LOW ×2, one choke point)*
`class: security-medium`

**Mechanism.** `inspect`'s unknown-principal branch returns `not IS_PRODUCTION`
(`:9690-9697`), so on `#play` any offline keypair reaches every update method past the shed
floor; the comment's stated blocker ("method-scoping inspect would need the full msg variant
enumeration") is obsolete — W1-05 built that enumeration (`:9581+`). `createMarginPool`
(`:11109`) and `cancelAllAfter` (`:10665`) are `requireAuth` only; `aiComplete`
(`:14700-14709`) inlines the registration check the doctrine names, and there is no shared
`requireRegistered` helper. Consequences: 64 permanent registry records per keypair
(`marginPools`/`poolByPrincipal`/`marginAccounts`, cleared only by `performWorldWipe`
`:16835-16843`); five per-user paths still `Map.entries(marginPools)` — `getMyMarginPools`
`:11710`, `getMyPositionFills` `:11751`, `getMyPoolLiquidations` `:11788`,
`getMyArchivedEvents` ~`:8380`, `archiveExecute` `:17544` — although `poolIdsByOwner`/
`ownedPoolIds` exist (`:4534-4546`; W5-21 converted only `selfAndOwnedPools`); `HEAT_MAX_POOLS =
5_000` counts empty pools (`:4691, :4840, :4969`). `tickDeadman` (`:10727-10738`) walks the whole
map every beat behind `hbReady("deadman", …)` (`:7553-7554`, backoff to 32 s) and fires an
uncapped due cohort with `bumpUserVersion` leaving a permanent `userStatuses` row per throwaway
(`:4329`). The 2026-08-20 dead-man decision (`1787196310`) concerns pool-order scope only and is
untouched.

**Fix criteria.** (1) `inspect`: unknown principals admitted only to `getMyProfile`,
`setUserPreferences`, `getUserPreferences`, `regenerateUsername`, and both
`_internet_identity_sign_in_*` tags (the frontend's entire pre-registration surface;
`creditAndRegister` is inter-canister and unaffected); pinned like W1-05's switch. (2) A shared
`requireRegistered` used by `createMarginPool`, `cancelAllAfter` and `aiComplete`. (3)
`DEADMAN_MAX_FIRES_PER_PASS` mirroring `MAX_EXPIRY_RELEASES_PER_PASS`; skip `bumpUserVersion`
when the principal holds no orders; an operator prune that does not wipe the season. (4) The
five scans resolve through `ownedPoolIds(caller)` + `Map.get`; the heat/risk scans count only
pools with a `loans`/`marginAccounts` entry.

**Verify.** A fresh unregistered principal's `createMarginPool` and `cancelAllAfter` are refused
and, under a raised shed floor, its non-allowlisted updates are shed (`test_load_shed_exits.sh`
pattern); N ≫ cap due switches fire across beats without the `deadman` streak rising; the
instruction cost of the five queries (`devSweepCostProbe`) does not change when unrelated
identities add pools; thousands of empty pools do not set `truncated = true`.

### H-31 · Per-principal trade history costs O(matches + bounded skips); anonymous history queries return before touching the tape; position fills resolve pools via the owner index  *(F48 · LOW)*
`class: hygiene`

**Mechanism.** `OrderBook.getUserTrades` (`OrderBook.mo:1026-1041`) walks the ENTIRE
`store.trades` list forward (up to `TRADES_GLOBAL_TRIM_AT = 750_000`, `main.mo:197-198`) with
two `Principal.equal` per record regardless of `limit`; the `Since`/`SinceId` siblings
(`:1045-1093`) have no scan ceiling. `getMyTradeHistory`/`getMyTradeHistorySince`
(`UserAccount.mo:236-242`) are `query (msg)` with no `requireAuth` — anonymous scans the full
tape for a 20-byte request; `getMyPositionFills` (`:11749-11757`) multiplies by owned pools
(≤ 64) inside the global-pool scan. Public trade feeds were bounded for exactly this
(`MarketData.mo:51-55`).

**Fix criteria.** A transient per-principal trade-id side index rebuilt at init (the
`poolIdsByOwner` shape — not a new field on the `OrderStore` record type), or a lazy reverse walk
with a hard scan ceiling on all three lookups; early return for the anonymous principal;
`getMyPositionFills` one bounded pass over `ownedPoolIds`.

**Verify.** On a full 600k+ tape, `getMyTradeHistory`, `getMyTradeHistorySince(0)`,
`getMyTradesSinceId(0)` for a principal with no trades complete within a fixed small budget; a
64-pool caller's `getMyPositionFills` stays well inside the query limit
(`devSweepCostProbe`).

### H-32 · A single principal's tape inflow through the exit set is bounded without refusing a genuine exit, and a healthy archive never loses history to user-driven inflow  *(F12 · MEDIUM)* — `after: D2`, `after: H-10`
`class: security-medium`

**Mechanism.** The exit set is admitted at every shed floor (`:9683-9687`; W1-05,
`done/W1-05…md`, pinned by `test_load_shed_exits.sh` §3) on the stated premise that "none is a
spam vector" (`:9663-9682`); `withdrawMarginPool` (`:11174`), `unstakeInsurance` (`:12852`),
`withdrawLp` (`:16418`), `withdraw` (`UserAccount.mo:205`) bound only `amount == 0` (W3-10 left
exits unfloored), have no per-principal rate limit (`RateLimit.check` is wired to `aiComplete`
only) and each writes 2–11 permanent events. Drain is fixed: `SHIP_BATCH_MAX = 2_000` (`:8418`)
per `HB_SHIP_NS = 10 s` (`:7125`). Above 200 ev/s the queue grows: floor 1 at 50k (all L0
entries refused), floor 2 at 100k, and the size-only L3 shear at `SHIP_SHEAR_CAP_DEFAULT =
375_000` (`:8462`, `:8907`) drops ≥ 175k events of everyone's unshipped history with a healthy
archive — ~18 min of one client at ~50 `withdrawLp`/s. The #52.2 decision ratified the shear
"strictly above every admission tier … 10+ minutes of sustained pathological *internal-emitter*
EXCESS"; the exit carve-out makes it user-reachable. H-10 removes the other user-driven emitter.

**Fix criteria (per D2).** Preferred, no doctrine change: a per-principal cooldown or
dust-aggregation rule on the four value-moving exits (a genuine exit is never refused, a second
dust exit within the window is coalesced or delayed) and drain that scales with backlog (loop
several `SHIP_BATCH_MAX` awaits per tick when the queue is above `SHED_SOFT_SHIP`); the size-only
shear additionally requires a memory-pressure signal rather than an event count alone.
Alternative (doctrine change): above the HARD ship tier, admit unconditionally only the
liquidation-protective exits (`closePosition`, `cancel*`).

**Verify.** One registered principal issuing dust exits at maximum ingress rate cannot raise
`List.size(userEvents)` above `SHED_SOFT_SHIP`; with the archive acking normally, no user-driven
inflow reaches `shedOldestEvents` (`test_ship_backpressure.sh`, `test_archive_failover.sh` §F);
`test_load_shed_exits.sh` §3 stays honest.

### H-33 · Play-deposit allowance is valued only at a fresh, un-pended mark  *(F47 · LOW)*
`class: hygiene`

**Mechanism.** `markValueUsd` (`:6539-6545`) reads `p.refPrice` with no age bound and no
`pendingPriceJumps` check; consumers `playDepositReserve` (`:6798-6836`) and
`creditAndRegister`'s excess path (`:6409-6436`). `extMarketSwap` (`:5931-5937`) and LP mint
gate on `LP_DEPOSIT_MAX_REF_AGE_NS` (60 s) + pend; margin uses the 5-min wall. A user deposits an
asset while its mark is frozen below market and is charged allowance at the stale value.

**Fix criteria.** A `markValueUsdFresh` for the two admission callers refusing (or re-quoting)
when the mark is older than the bar or the base token sits in `pendingPriceJumps`. Use the
5-min margin wall, not 60 s — quiet markets refresh at ≥ 45 s age on a 30 s cadence, so a 60 s
bar refuses honest deposits between refreshes. Refusal text must be actionable (W3-04 rolls back
on `#err`).

**Verify.** `test_play_deposit_cap.sh` §: `setTestPendingJump` / `setAmmRefPrice` with an old
stamp → `playDepositReserve`/`creditAndRegister` refuse, succeed once the mark refreshes;
`test_bridge_deposit_claim.sh` rollback path green.

### H-34 · Idle pre-borrow is bounded: a leveraged resting entry carries a distance-from-mark bound or a TTL that cancels via `cancelPoolOrderInternal`; a single pool cannot take the whole vault borrow cap  *(F36 · LOW)* — `after: H-07`, `after: D5`
`class: hygiene`

**Mechanism.** `openPosition` pre-borrows at placement (`:11302-11324`; up to 4C at ICPUSD LTV
1.0) and stages with `expiresAtNs = null` (`:11325`); `priceBandCheck` admits a non-marketable
bid down to mark/100; `borrowCheck` caps at 0.5 × CURRENT holdings (`BorrowEngine.mo:176-183`),
so the first borrower may take half the vault's quote and every later quote borrow fails; the
resting bid is exempt from `sweepStaleUserOrders` (`:1738`), `evictOverCap` (`:1780`) and the
dead-man switch (`:10717`, "deliberately SURVIVE" — ratified by `1787196310` for EXITS).
Pre-borrow timing is a recorded design (`docs/limit-order-positions-design.md:12-18`,
borrow-at-fill rejected); the vault-capacity consequence was not weighed.

**Fix criteria.** Scope any bound to ENTRIES that carry debt — never sweep pool exits
(`1787196310`). Cheapest: refuse or re-gate a leveraged `#limit` entry whose price is farther from
the mark than a defined bound; or a TTL routed through `cancelPoolOrderInternal` (`:11650`) using
the existing `orderExpiry` map; plus a per-pool share of `VAULT_BORROW_FRACTION_CAP` in
`borrowCheck`.

**Verify.** A pool bid resting at 1% of the mark cannot hold vault quote past the bound, and other
pools can still borrow after such orders are placed (`test_order_caps_margin.sh`,
`BorrowEngine.test.mo`).

### H-35 · Insurance-penalty yield vests with holding time  *(F42 · LOW)* — `after: D3` · `stable: +map` if cooldown; `candid: getMyInsuranceStake additive → MM_API minor`
`class: hygiene`

**Mechanism.** `stakeInsurance` (`:12750-12850`) / `unstakeInsurance` (`:12852-12886`) have no
lock-up, vesting, entry or exit fee; `accrueInsurancePenalty` → `settleInsuranceArrears`
(`:6901-6925`) credits the share set at that instant; the sweep cadence (`HB_LIQ_NS`, `:7110`),
`getLiquidationSweepHealth` (`:4109`) and `getMarginRiskSummary` (`:4883`) make the event
predictable. The unstake comment (`:12865-12878`) names this exact skim and addressed only the
virtual-offset asymmetry (#48.1). `LP_EXIT_FEE_BPS` (`:15273`) is the sibling precedent.
`test_insurance_staking.sh` §2–3 pins `redeem(mint(A)) == A` and the #48.1 quote == payout, so an
exit fee would break those pins; a cooldown breaks neither.

**Fix criteria (per D3).** An unstake cooldown longer than the liquidation cadence (new stable
`insuranceStakedAt` map; `getMyInsuranceStake` gains `unlockAtNs`), or an accrual-index
distribution. Ledger replay of `#insShareDelta` (`:9355`) must stay reconcilable.

**Verify.** stake → `adminRunLiquidationBatch` → unstake within one heartbeat: the sniper's
payout is no greater than their stake; existing round-trip and quote == payout pins green.

### H-36 · Pre-registration profile/preference records are bounded and purgeable  *(F33 · LOW)* — `after: D4`
`class: hygiene`

**Mechanism.** `getMyProfile` creates a `UserProfile` on first hit after `requireAuth`
(`UserAccount.mo:72-89`); `setUserPreferences` bounds payload only (`:127-139`; triage 1.8 cut
the blob 1000×, not the count); `performWorldWipe` preserves both maps (`:16706`); no purge.
Profile creation must stay pre-registration by design, so H-30's choke point deliberately
allowlists it — F33 needs its own answer.

**Fix criteria (per D4).** A bounded, evictable pre-registration store (LRU by `lastSeen`) promoted
to the permanent map on registration; and/or a sharded sweep (`Shard.step`) dropping profiles
and preferences of principals absent from `registeredUsers` after a grace period, exposed as an
operator tool.

**Verify.** Drive N fresh keypairs through `getMyProfile`/`setUserPreferences`: stable heap growth
is capped; a sweep reduces `Map.size` of both maps without touching registered players.

---

## 8. Wave 4 — backend upgrade #4: oracle fan-out

### H-37 · The mark is applied on a robust quorum or a per-refresh deadline; one slow provider cannot delay the aggregate past the staging window  *(F34 · LOW, structural)* — `after: H-11`, `after: H-23`
`class: architecture` · `touches: backend, tests`

**Mechanism.** `refreshMultiSourcePrice` (`:15988-16005`) dispatches eight futures then awaits
each in order; `fetchFromSource` (`:14435-14446`) has no timeout (the IC API offers none — only
`max_response_bytes`); `_priceRefreshInFlight` (`:15560`, `:16139-16182`) holds across
sequential per-pool refreshes; `_geptorInFlight` TTL 60 s. One provider that trickles its body
controls the cadence of every mark: staged orders miss `DEFERRED_EXPIRY_NS` (15 s) and fall to
the users-only pass with the AMM (~58% of the book) sidelined, FOKs killed, marks one timeout
stale. Motoko cannot select on or abandon an `await`, so this is a restructure: per-source
self-calls record into a per-(asset, epoch) accumulator; the first completion to see
`minSources()` with acceptable dispersion (or a timer deadline well under 15 s) runs
`aggregateByQuote` → `applyFreshAggregate` → requote → release; late readings attach for
observability only; both in-flight guards release on quorum/deadline.

**Fix criteria.** As above. `lastAggregates` type unchanged if readings stay `[Reading]`; no
candid change unless `getPriceFeedStats` gains fields. Needs a dev hook (`devStallSource`) in the
mock route to test on a local replica.

**Verify.** One non-answering source in the fan-out: the mark still advances within the staging
window; `PriceFeed.test.mo` partial-set aggregation; `test_oracle_*.sh` green; live: staged
releases keep landing within ~2 s during a deliberate provider outage.

---

## 9. Wave D — operator decisions (record as `## Operator answer`, then the dependent task runs)

| # | Decision | Feeds | Recommendation |
|---|---|---|---|
| **D1** | L4 shield lifetime: (a) stamp only for commensurate intents + lapse on landing (reverses `test_mm_shield_kill_exits.sh` §E and the `:2996-2998` design comment), or (b) cumulative shielded-time budget per owner/market (new stable map). And: amend W4-22 so the sweep honours the shield for non-AMM makers and rates the aggressor maker only against the AMM | H-24 | (a) + the W4-22 amendment. The shield's stated justification is "the maker HAS a staged intent they could requote"; a $10 dust intent far from mid is not one. Budgets add state and still leave a free window |
| **D2** | Exit-set inflow: per-principal cooldown/dust aggregation + backlog-scaled drain (no W1-05 doctrine change), versus narrowing the always-admitted set above the HARD tier | H-32 | Cooldown + drain scaling. Keeps "exits are never refused" literally true and closes the #52.2 premise gap; also reconsider gating the size-only shear on a memory-pressure signal |
| **D3** | Insurance timing: unstake cooldown (state + additive candid) vs exit fee (breaks two pins) vs accrual index (largest) | H-35 | Cooldown > `HB_LIQ_NS` (e.g. 10 min); cheapest correct fix, sibling of the LP exit fee in spirit |
| **D4** | Pre-registration profile store: bounded LRU vs sharded purge vs accept | H-36 | Sharded purge of profiles absent from `registeredUsers` after 7 days, operator-triggered; profile creation stays free |
| **D5** | Idle pre-borrow bound: distance-from-mark refusal vs TTL vs per-pool borrow share | H-34 | Distance bound (e.g. 20% from mark for leveraged entries) + per-pool share of the vault cap; no sweep touches pool exits |
| **D6** | `getReleaseInfo` exposes `geptorDeadlineNs`/`refPriceUpdatedNs` anonymously (the F6 timing signal) | H-23 | Keep — transparency doctrine; the lock fix removes the value of the signal |
| **D7** | Extend W3-08: dispatch `tickAmm`/`finaliseExpiredPending` through an async breaker (cadence changes under trap) | H-09, H-22 | Yes; the `armLiquidationDispatch` precedent already exists |
| **D8** | Skill sync: keep the unattended SessionStart hook with the manifest guard, or make it an explicit command / pin digests | H-03 | Manifest guard now; explicit `sync` command before `#production` — H-03 landed the manifest + git-tracked guard, the scheme/origin pin and `SYNC_BASE` on 2026-09-04 (`974fcfe`); digest pinning and the explicit-command switch remain this decision's (`1788467600`) |
| **D9** | Leaderboard join (F18): bucket the four published USD columns ($10 / 10 bps) or ratify as a W4-21-style DECISION in `getApiDoc()` (doctrine: the tape is public and principal-attributed by requirement, so the linkage is inherently derivable) | new task after `0288283668` (equity semantics) | Ratify + document, matching W4-21/W6-10.1; if bucketing is chosen it must apply to the *final* equity formula, so it waits on `0288283668` — **decided 2026-09-05 (b)**: ratified, no bucketing; recorded 2026-09-06 on claude/steady-brattain-70eed1 `bfef256` (`getApiDoc()` DECISION paragraph beside W4-21/W6-10.1, `oracle-settlement-and-transparency.md` §4.1, triage §6; Text literal only, no candid change) |

---

## 10. Finding → task index

| F | Sev | Title (short) | Task | Wave |
|---|---|---|---|---|
| 1 | HIGH | Pool market close at 25% edge → socialised bad debt | H-05 | 1 |
| 2 | HIGH | L4 shield renewable with dust | H-24 — **done 2026-09-05** on claude/seat-1 `100c687` (D1 (a): `isRepricingIntent` — notional ≥ 20% of the owner's resting notional on the market, within 200 bps of the mark — gates the stamp; `landMmShield` lapses it on landing; `getTakeableDepth` + `sampleUptime` exclude shielded quotes; no stable change; remote rollout deferred to `1788469062`) | 2 |
| 3 | HIGH | swap #limitOrder bypasses priceBandCheck | H-08 — **done 2026-09-03** on claude/seat-2 `6d3a7a5`, merged `06d3f5a` (gate before `validateNewOrder` in `executeSwapDirect` `#limitOrder`; `test_swap` §4; remote rollout deferred to `1788469062`) | 1 |
| 4 | HIGH | Quadratic depth walks wedge tickAmm/release | H-09 — **done 2026-09-04** on claude/steady-brattain-70eed1 `f02a73d`, merged `2178e8b` (`WALK_SCAN_MAX` 512 on every walker, band-clamped `getTakeableDepth`, scan-capped `quoteSwap`; the D7 half landed with it: `finaliseExpiredPending` via `hbRunAsync`, per-market AMM tick under `hbRun`); docs half H-25 — **done 2026-09-04** `8a334de` (W3-08 §"Extended 2026-09-04") | 1 |
| 5 | MED | Unbounded Nat → quadratic toText; Bridge keeps write-ahead | H-15 (DEX ceiling + toText) — **done 2026-09-04** on claude/exec-a `6b23c03` (`SafeMath.RELAY_CEILING` 2^128 + `natDisplay`, all three Bridge-facing updates) + H-27 (Bridge ceiling) — **done 2026-09-04** on claude/steady-brattain-70eed1 `81b4f14` (the same 2^128) + round-18 `1788465034` (catch-arm rollback, merged `b672db8`) — F5 closed both sides | 1 + 3 |
| 6 | MED | 3 s commit lock not bound to release | H-23 — **done 2026-09-04** on claude/seat-1 `0968f50` | 2 |
| 7 | MED | Skill sync replaces repo-owned skills | H-03 — **done 2026-09-04** on claude/seat-1 `974fcfe` | 0 |
| 8 | MED | Deploy trusts committed id mapping | H-02 — **done 2026-09-04** on claude/seat-1 `d1fb0ea` | 0 |
| 9 | MED | Verifier origin pinned to active chainStartSeq | round-18 `1788465027` (#55.1) | — |
| 10 | MED | CLI tail concession exits 0 unanchored | H-18 — **done 2026-09-04** on claude/seat-2 `2dbeb47`, merged `54cb3d6` | V |
| 11 | MED | Browser ignores sealed-segment cert failure | round-18 `1788465028` (#55.3) | — |
| 12 | MED | Exit-set flood reaches L3 shear | H-32 (+D2) — **done 2026-09-05** on claude/seat-3 `08972bb` (per-principal dust-coalescing window on the four value-moving exits, exits never refused; backlog-scaled ship burst; the L3 shear gated on memory pressure; `test_exit_coalesce.sh`, `test_archive_failover` §F; remote rollout deferred to `1788469062`, `wasm_memory_threshold` → `1788636215`) | 3 |
| 13 | MED | Unfunded crossing orders re-homed every 2 s | H-10 — **done 2026-09-04** on claude/exec-a `bd40337` | 1 |
| 14 | MED | Cross-swap legs anchor to book best | H-20 — **done 2026-09-04** on claude/steady-brattain-70eed1 `8abfc14` (engine `priceCap`; both release legs + the immediate FOK legs mid-anchored; sell sizing by `max(mid, bestBid)`) | 2 |
| 15 | MED | Keychain helper: password on argv | H-01 — **done 2026-09-04** on claude/seat-2 `da1160e` | 0 |
| 16 | MED | One USD provider freezes the mark | round-18 `1788465030` (H-11 superseded) | — |
| 17 | MED | Keychain helper: `unsigned:` partition | H-01 — **done 2026-09-04** on claude/seat-2 `da1160e` (rewrite; the standing grants are revoked under H-01b) | 0 |
| 18 | MED | Leaderboard columns re-join username→principal | D9 — **decided 2026-09-05 (b)**, recorded 2026-09-06 on claude/steady-brattain-70eed1 `bfef256` (derivable by design; columns stay exact, no bucketing; `getApiDoc()` + transparency doc §4.1 + triage §6) | D |
| 19 | MED | Immediate cross-swap bypasses sealed release | H-21 — **done 2026-09-04** on claude/steady-brattain-70eed1 `920fcd4` (the immediate branch retired; every cross-swap stages and releases through the sealed pipeline) | 2 |
| 20 | MED | Posture gate spacing-exact regex | H-02 — **done 2026-09-04** on claude/seat-1 `d1fb0ea` | 0 |
| 21 | MED | Re-anchor honoured with lastSeq null predecessor | H-18 — **done 2026-09-04** on claude/seat-2 `2dbeb47`, merged `54cb3d6` | V |
| 22 | MED | Cross-swap staging uncapped; release unpaced | H-13 (a/b) — **done 2026-09-04** on claude/seat-1 `d5d7032` + H-22 (c) — **done 2026-09-04** on claude/steady-brattain-70eed1 `be7d829` (`MAX_RELEASES_PER_PASS` 256 / `RELEASE_PASS_FILL_BUDGET` 1,024, one `ReleaseBudget` helper over `processDeferred` and `processDeferredSwaps`; remainder staged in priority order, GEPTOR re-armed, tick/finalise resume); docs half H-25 — **done 2026-09-04** `8a334de` | 1 + 2 |
| 23 | MED | Borrow freshness covers only traded token | H-06 | 1 |
| 24 | LOW | Suites use fixed sticky-/tmp names | H-04 — **done 2026-09-04** on claude/exec-a, merged `558ed17` | 0 |
| 25 | LOW | Sweep re-home maker/maker, shield off | H-24 — **done 2026-09-05** on claude/seat-1 `100c687` (D1 yes: `ProtectionCtx.aggressorRole = #swept({ makerVs })` — maker only vs the AMM, a user-vs-user sweep fill has a taker leg; `sweepCtx.isNonTakeable` honours the shield for non-AMM makers) | 2 |
| 26 | LOW | Uptime counts unfundable quotes | H-14 — **done 2026-09-04** on claude/exec-a `42a0099` (per-market `getAvailable` budgets in `sampleUptime`, quote for bids / base at the order's price for asks) | 1 |
| 27 | LOW | Anti-snipe keyed to arrival not dispatch | H-23 — **done 2026-09-04** on claude/seat-1 `0968f50` | 2 |
| 28 | LOW | processDeferred unpaced; tickAmm outside breaker | H-22 (+H-09 — **done 2026-09-04** `2178e8b`: the tickAmm/finalise breaker half, D7) — **done 2026-09-04** on claude/steady-brattain-70eed1 `be7d829` (the pacing half, plus the GEPTOR finalizer requoting WITHOUT the release pass while `hbStreakOf("amm:<mkt>")` > 0 — a tripped market's fetched mark always commits; `test_heartbeat_isolation.sh` §7); docs half H-25 — **done 2026-09-04** `8a334de` (W3-08 §"Extended 2026-09-04" + access-prioritization-design §6 "Landed (D7)") | 2 |
| 29 | LOW | Seed probe fails open | H-02 (scripts) — **done 2026-09-04** on claude/seat-1 `d1fb0ea` + H-17 (backend) — **done 2026-09-04** on claude/exec-a `241ce8b` (`seedInsuranceFund` genesis-bound on #play) + decision `1788529484` — **decided 2026-09-06** (a)+(c), landed on claude/seat-1: `setTestBalance`/`fundArbitrageur` RATIFIED live-on-#play (absolute SET, controller-only, extNetFlow-recorded; refused by posture on #production), `bulkSetTestBalances` genesis-bound on #play (`lib/Genesis.mo`, `tests/Genesis.test.mo`, hygiene §6d), split-out (b) not adopted; recorded in `getApiDoc` + `docs/deployment-modes.md` "The genesis window" — **F29-backend CLOSED** | 0 + 1 |
| 30 | LOW | Two sheds, one jump, two #gaps | H-16 (backend) + round-18 `1788465029` (verifiers) — **done 2026-09-04**: backend landed by `3de535e` (`1788469743`), verifiers by `a2e669d` (`1788465029`); H-16 closed as verified-against-the-brief on claude/steady-brattain-70eed1 (no code change) | 1 |
| 31 | LOW | Pool #market zero-fill keeps pre-borrow | H-07 — **done 2026-09-04** on claude/seat-2 `ee761bc` | 1 |
| 32 | LOW | resetSeason gates before Bridge await | round-18 `1788465019`, **merged `46c9416`** (H-28 superseded) | — |
| 33 | LOW | Unregistered profile records unbounded | H-36 (+D4) — **done 2026-09-05** on claude/seat-1 `371b5f5` (D4 (a′): hard cap `PREREG_CAP` 10,000 at write time, LRU-evict unregistered via `lib/PreReg.mo`; heartbeat `prereg` expiry 7 d, no operator tool; promotion at all four registration sites; one additive stable record; candid additive; remote rollout deferred to `1788469062`) | 3 |
| 34 | LOW | One stalling provider delays every refresh | H-37 — **done 2026-09-04** on claude/seat-1 `558da0b` | 4 |
| 35 | LOW | FOK gate has no maker budget | H-09 — **done 2026-09-04** on claude/steady-brattain-70eed1 `f02a73d`, merged `2178e8b` (`FOK_GATE_ITER_BUDGET` = the engine's 256-iteration cap; the gate kills when the budget runs out before the quantity) | 1 |
| 36 | LOW | Far-off pool bid locks vault quote | H-34 (+D5) — **done 2026-09-05** on claude/seat-3 `ab917b0` (D5 decided (d): no placement-time borrow at all — a resting entry holds zero vault debt, the fill borrows exactly its quantity, an unlendable vault fails the fill closed; `test_initial_margin.sh` §G; remote rollout deferred to `1788469062`) | 3 |
| 37 | LOW | createMarginPool by unregistered keypairs; O(global) scans | H-30 — **done 2026-09-04** on claude/seat-2 `98400e8`, merged `4eafd35` | 3 |
| 38 | LOW | Cross-swap noPartialFill not FOK | H-21 — **done 2026-09-04** on claude/steady-brattain-70eed1 `920fcd4` (`swapFok` side map + `fokCrossGate` at release: both legs simulated, full fill + full proceeds absorbed or a recorded kill with nothing settled) | 2 |
| 39 | LOW | Cross-swap fresh-mark ≠ fresh ladder | H-23 — **done 2026-09-04** on claude/seat-1 `0968f50` | 2 |
| 40 | LOW | Refused devSimulateDeposit leaves rows | H-26 — **done 2026-09-04** on claude/exec-a `52fcbd6` (MERGE PENDING — operator: primary README dirty) | 3 |
| 41 | LOW | Bridge interlock holdable by anyone | H-26 — **done 2026-09-04** on claude/exec-a `52fcbd6` (MERGE PENDING — operator) | 3 |
| 42 | LOW | Insurance stakers front-run the sweep | H-35 (+D3) — **done 2026-09-05** on claude/seat-2 `4446e86` | 3 |
| 43 | LOW | Dead-man armable by unregistered; uncapped cohort | H-30 — **done 2026-09-04** on claude/seat-2 `98400e8`, merged `4eafd35` | 3 |
| 44 | LOW | CSV export formula injection | H-19 | V (+3) |
| 45 | LOW | Recycled pool ids read prior-owner archive rows | H-29 — **done 2026-09-04** on claude/exec-a, merged `b7705d4` | 3 |
| 46 | LOW | Direct-swap FOK cap anchored to book best | H-12 — **done 2026-09-04** on claude/steady-brattain-70eed1 `56998a8` (the cross-swap legs + the #3a-for-FOK option stay with H-20) | 1 |
| 47 | LOW | Deposit allowance at ungated marks | H-33 | 3 |
| 48 | LOW | Trade-history full-tape scans | H-31 — **done 2026-09-04** on claude/steady-brattain-70eed1 `8b91463` (transient per-principal fills index at the refreshRolling24h choke point; every "my fills" read O(own) — measured 5.7×10^3 vs a 5.0×10^8 walk at a 600k tape) | 3 |

## 11. Filing into the factory

One queue task per H-row (thin `docfile:` pointing here, section anchor in the gist), classes
as listed, `after: 1788285811` on every backend task, `lane: operator` on H-01's revocation
half, H-02's expected-id table seeding, and every D-row. File Wave 0 and Wave 1 first, then
Wave V; Wave 2 after D1 is answered; Wave 3 after D2–D5. The three verification-only claims
that could not be closed from the tree are recorded inside the tasks (F28/F22 trap threshold
unmeasured — the fix does not depend on it; F32's deploy-wiring claim; F41's probabilistic
hold). Outward: none of these has a public issue or advisory yet; the mirror row rides the next
drop per `multidex-outward-batch-2026-08` — nothing outward before the push.

### Round-18 overlap — read before claiming anything here

Forty minutes before this set was filed, the operator session triaged public issues #53/#54/#55
and GHSA-63hp (OhShii round 18) into 32 tasks (`1788465019`–`1788465056`, tracker §8). Four of
those cover findings in this scan; the dispositions, applied 2026-09-03 22:45:

| This plan | Round-18 task | Disposition |
|---|---|---|
| H-28 (F32 season seal) | `1788465019` — **merged `46c9416`** (`_seasonSealing` latch + honest post-await re-seal, `tests/test_season_seal.sh`) | H-28 **superseded**; brief removed |
| H-11 (F16 USD-group veto) | `1788465030` (pooled trim stays primary when the USD group is below the floor + `Float.toInt` guard) | H-11 **superseded**; H-37 re-gated on `1788465030` |
| H-18 (F9/F10/F11/F21/F30) | `1788465027` (F9), `1788465028` (F11), `1788465029` (F30 tiling, exact merged match) | H-18 **narrowed to F10 + F21**, `after:` all three + `1788465046` (same stub) |
| H-27 (F5 Bridge) | `1788465034` (catch-arm rollback + pre-confirm reservation check) | H-27 **narrowed to the amount ceiling**, `after:` 034; H-26 also `after:` 034 |
| H-16 (F30 backend) | `1788465029` refuses a superset, so the coalesced emit is what makes the chain-collected set cover the jump when shed 2 drops shed 1's `#gap` | kept, note added |
| H-02, H-23, H-29, H-30, H-32 | `1788465035`/`043` (deploy.sh), `036` (oracle writers), `055` (season archives), `021`/`032` (archiveExecute, inspect predicate) | kept, `after:` edges added so shared files are edited once |

### Filed 2026-09-03

Briefs: one `docs/tasks/H-NN-*.md` per H-row (this document stays the overview; the per-task brief is what a seat closes). Queue ids (runtime `tasks/` state, gitignored):

| Task | id | Title |
|---|---|---|
| ~~H-01~~ | `1788467588` — **done 2026-09-04** on claude/seat-2 `da1160e` (the revocation half → H-01b `1788467589`, operator) | H-01: Rewrite the keychain helper: no password on argv, no `unsigned:` grant, controller identities excluded — and REVOKE the grants already applied |
| H-01b | `1788467589` | OPERATOR: revoke the standing `unsigned:` partition grant on the icp-cli keychain items on the controller Mac (F17, independent of the H-01 rewrite) |
| ~~H-02~~ | `1788467590` — **done 2026-09-04** on claude/seat-1 `d1fb0ea` (remote rollout rides the deploy sitting `1788469062`; observed controller sets to pin first → `1788482118`) | H-02: Deploy pre-flight (pinned ids + controller set) and post-install posture read-back; posture reader fails closed on non-canonical spellings; merge gate refuses mapping edits |
| ~~H-03~~ | `1788467591` — **done 2026-09-04** on claude/seat-1 `974fcfe` (digest pinning / explicit `sync` command → D8 `1788467600`) | H-03: Skill sync never replaces or prunes a directory it did not install |
| ~~H-04~~ | `1788467592` — **done 2026-09-04** on claude/exec-a, merged `558ed17` | H-04: Integration suites stop using fixed sticky-`/tmp` names; hygiene census covers `tests/` |
| D1 | `1788467593` | D1 · DECISION: L4 shield lifetime - stamp only for commensurate intents that lapse on landing, or a cumulative shielded-time budget; and amend W4-22 so the sweep honours the shield for non-AMM makers (F2 HIGH + F25) |
| D2 | `1788467594` | D2 · DECISION: bound exit-set tape inflow per principal + backlog-scaled ship drain (no W1-05 doctrine change) vs narrowing the always-admitted set above the HARD tier (F12) |
| D3 | `1788467595` | D3 · DECISION: insurance-penalty timing skim - unstake cooldown (state + additive candid) vs exit fee (breaks two pins) vs accrual index (F42) |
| D4 | `1788467596` | D4 · DECISION: pre-registration profile/preference store - bounded LRU, sharded purge of unregistered principals, or accept the growth (F33) |
| D5 | `1788467597` | D5 · DECISION: bound the idle pre-borrow on far-off leveraged pool entries - distance-from-mark refusal, TTL via cancelPoolOrderInternal, or per-pool share of the vault borrow cap (F36) |
| D6 | `1788467598` | D6 · DECISION: keep getReleaseInfo exposing geptorDeadlineNs / refPriceUpdatedNs anonymously once the commit lock is bound to the fetch (F6 timing signal) |
| D7 | `1788467599` | D7 · DECISION (record only): extend W3-08 - dispatch tickAmm and finaliseExpiredPending through an async failure-streak breaker (F4/F28) |
| D8 | `1788467600` | D8 · DECISION (record only): skill sync stays an unattended SessionStart hook with the manifest guard, or becomes an explicit command / digest-pinned before #production (F7) |
| ~~D9~~ | `1788467601` — **done 2026-09-06** on claude/steady-brattain-70eed1 `bfef256` (decided (b) 2026-09-05: ratified as a DECISION in `getApiDoc()` + the transparency doc; no bucketing, no code change to the columns) | D9 · DECISION: leaderboard username->principal join via exact e8 columns - bucket the published USD/bps columns, or ratify as a W4-21-style DECISION in getApiDoc (F18) |
| ~~H-05~~ | `1788467602` — **done 2026-09-04** on claude/seat-3 `1e02010` (remote rollout → the operator's deploy sitting `1788469062`) | H-05: A pool's exposure-reducing fill is bounded so post-fill equity at the worst-case price stays ≥ 0; pool market orders get the taker price bound everyone else has |
| ~~H-06~~ | `1788467603` — **done 2026-09-04** on claude/seat-3 `3c71743` (remote rollout → the operator's deploy sitting `1788469062`; the `parkDeferred` cap-price trim → `1788557389`) | H-06: Any debt-increasing pool action requires fresh marks for the whole collateral basket; the release clamp fails closed on a missing or stale price |
| ~~H-07~~ | `1788467604` — **done 2026-09-04** on claude/seat-2 `ee761bc` | H-07: A pool order that ends with no staged and no resting remainder repays its idle pre-borrow |
| ~~H-08~~ | `1788467605` — **done 2026-09-03** on claude/seat-2 `6d3a7a5`, merged `06d3f5a` | H-08: The swap `#limitOrder` path enforces `priceBandCheck` like every sibling limit path |
| ~~H-09~~ | `1788467606` — **done 2026-09-04** on claude/steady-brattain-70eed1 `f02a73d`, merged `2178e8b` (the D7 breaker half — `finaliseExpiredPending` via `hbRunAsync`, per-market AMM tick — landed with it; remote upgrade DEFERRED to the deploy sitting `1788469062`) | H-09: Every book-walking simulator has a scan budget; the FOK gate counts every maker it passes and fails closed; public depth queries are bounded |
| ~~H-10~~ | `1788467607` — **done 2026-09-04** on claude/exec-a `bd40337` (pool-debit re-validation → `1788520599`) | H-10: A swept resting order whose owner cannot fund one slice is cancelled with the unfunded-maker notice, and every balance-reducing action re-validates resting orders |
| ~~H-11~~ | `1788467608` superseded → `1788465030` | H-11: A USD-quote group that is not itself robust cannot override the pooled aggregate |
| ~~H-12~~ | `1788467609` — **done 2026-09-04** on claude/steady-brattain-70eed1 `56998a8` (cross-swap legs / #3a-for-FOK → H-20 `1788467617`) | H-12: The direct-swap market cap anchors to the AMM/oracle mid, not the book's best resting order |
| ~~H-13~~ | `1788467610` — **done 2026-09-04** on claude/seat-1 `d5d7032` (F22c → H-22 `1788467619`) | H-13: Staged cross-swaps count toward the per-owner staged cap and the shed-floor depth |
| ~~H-14~~ | `1788467611` — **done 2026-09-04** on claude/exec-a `42a0099` | H-14: Uptime samples credit only depth the owner could honour at sample time |
| ~~H-15~~ | `1788467612` — **done 2026-09-04** on claude/exec-a `6b23c03` | H-15: DEX side of the unbounded-Nat relay: ceiling on `amount`/`seq` before valuation; refusal text never formats a caller-sized bignum |
| ~~H-16~~ | `1788467613` — **done 2026-09-04** on claude/steady-brattain-70eed1 (code credit `3de535e` / `1788469743`; verified against the brief on `2cc268f`, no code change) | H-16: A merged shed emits a `#gap` event covering the coalesced range |
| ~~H-17~~ | `1788467614` — **done 2026-09-04** on claude/exec-a `241ce8b` (seed-time `setTestBalance` → decision `1788529484` — **decided 2026-09-06** (a)+(c), landed on claude/seat-1: `setTestBalance`/`fundArbitrageur` ratified live, `bulkSetTestBalances` genesis-bound; F29-backend closed) | H-17: `#play` refuses repeated genesis mints once the venue is live |
| ~~H-18~~ | `1788467615` — **done 2026-09-04** on claude/seat-2 `2dbeb47`, merged `54cb3d6` (the narrowed F10 + F21 scope; the subnet `--full --fold` run DEFERRED to the deploy sitting `1788469062`) | H-18: Verifier anchoring rework, both mirrors: origin 0 by default, no unanchored exit 0, every segment's certificate must verify, every re-anchor must be justified, tiled `#gap`s accepted |
| ~~H-19~~ | `1788467616` — **done 2026-09-04** on claude/seat-3 `6c36017` | H-19: CSV exports neutralise leading formula characters; pool names are restricted to a benign charset |
| ~~H-20~~ | `1788467617` — **done 2026-09-04** on claude/steady-brattain-70eed1 `8abfc14` (the #3a-for-FOK kill-if-short option not needed: the FOK paths kill at their mid-anchored cap; H-21 retires the immediate-path anchor sites when it stages that path) | H-20: Every cross-swap leg executes under an absolute cap anchored to that market's mid; sell sizing never divides by the book's best bid |
| ~~H-21~~ | `1788467618` — **done 2026-09-04** on claude/steady-brattain-70eed1 `920fcd4` (H-20's two immediate-path anchor sites retired with the branch; the seed-time ETH fallback drift seen on the seat venue filed as `1788527364`) | H-21: No player-reachable taker settles inside the caller's own message: the all-or-nothing cross-swap is staged and FOK-checked at release |
| ~~H-22~~ | `1788467619` — **done 2026-09-04** on claude/steady-brattain-70eed1 `be7d829` (pacing + the finalizer breaker gate; remote upgrade DEFERRED to the Wave 2 rollout) | H-22: Both release passes are paced (per-pass release cap + fill budget, resume next tick) and the requote/release dispatch sites sit behind a failure-streak breaker |
| ~~H-23~~ | `1788467620` — **done 2026-09-04** on claude/seat-1 `0968f50` (`releaseRefs` side map, not an `AMM.Pool` field; `getAmmPool` unchanged, no MM_API bump) | H-23: The sealed model keys on fetch DISPATCH time: the anti-snipe gate, the sweep gate, the cross-swap freshness predicate and the owner commit lock all read it |
| ~~H-24~~ | `1788467621` — **done 2026-09-05** on claude/seat-1 `100c687` (D1 (a) + the W4-22 amendment; no stable-layout change; remote upgrade DEFERRED to the Wave 2 rollout `1788469062`) | H-24: L4 shield: a maker's quotes are non-takeable only while a genuine repricing intent is in flight; shielded depth earns neither display weight nor uptime; the sweep honours the shield for non-AMM makers and rates the aggressor maker only against the AMM |
| ~~H-25~~ | `1788467622` — **done 2026-09-04** on claude/steady-brattain-70eed1 `8a334de` (docs only: W3-08 §"Extended 2026-09-04 — D7" + design §6 "Landed"; hygiene PASS) | H-25: The `tickAmm`/`finaliseExpiredPending` breaker and pacing constants are documented as an extension of W3-08 |
| ~~H-26~~ | `1788467623` — **done 2026-09-04** on claude/exec-a `52fcbd6` (MERGE PENDING — operator) | H-26: Bridge: a refused admission leaves the stable maps identical to their pre-call state; a wipe-pending fence lets the season wipe complete against a sustained admission stream; ineligible callers never occupy the interlock |
| H-27 | `1788467624` | H-27: Bridge: caller-supplied `amount` above a ceiling is refused before any write and no DEX call is made; the catch arm rolls the write-ahead back on a callee-side failure |
| ~~H-28~~ | `1788467625` superseded → `1788465019`/`46c9416` | H-28: The season seal is atomic with its preconditions |
| ~~H-29~~ | `1788467626` — **done 2026-09-04** on claude/exec-a, merged `b7705d4` | H-29: Pool principals are unique for the lifetime of the archive set; season-archive federation passes only principals the caller owned in that season |
| ~~H-30~~ | `1788467627` — **done 2026-09-04** on claude/seat-2 `98400e8`, merged `4eafd35` | H-30: Unregistered principals are admitted only to the pre-registration method set; state-writing methods require registration; dead-man fires are capped per pass; the five per-user pool scans use the owner index |
| ~~H-31~~ | `1788467628` — **done 2026-09-04** on claude/steady-brattain-70eed1 `8b91463` (index, not a scan ceiling — no history is lost to a budget; the legacy walks stay as the probe's negative control) | H-31: Per-principal trade history costs O(matches + bounded skips); anonymous history queries return before touching the tape; position fills resolve pools via the owner index |
| ~~H-32~~ | `1788467629` — **done 2026-09-05** on claude/seat-3 `08972bb` (remote rollout → the operator's deploy sitting `1788469062`) | H-32: A single principal's tape inflow through the exit set is bounded without refusing a genuine exit, and a healthy archive never loses history to user-driven inflow |
| ~~H-33~~ | `1788467630` — **done 2026-09-04** on claude/seat-3 `1bc445c` | H-33: Play-deposit allowance is valued only at a fresh, un-pended mark |
| ~~H-34~~ | `1788467631` — **done 2026-09-05** on claude/seat-3 `ab917b0` (D5 option (d): BORROW AT FILL — the brief's (a)/(b)/(c) superseded; remote rollout → the operator's deploy sitting `1788469062`) | H-34: Idle pre-borrow is bounded: a leveraged resting entry carries a distance-from-mark bound or a TTL that cancels via `cancelPoolOrderInternal`; a single pool cannot take the whole vault borrow cap |
| ~~H-35~~ | `1788467632` — **done 2026-09-05** on claude/seat-2 `4446e86` | H-35: Insurance-penalty yield vests with holding time |
| ~~H-36~~ | `1788467633` — **done 2026-09-05** on claude/seat-1 `371b5f5` (D4 (a′) hard-capped + self-expiring + promoted; ONE additive stable record; remote upgrade DEFERRED to the rollout `1788469062`) | H-36: Pre-registration profile/preference records are bounded and purgeable |
| ~~H-37~~ | `1788467634` — **done 2026-09-04** on claude/seat-1 `558da0b` (fan-out accumulator, transient; quorum = majority of the fleet, never below the floor; 8s heartbeat deadline; `getPriceFeedStats` additive) | H-37: The mark is applied on a robust quorum or a per-refresh deadline; one slow provider cannot delay the aggregate past the staging window |

`after:` wiring as filed: every backend task after `1788285811`; H-06←H-05; H-21←H-20; H-22←H-09; H-24←D1,H-14; H-25←H-22; H-32←D2,H-10; H-34←H-07,D5; H-35←D3; H-36←D4; H-37←1788465030,H-23; plus the round-18 edges above; D9←1788283668. Priorities are the prioritizer's; `class:` is its input.
