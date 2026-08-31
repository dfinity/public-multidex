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

### Major bumps so far

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

## Regenerating

Run `scripts/gen-did.sh` after any change to the backend's public method surface, and commit the
result. It builds the backend and writes this file (do not hand-edit it).
