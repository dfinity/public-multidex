# H-26 — Bridge: a refused admission leaves the stable maps identical to their pre-call state; a wipe-pending fence lets the season wipe complete against a sustained admission stream; ineligible callers never occupy the interlock

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 3 (Bridge upgrade + backend #3: season boundary & state growth) · findings F40 + F41 · LOW ×2 · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` · `touches: bridge, tests` — `stable: +Bool` (Bridge)

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

**done 2026-09-04** (task `1788467623`, branch claude/exec-a, on top of `b672db8`/1788465034): Bridge-only, additive candid, one new implicitly-stable `Bool`. **F40**: `pruneZeroRows(k)` deletes a 0-valued `admittedUnits` row and an all-zero Ledger row (both read identically to absent) — called in BOTH rollback arms of `devSimulateDeposit` (explicit `#err` and the catch arm) and after the confirm-time phantom drop; `adminPurgeZeroRows()` (controller) reclaims already-leaked rows (it found 3 on the seat venue, all from pre-fix runs). **F41**: `wipePending` — a refused `adminSeasonWipe` ARMS it; `claim`, `devSimulateDeposit`, `devTestStrandAdmission`, `devTestHoldAdmission` refuse with a typed `#err` and `devConfirmDeposits` traps while it is set; cleared on a completed wipe; `adminCancelSeasonWipe()` (DEX/controller) disarms an abandoned reset; stable by design (survives a Bridge upgrade — pinned). **(3)** every local check (asset, posture, amount, fence, wiring) precedes the in-flight guard and any write; the one non-local check (the DEX's binding gate) is what the fence covers. `getBridgeStats()` query exposes map sizes + the fence. `devTestHoldAdmission(user, asset, hold)` (#dev, controller) parks/releases an admission deterministically. Verified on the seat venue (#dev): RED pre-fix — `test_bridge_write_ahead.sh` 9/24 failed (§5/§6), `test_season_wipe_fence.sh` 24 failed/10 passed (and its real stream DID hold the interlock on attempt 1 pre-fix); GREEN post-fix — write_ahead 24/24 (across-upgrade §2 live), `test_season_wipe_fence.sh` 34/34 (§1 deterministic hold → attempt 1 refused+armed → eligible deposit/claim/confirm + attacker re-hold refused → release → attempt 2 #ok; §2 fence survives `--mode upgrade`, cancel gated; §3 three unbound loops: reset in 2 attempts, 0 rows left), `test_bridge_deposit_claim.sh`, `test_deposit_ledger_guard.sh`, `test_play_deposit_cap.sh`, `test_season_seal.sh` 25/25, `mops test` 19 files, `test_deploy_hygiene.sh` PASS. Not run: the full `run_all.sh` (bridge-only change; the bridge/deposit/season suites above are the honest gate set). Found on the way: `test_deposit_ledger_guard.sh` §5's `icp deploy bridge` rebuilds from the tree and flips a seat's Bridge to #play (and `icp canister install --mode upgrade` installs the LAST build without rebuilding) — write_ahead §2 and the new suite are now posture-aware (build-first when tree == venue, loud ⊘ otherwise; the fence suite gates its hook sections on the BRIDGE's own posture); the ledger_guard half plus the loose `grep -q ok` (matches "h**ook**" in a dev-hook refusal) are filed as `1788474497`. Remote (engine/subnet) rollout of the Bridge upgrade: DEFERRED to the Wave 3 operator rollout (plan §7: must roll before the next `resetSeason`).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
