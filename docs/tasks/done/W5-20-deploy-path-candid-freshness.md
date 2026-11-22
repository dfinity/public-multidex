# W5-20 — The deploy path ships whatever candid is lying around

**Issue:** none — raised by [W1-03](W1-03-archive-execute-hop-isolation.md) (queue step 5), 2026-08-14
**Status:** REPRODUCED LIVE during W1-03, local target
**Severity:** `#play` LOW / `#production` MEDIUM (a public, machine-readable interface that lies)
**Effort:** S

## What happened (live repro, 2026-08-14)

W1-03 changed `archiveExecute`'s return type and added a method, then deployed to the local
replica **without running `scripts/gen-did.sh`**. The build embedded the stale checked-in
interface as the canister's public `candid:service` metadata (mops.toml declares
`candid = "src/backend/backend.did"` and `--public-metadata candid:service`). Observable effects:

- `icp canister call` decoded replies against the stale record and **silently dropped the new
  `degraded` field from display** — the very field under test;
- calls to the new method printed raw hash variants (`variant { 24_860 }`) after a
  "could not fetch candid type" warning;
- any remote tooling reading the published metadata (the mops.toml comment names
  `ic_describe_api`) would see an interface that does not match the deployed code.

`scripts/lint-ratchet.sh` §CANDID does assert `candid/backend.did` freshness — but only when the
ratchet runs. Nothing on the **deploy path** (`deploy.sh`, `icp deploy`, `play_start.sh`,
`cold_start.sh`) regenerates or asserts it, so the window between "edited the API" and "ran the
ratchet" ships a lying interface to whichever target you deploy in between. On the subnet that is
a public artefact of a transparency-doctrine venue.

## Fix sketch

1. `deploy.sh` (all targets): before build, either run `scripts/gen-did.sh` outright (it is
   idempotent and cheap relative to a deploy) or assert the regenerated output is byte-identical
   to the checked-in copy and die naming `gen-did.sh` when not.
2. Keep the ratchet's check as the commit-time gate; this adds the deploy-time one. Same
   fresh-vs-checked-in comparison, two enforcement points.
3. Pin in `test_deploy_hygiene.sh`: deploy.sh contains the gen-did step/assertion (static), and
   the assertion actually fails on a doctored stale copy (behavioural, fixture-based like §6b).

## Done when

- [ ] A deploy from a tree whose `.did` is stale either regenerates it or refuses, on every target
- [ ] The hygiene test pins the mechanism
- [ ] `icp canister call` against a fresh local deploy of an API-changing edit decodes named
      fields without a `gen-did.sh` thought required

---
## Done — 2026-08-15

deploy.sh now runs `bash scripts/gen-did.sh` unconditionally BEFORE the
posture gate and the target dispatch — every target inherits it, and a
gen-did failure dies with "refusing to deploy a stale candid:service
interface" (option 1 of the sketch: regenerate outright — idempotent and
cheap relative to any deploy; the ratchet's CANDID section remains the
commit-time gate). Hygiene §7c pins three things: the step exists in
uncommented deploy.sh text, the refusal text exists, and the step's line
number PRECEDES the `case "$TARGET"` dispatch so no target branch can skip
it.

Verified: (a) removing the step turns §7c red; (b) behaviourally — doctored
src/backend/backend.did with stale content, ran the real `deploy.sh local`:
the file was regenerated (hash changed, doctored content gone), the deploy
completed through the full local flow, and a named-field query
(devSweepCostProbe) decodes symbolically with no manual gen-did thought.
Note: the local flow's tail also restarted the sim bot fleet, as it always
does — the end-of-session regression stops it via run_all's guard.
