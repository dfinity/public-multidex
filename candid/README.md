# Published Candid interface

`backend.did` is the **published Candid interface** of the MULTI/DEX backend canister —
the machine-readable list of every public method with its argument and return types.

## Two ways to get it

- **Live, from the deployed canister.** The backend serves this as **public `candid:service`
  metadata** (the build passes `--public-metadata candid:service`; see `mops.toml`), so remote
  tooling — e.g. the IC MCP connector's `ic_describe_api` — can fetch the typed interface directly
  from the canister with no repo checkout.
- **Here, versioned.** This committed copy is the reviewable stability contract, diffable in PRs.

## Signatures vs. semantics

Candid describes **shapes, not behavior.** It won't tell you that market/limit orders return with
*no fills* and you poll for the outcome (sealed/staged matching), that all money is a `Nat` scaled
by 10⁸, that there's a $100k lifetime deposit cap, or how the dead-man switch works. For that, call
the **`getApiDoc()`** query on the canister — the guide to the non-obvious semantics — and
`getMarketSpecs()` for the live numeric constants.

## Stability

Additive-only within a major `apiVersion` (see `MM_API_VERSION` / `getMarketSpecs`): new methods and
new optional fields may appear; existing signatures don't change or disappear without a major bump.

### Queued for the next major bump

Breaking changes that are DECIDED but WAITING for a major window — `scripts/lint-ratchet.sh`'s
subtype gate refuses them within the current major, by design. Whoever opens the next major
folds these in (each names its task) and moves the entry into "Major bumps so far".

