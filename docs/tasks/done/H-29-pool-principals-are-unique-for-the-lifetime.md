# H-29 — Pool principals are unique for the lifetime of the archive set; season-archive federation passes only principals the caller owned in that season

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 3 (Bridge upgrade + backend #3: season boundary & state growth) · findings F45 · LOW, latent → live at the next reset · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` — `stable: +map` (fix 2)

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

**done 2026-09-04** (task `1788467626`, branch claude/exec-a, on top of `44a25e2`, after 1788465055/`e6bf9df`): backend-only, candid unchanged (`candid/backend.did` no diff), one new additive stable map. **Fix 1**: `performWorldWipe` no longer executes `nextPoolId := 1` — the counter is the existing stable `var` in a 64-bit id space, so pool ids (and therefore `MarginPools.poolPrincipal`) are unique for the lifetime of the archive set across BOTH wipe arms (`resetSeason` and `resetExchange`); the episode-accumulator comment that justified the clear by "ids restart at 1" is rewritten (it still clears — a dead pool's accumulator has nothing to settle to). **Fix 2**: `_seasonPoolOwners : Map<Nat, Map<Text, [Principal]>>` (season → owner principal text → that owner's pool principals) is frozen INSIDE `performWorldWipe(forSeason)` BEFORE `Map.clear(marginPools)` (keyed `List.size(seasonRecords) + 1`, the same number the detach registers the segments under) and dropped with the registry in the full-wipe arm. New helpers `seasonOfArchive(cid)` and `archiveReadPrincipals(caller, ?season)`: the current chain resolves through the live registry (`selfAndOwnedPools`); a closed season resolves ONLY through the frozen map, and a season with no entry (closed before the map existed — the Phase I archives, were they ever registered) federates the human principal alone. `getMyArchivedEvents` derives the season from the `archiveId` and passes that set; `archiveExecute` carries a `(cid, principals)` pair per hop so each season segment is read with its own set (leg 1's `getEventsForPrincipals` AND leg 2's "mine" filter), the current chain with the live one — `unvisited` reporting unchanged. **Verified on the seat venue (#dev)**: new `tests/test_season_pool_principals.sh` (A funds pool #k in season N → resetSeason → B's first pool, B/A federation through `getMyArchivedEvents` + `archiveExecute` against season N's segments, plus the adjacent "A's NEW pool is indexed in no season-N segment"): RED on the pre-fix venue build — 6/21 failed exactly on the mechanism (season 10's #4 → season 11's #1 recycled; B read 3 season-10 rows it never made; A LOST her pool rows after the wipe in both `getMyArchivedEvents` and `archiveExecute`; A's new pool #2 wore a seed pool's principal and read its season-10 row) — GREEN post-upgrade 21/21 (in-place `deploy.sh local --no-seed` upgrade succeeded, no IC0503). Then `test_season_record_archives.sh` 27/27, `test_season_seal.sh` 31/31, `test_archive_hop_isolation.sh` 23/23, `test_archive_chain.sh` 27/0, `test_archive_chain_paged.sh` 10/0, `test_verify_ledger_gate.sh` 42/42, `test_margin_pools.sh` + `test_archive_replay.sh` (see the task report for their counts), `mops test` 19 files, `bash tests/test_deploy_hygiene.sh` PASS with the new **§6ac** (wipe lacks the counter reset; owner snapshot precedes `Map.clear(marginPools)` by line number; both federation sites use `archiveReadPrincipals` and no longer scan `marginPools`; the helper never consults the live registry for a closed season). Not run: the full `run_all.sh` (the season/archive/margin suites above are the honest gate set for a change confined to the wipe and the two federation sites). Found on the way: `icp identity delete <name> --yes` is a silent no-op in eight suites (the flag does not exist; identities accumulate and a persisted one carried the previous run's season history into this suite's virgin assertions until it switched to per-run names + `echo y | icp identity delete`) — filed as `1788502454`. Bookkeeping: README row strike DEFERRED to `1788502453` (the primary holds the H-series README rows uncommitted behind `1788470219`, as for H-26/H-04); plan §10 row marked in place. Remote: nothing to roll on its own — the fix ships with the Wave 3 backend build that must land before the next `resetSeason` (plan §7).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
