# W1-03 — One unreachable archive segment fails every History and OQL read, for every caller

**Issue:** [#26](https://github.com/dfinity/public-multidex/issues/26) item 26.2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` HIGH / `#production` HIGH — **not posture-gated**
**Effort:** S–M

## What's wrong

`archiveExecute` walks the archive chain and both federated `await`s sit **bare** inside
`label chain for (cid in List.values(visit))`. There is no `try`/`catch`, no partial result, and no
skip for a segment already observed frozen. One rejected hop fails the entire composite query.

The same file already does this correctly: `adminUpgradeArchives` wraps each per-archive hop in
`try { … } catch (_) { skipped += 1 }`. This is a sibling fix applied to one of two places.

Triggers, none of which needs an attacker:

- `adminUpgradeArchives` walks every segment upgrading it in place — any `archiveExecute` landing
  inside a segment's upgrade window hits a reject
- a segment frozen for cycles (see [W4-15](W4-15-sealed-archive-funding.md))
- a blackholed segment whose status can no longer be read ([W4-10](W4-10-blackholed-segment-observability.md))

**`archiveExecute` has no auth check at all** — the only guard is `oqlRejectReason(qJson)`, a cost
guard — so an anonymous caller reaches the fan-out, and the blast radius is every user of the
History page, not only the caller who triggered it.

## Evidence

- `src/backend/main.mo:15248` — `public shared composite query ({ caller }) func archiveExecute(qJson : Text)`
- `:15251` — the only guard is `oqlRejectReason` (cost), no `requireAuth` / anonymous reject
- `:15281`, `:15293` — the two bare `await`s inside `label chain`, no `try`/`catch`
- `:7833-7846` — `adminUpgradeArchives`, the correct per-hop pattern to mirror

## Fix

```motoko
catch (_) { List.add(degraded, cid); continue chain };
```

plus a `degraded : [Principal]` (or `complete : Bool`) field on the result so the UI can say
"segment X unavailable" instead of failing the page. Additionally skip any cid whose `_archiveObs`
entry reports `frozen = true`.

Decide separately whether `archiveExecute` should carry an auth check at all — under the
transparency doctrine the *publicness* is defensible, but the absence should be deliberate and
documented rather than incidental.

## Done when

- [x] A rejecting/frozen segment yields a partial result, not a failed query
- [x] The result distinguishes "complete" from "degraded", and the frontend surfaces which segment
- [x] A test installs an unreachable segment and asserts History still renders the reachable rows
- [x] The auth posture of `archiveExecute` is a written decision, either way

## Completed 2026-08-14

- `archiveExecute` returns `ArchiveOqlResult = { rows; hasMore; degraded : [Text] }`. Each segment
  hop is wrapped in `try/catch` (verified to compile in a composite query on the pinned moc 1.9.0):
  an unreachable segment adds its cid to `degraded` and the walk continues — mirror of
  `adminUpgradeArchives`' per-archive isolation. Rows already collected from a segment that failed
  mid-pagination are kept. A segment whose `_archiveObs` entry last read `frozen = true` is skipped
  without the round-trip and reported degraded (worst case one fuel-interval stale — the cheap
  direction of wrong).
- **Auth decision, written** (comment at the endpoint + pinned by the test's anonymous-caller §):
  deliberately public beyond the cost guard. Leg (2) is the public money-flow ledger the
  transparency doctrine requires; leg (1) is caller-scoped by construction; `oqlRejectReason`
  remains the real gate because the fan-out spends sidecar cycles.
- Frontend: `ArchiveOqlResult` IDL (candid record subtyping keeps an older UI decoding fine);
  History explorer status line names unavailable segments; the AI assistant's history query result
  carries a WARNING note so the model qualifies partial reads.
- Dev hook `setTestArchiveStopped(cid, stopped)` (controller + `requireDevHook`, scoped to
  `allArchivePrincipals` — refuses foreign principals; `start_canister` added to the ic00
  interface). New `tests/test_archive_hop_isolation.sh`: two-segment chain, baseline complete →
  stop sealed segment → **answers** with rows + `degraded = [cid]` (pre-fix: rejected venue-wide),
  anonymous caller same, restart → drains, hook scope pinned. 14/14 green on a `#dev` local
  deploy; `test_oql_guard` and `test_deploy_hygiene` re-run green after the `#play` restore.
- `scripts/gen-did.sh` run: `candid/backend.did` (published) regenerated with the new surface.
- Local venue note: the test family's `resetExchange` wiped the seeded venue; local backend is
  redeployed on `#play` but **unseeded** — `bash scripts/cold_start.sh` before anything that needs
  the seeded AMM.
- Raised [W5-20](W5-20-deploy-path-candid-freshness.md): the first `#dev` deploy shipped with
  **stale** candid:service metadata (checked-in `.did` embedded at deploy; `gen-did.sh` had not
  run) — reproduced live today; nothing on the deploy path asserts the published interface is
  fresh.