- **`getUserPreferences` becomes a `query`** (task 1788644470, recorded 2026-09-06 — the
  follow-up 1788656273 carries the recipe). **It did NOT ride 6.0.0**: when that window opened
  (task 1788731608, 2026-09-07) the operator-lane decision 1788656273 was still undecided, and a
  breaking release bundles only decided changes — so this waits for **7.0.0**. **Operator ruling
  2026-09-17: confirmed — it becomes a `query`; it rides the 7.0.0 window (no additive
  `getMyPreferences` sibling in the meantime). The recipe is in the archived brief
  `tasks/archive/1788656273.md`; the task that opens 7.0.0 folds it in.** The body is a pure `Map.get` with a default (it never writes,
  never stamps H-36's pre-registration store), yet every read is an update: a consensus round
  and a bounded-ingress-queue slot per sign-in / market switch. There is no design reason for
  the update mode (an update since the initial commit; H-36 filed it as a follow-up), and the
  frontend's hand-written IDL already needs only a `["query"]` annotation. It cannot land within
  apiVersion 5 because Candid function subtyping requires IDENTICAL annotations on both sides —
  `update → query` is not a subtype in either direction (`mops check-candid`: "Candid
  compatibility check failed"). With the mode change: drop it from `PRE_REGISTRATION_METHOD_SET`,
  the `preRegCandidate` arm in `inspect`, hygiene §6d's list and `test_h30_unregistered` §1
  (queries never reach `inspect`; the `inspect` msg variant keeps the tag — M0127). Additive
  alternative if no major window opens: a sibling `getMyPreferences` query and a frontend
  switch, leaving the update in place as a deprecated alias.

### Major bumps so far

- **6.0.0 — September 2026 (task 1788731608; the operator rulings of 2026-09-06 in tasks
  1788503312 and 1788516198).** Two decided changes rode the one hatch:
  1. **`depositLp` / `withdrawLp` BECOME the sealed LP doors.** Both now return
     `{#ok : StagedLpRequest; #err : Text}` — the REQUEST, not the minted LP / the basket. The
     deposit legs (or the shares) are reserved at the call; the request settles at the first
     NAV whose basket marks ALL postdate it (the price-postdates-entry rule orders release on,
     so a stale mark can never be minted or redeemed against), through the same mint/redeem
     body the immediate doors ran, every refusal evaluated AT SETTLEMENT and recorded as a
     `#cancelled` outcome; a request no fresh marks reach within 5 minutes is cancelled and
     refunded, fail-closed. Poll `getMyStagedLpRequests()` for the outcome (5.1.0's additive
     surface, unchanged). The 5.1.0 `stageLpDeposit` / `stageLpWithdraw` names are DROPPED
     (no alias — they existed for one unreleased minor and never reached a remote target).
     `seedAmmPool` is **controller-only** now (it was `requireAuth` only): it is the one
     immediate mint door left, for the seed scripts under paused timers; an open immediate
     mint would have been the sniping window the ruling closed. Why a major: a Candid return
     type cannot change its meaning under the same shape, and `mops check-candid` proves a
     new variant arm on a return type BREAKING (rc 1) — so the flip could not ride 5.x
     (docs/amm-vault-design.md §5 "Sealed LP requests"). Bots calling `depositLp` /
     `withdrawLp` must read the request id from `#ok` and poll; the 60 s freshness belt the
     immediate doors flickered on is no longer a refusal they can see.
  2. **The PendingMatch / protection-window surfaces are REMOVED** (task 1788516198, option 2:
     the machinery was retired on the 5.x line with the Candid byte-identical — inert stubs).
     Gone: `getMyPendingMatches` (always `(vec {})`), `placeProtectedLimitOrder`
     (= `placeLimitOrder`, `windowSeconds` ignored), the `pendingMatches` field of
     `MatchResult` (placeMarketOrder) and `PlaceLimitResult` (always `[]`), the `PendingMatch`
     / `PendingMatchStatus` types, `setAmmConfig`'s sixth parameter `protectionWindowSec`
     (accepted and ignored — callers pass FIVE arguments now) and `AmmPool.protectionWindowSec`
     (stored, never consulted). With them went `devSweepCostProbe`'s seven `pending*` fields
     and the owner-index audit fixture (`pmIdsByUser`, `recordPendingMatchIndex`,
     `myPendingMatchesOf`, `tests/test_pending_owner_index.sh`) whose only public reader was
     the removed query. NOT swept: the four fossil stable fields (`orderSettlementWindows`,
     `pendingByMaker`, `nextPendingMatchId`, `pendingQtyByMaker`) and the `pendingMatches` map
     stay parked — enhanced orthogonal persistence refuses a stable-field drop or retype
     (IC0503), which is also why `Types.PendingMatch` survives as a PRIVATE type (the fossil
     map's element type; no public method mentions it, so the .did no longer carries it). The
     same rule bit `AmmPool.protectionWindowSec`: dropping the field from `AMM.Pool` inside the
     stable `pools` map was refused live as IC0503 "Memory-incompatible program upgrade" — so
     the stored record KEEPS it as a fossil and `getAmmPool` / `getAmmPools` return
     `AMM.PoolView`, the same record with the field projected out. (Both parkings ended
     with the sixth one-shot migration, task 1788744109 — the five stable fields consumed
     and dropped, `pools` mapped onto the field-less record, `PoolView` kept only as the
     Candid's name for the stored `Pool`; the .did is byte-identical across the sweep. See
     the NOTE above the actor in `src/backend/main.mo`.)
     Installing the bump itself needs icp's Candid-compatibility bypass ONCE per venue
     (`icp deploy --yes`; `cold_start.sh` forwards it under the hand-set
     `MDX_DEPLOY_BREAKING=1`, and `deploy.sh engine|subnet` passes `--yes` through to the
     backend deploy) — the ratchet made the declaration, this only carries it to icp.
  Not in 6.0.0: `getUserPreferences` update → query (queued above; its decision task was
  still open when the hatch was taken, so it waits for 7.0.0). Everything else in 6.0.0 is
  additive or unchanged.

- **5.0.0 — August 2026 (#47.4 decision, task 1787199871).** `UserEventKind` gains the
  `#config` variant — `{ setter : Text; value : Text }`: the six authority setters
  (`setBridge`, `setArbitrageur`, `setFuelRoute`, `setXrcCanister`, `setBlackholeAtSeal`,
  `setAutoFuel`) now land on the durable hash-chained tape beside their ring-log lines
  (operator-ratified 2026-08-20: an NNS-run venue whose tape is the permanent
  principal-attributed record should not keep "who rewired the oracle and when" only in a
  bounded transient ring). Same change class as 3.0.0's `#gap`: consumers decoding tape
  events must add the case; decoders built against 4.x fail on the first `#config` event
  they meet, which is deliberate — a verifier older than the canister must say so rather
  than mis-verify. Everything else in 5.0.0 is additive: no existing constructor, method,
  or field changed.
- **4.0.0 — August 2026 (#49.5 retirement, task 1787182537).** The inert Phase-4
  adverse-flow ("hostility") machinery is deleted: `getCounterpartyStatsQuery` and
  `getAllCounterpartyStats` (controller-gated queries that only ever surfaced an
  empty map — the AMM is non-takeable, so their data source was provably never
  fed), the `CounterpartyStats` type, and `devSweepCostProbe`'s
  `hostilityCold`/`hostilityWarm` fields. Adverse-flow widening is UNIMPLEMENTED
  and the quote formula no longer advertises it; wiring was rejected as
  attacker-influenceable (widen-by-griefing / Sybil laundering) — any future
  adverse-selection protection will be designed fresh (markout / vol /
  inventory-based). Quotes are byte-identical: the removed term was identically
  zero. No non-controller consumer existed for the removed surfaces.
- **3.0.0 — August 2026 (W2-04).** `UserEventKind` gains the `#gap` variant: the L2
  archive-failover shed now declares its dropped range ON the chain (hash-committed,
  certificate-covered), so ledger verifiers no longer have to trust `getLedgerGaps` — an
  uncertified self-report — to tell a documented gap from tampering. Consumers decoding tape
  events (`getEventsRange`, `getMyUnshippedEvents`, archive reads) must add the case; decoders
  built against 2.x fail on the first `#gap` event they meet, which is deliberate — a verifier
  older than the canister must say so rather than mis-verify (`verify_ledger.mjs` already
  refuses unknown kinds by design). Everything else in 3.0.0 is additive: per-segment
  certificate validation and genesis pinning live in the verifiers, and
  `getStagedIndexAudit` / `devSweepCostProbe` / `getAccessPolicy` gained fields (W1-07/W1-08).
- **2.0.0 — July 2026.** The public trade feeds — `getRecentTrades`, `getAllTrades`,
  `getTradesSince` — now return **de-identified `PublicTrade`** records (no maker/taker
  principals). Bots parsing the old `Trade` shape from these three methods must switch to
  `PublicTrade`; your *own* fills (with fees and order ids) are unchanged via
  `getMyTradesSinceId` / `getMarketChanges`. Account-attributed history remains available on the
  public archive tape, which proof-of-reserves requires. Everything else in 2.0.0 is additive —
  notably the liquidation-transparency queries (`getMarginHeatmap`, `getMarginHeatmaps`,
  `getMarginHeatmapHistory`, `getMarginRiskSummary`).

## Sibling interfaces (task 1788510196)

Two more canisters the frontend talks to directly get a published copy here, generated by the
same script with the same header:

- **`archive.did`** — the archive sidecar **actor class** (`src/backend/ArchiveCanister.mo`;
  `service : (owner : principal) -> Archive`), one per backend, spawned by it. It ships the
  backend's `UserEvent` verbatim, and `main.js` hand-writes a *second* IDL for it
  (`getArchiveIdlFactory`) — this file is what pins that copy.
- **`bridge.did`** — the deposit-custody **stub** (`src/bridge/main.mo`); real chain-key custody
  is a separate team's job (`docs/bridge-and-cks-design.md`).

Neither carries an `apiVersion` or the additive-only promise above — they are *reference* copies,
not stability contracts: `tests/frontend_display_integrity.test.mjs` §K holds each hand-written
IDL factory in `main.js` to its file (IDL fields ⊇ published fields, because `@dfinity/candid`
silently drops wire fields the IDL does not name), and `scripts/lint-ratchet.sh` fails when either
is stale against its source, exactly as for `backend.did`.

## Regenerating

Run `scripts/gen-did.sh` after any change to the backend's public method surface, and commit the
result. It builds the backend and writes this file (do not hand-edit it) — and `archive.did` +
`bridge.did` beside it.
