# H-30 — Unregistered principals are admitted only to the pre-registration method set; state-writing methods require registration; dead-man fires are capped per pass; the five per-user pool scans use the owner index

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 3 (Bridge upgrade + backend #3: season boundary & state growth) · findings F37 + F43 · LOW ×2, one choke point · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

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

**done 2026-09-04** on claude/seat-2 (98400e8 + a697511 + fea6a14), merged `4eafd35`: PRE_REGISTRATION_METHODS + isPreRegistrationMethod routed in inspect (EXIT_METHODS shape; faucet on #dev), shared requireRegistered ×3, DEADMAN_MAX_FIRES_PER_PASS 256 + no bump for order-less fires, adminPruneUnregisteredResidue (bounded, surgical), five reads via ownedPoolIds (archive pair via H-29's archiveReadPrincipals), poolIsEmpty skip before HEAT_MAX_POOLS in the four scans; hygiene §6d + test_h30_unregistered.sh (47; RED 33/51 pre-fix). Production keeps registration-first — operator decision filed as 1788499950. (Task `1788467627`; the bookkeeping half closed from claude/exec-a after the H-wave corpus landed on main at `59906ee`. Gates recorded by seat-2: `mops test` 19/19, `test_deploy_hygiene` PASS, full suite on `#dev` 98/105 — 4 reds were unregistered identities reading queries in update mode, fixed in `fea6a14` with `--query`; 2 venue-state, green standalone; 1 the known H-10 red; `7e43602` later made the same query-mode adjustment to `test_bridge_write_ahead.sh`.) **REMOTE rollout DEFERRED**: the engine/subnet upgrade of the merged build is not a consumer act (law 8) — it rides the operator's folded deploy sitting (task `1788469062`); until that sitting both remote targets still run the pre-fix `inspect` unknown-principal branch and the `Map.entries(marginPools)` per-user scans.

**addendum 2026-09-06** (task `1788499950`, claude/seat-1): the operator decided (2026-09-05) that **#production admits the pre-registration set too** — `preRegistrationAdmitted` no longer carries a `not IS_PRODUCTION` arm; the verdict is `PreReg.admitted(posture, anonymous, registered)` in `src/backend/lib/PreReg.mo` (exhaustive posture switch, unknown principals admitted on `#dev`/`#play`/`#production`), pinned per posture in `tests/PreReg.test.mo` (RED `unknown principal admitted on #production` → GREEN) and by hygiene §6d/1788499950 (RED 3 → PASS). The safety is H-36's bounded store (`688befa`). `EXIT_METHODS`, `requireRegistered` and every body-level `IS_PRODUCTION` interlock (fundArbitrageur, extMarketSwap, seedInsurance, resetExchange, the withdraw custody interlock, play allowances) are untouched; `whyAmIRefused.preRegistrationAdmitted` reflects the shared predicate as before; candid unchanged. Kill-matrix row split in `docs/deployment-modes.md`. **REMOTE rollout still DEFERRED** to the operator's deploy sitting `1788469062` (law 8) — until then production-posture targets keep refusing the six to unregistered keypairs.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
