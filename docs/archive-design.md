# Permanent User History — Archive Canister Design

*Drafted 2026-06-10. Status: PROPOSAL (nothing implemented). Companion to
`docs/pre-mainnet-checklist.md` ("durable user history" blocker) and the
2026-06-10 heap incident: the hot canister now reaps closed orders and caps
per-user histories, which makes a durable tier mandatory before real funds —
today trades trim at 200k/market / 600k global, so the tax-relevant record is
lossy by design.*

## 1. What must be permanent (the data inventory)

A user preparing taxes (or disputing an outcome) needs every event that
changed what they own, what they owe, or what it cost them. Concretely, in
this codebase's vocabulary:

| Event class | Why permanent | Where it's born today |
|---|---|---|
| **Fills** (trades, incl. swaps and netting) | The tax events: every acquisition/disposal with price, qty, time, fee, maker/taker role | `OrderBook.recordTrade` — a single choke point |
| **Deposits / withdrawals** | Cost-basis entry/exit; on mainnet these are ledger transfers | `UserStatus.appendDeposit` (and future ICRC transfer paths) |
| **Liquidations** (seizes, netting legs, bad-debt absorption) | Forced disposals — tax-relevant AND dispute-relevant | `liquidationEvents` (per-user, currently trimmed) |
| **Borrow lifecycle** (borrow, repay, interest accrual at repay, cash-settle) | Interest expense; debt history | borrow/repay paths in `main.mo` |
| **Vault/LP events** (depositLp, withdrawLp, seedAmmPool legs, insurance stake/unstake/payout) | LP share acquisition/redemption are taxable; insurance income | `performLpDeposit`, `withdrawLp`, `stakeInsurance`, … |
| **Order lifecycle** (place, adjust, cancel, close) | Not strictly tax-required (executions are), but the user's instruction record; cheap for humans | `UserStatus.appendAdjustments` + the reaper's close records |

Excluded: the AMM/vault principal's own quote churn (the 2026-06-10 leak —
millions of 2-second ladder quotes). The *user side* of a fill against the
AMM is recorded (it's the user's trade); the vault's side carries the AMM
principal in the counterparty field but gets no per-user index entry.

Derived data (balance statements, P&L summaries) is NOT archived — it can
always be recomputed from the events. CSV export does that client-side.

## 2. Constraints the design must respect

1. **No `await` in user value paths.** The security review's load-bearing
   invariant (no IC reentrancy on value paths). Event *capture* must be a
   synchronous, same-message append; *shipping* to archives is background
   work, like the reaper.
2. **Heap is scarce, stable memory is not.** wasm64/EOP heap walls at 6 GiB
   (incident history); stable Regions go to ~500 GiB per canister and don't
   touch the heap.
3. **2 MiB message limit** — shipping batches must be sized under ~1.5 MiB.
4. **At-least-once delivery is the only kind there is.** A shipped batch can
   time out with unknown outcome; the archive must dedupe so retries are
   exactly-once *effective*.
5. **Upgrades must never lose the unshipped tail** — the journal lives in
   stable memory, not the heap.
6. **Archives must outlive negligence.** If top-ups fail for months, the
   data must still be there (freezing threshold ≈ 1 year, and anyone can
   refuel — the project's existing public-good stance).

## 3. Architecture

```
 user msg (trade/deposit/…)          heartbeat (async)                queries
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────┐
│ main canister            │   │ shipper task (10s):      │   │ frontend     │
│  state change            │   │  read journal[shipped..] │   │  recent: ask │
│  + journal.append(event) │──▶│  appendBatch() ──────────┼──▶│  main (hot)  │
│    (same message,        │   │  await ack → advance     │   │  older: ask  │
│     stable Region,       │   │  shippedSeq, truncate    │   │  archives    │
│     global seq#)         │   └──────────┬───────────────┘   │  directly    │
└──────────────────────────┘              ▼                   └──────┬───────┘
 routing table (stable):        archive_0 [0…N0]   sealed                │
  seq range → canister id       archive_1 [N0+1…N1] sealed   ◀───────────┘
  user → [archive ids]          archive_2 [N1+1…  ] ACTIVE   getMyEvents(cursor)
```

- **Capture queue (in main; transit only — REVISED 2026-06-10):** an
  in-order queue of `UserEvent`s with a global monotone `seq`, appended
  synchronously in the same message as the state change — if the message
  traps, both roll back. This local hop is physically unavoidable: an
  inter-canister write cannot be atomic with the trade (awaiting mid-message
  commits partial state and reintroduces exactly the reentrancy windows the
  value paths are designed not to have), so durability is achieved by
  capture-locally + ship-async, never by write-through. Per the 2026-06-10
  decision the queue is NOT a durable tier: it lives on the heap as a plain
  `List` (EOP makes the heap survive upgrades, so nothing is lost on
  upgrade), is truncated as batches are acked, and is expected to hold
  seconds-to-minutes of events. `journalUnshipped` is a dashboard metric
  with an alarm threshold; a stable-Region spill for pathological backlogs
  is deferred to Phase D. The durable tier is the sidecar/archive chain
  from day one.
- **Shipper (heartbeat task):** every ~10 s, if the queue is non-empty,
  send a batch (≤ ~1.5 MiB or ≤ 5k events, plain candid — no local byte
  codec needed), `await archive.appendBatch()`, on ack advance `shippedSeq`
  and drop the acked prefix. On unknown outcome: re-ship; the archive
  ignores `seq < its nextExpected` (dedupe).
- **Archive canister (small Motoko actor, wasm embedded in main):**
  - `appendBatch(events) : async {#ok : Nat /*nextExpected*/; #err}` —
    gated to `msg.caller == main`; writes to its own stable Region; updates
    its per-user index (`principal → vec of region offsets`, on heap or in a
    second region); rejects when sealed/full.
  - `getMyEvents(cursor) / getEventsRange(from, to)` — public queries;
    `getMyEvents` keyed on `msg.caller` (II delegations work against any
    canister, so the frontend queries archives directly).
  - `stats()` — seq range, bytes, event count, `Cycles.balance()`,
    per-user count for the caller. Powers the dashboard and the top-up task.
- **Routing table (in main, stable):** `[(canisterId, fromSeq, toSeq?)]`
  plus `user → [archiveIds]` (one entry the first time a user's event lands
  in an archive) so the UX never queries an archive that holds nothing for
  that user.

## 4. Event schema

One envelope, one sequence, every class:

```motoko
type UserEvent = {
  seq      : Nat;          // global, dense, assigned at capture
  ts       : Int;          // Time.now() at capture
  user     : Principal;    // the user this event belongs to (indexed)
  counterparty : ?Principal; // e.g. the other side of a fill (AMM allowed)
  kind     : {
    #fill : { marketId : Text; side : Side; orderType : OrderType;
              price : Float; qty : Float; feeUsd : Float;
              orderId : Nat; tradeId : Nat; role : { #maker; #taker } };
    #deposit : { token : Text; amount : Float; kind : DepositKind };
    #withdrawal : { token : Text; amount : Float };
    #orderClosed : { orderId : Nat; marketId : Text; side : Side;
                     status : { #filled; #cancelled };
                     price : Float; qty : Float; filled : Float };
    #liquidation : { …mirror of LiquidationEvent… };
    #borrow : { token : Text; amount : Float };
    #repay  : { token : Text; amount : Float; interest : Float };
    #lpDeposit  : { marketId : Text; baseAmt : Float; quoteAmt : Float; lpMinted : Float };
    #lpWithdraw : { lpBurned : Float; basket : [(Text, Float)] };
    #insurance  : { #stake : Float; #unstake : Float; #payout : Float };
  };
  prevHash : Blob;         // SHA-256 of previous event — tamper-evident chain
};
```

A fill generates **two** events (one per human party; the AMM side is
counterparty metadata only). Encoding: Candid (`to_candid`) into the region —
self-describing, future-proof for added variants, decodable by tooling.
The hash chain costs one SHA-256 per event and turns the archive into an
audit log: any party can verify a downloaded range. (Full certified-variable
query certification is a Phase-D hardening, not required to start.)

## 5. Archive lifecycle

- **Spawn-ahead:** when the active archive reports ≥ 90% of `ARCHIVE_CAP`
  (default 16 GiB region bytes — ~3 years of heavy-sim volume at ~10–15
  MB/day; small enough for cheap blast radius, big enough that spawns are
  rare), the shipper creates the next one with `INITIAL_CYCLES`, installs the
  embedded archive wasm, appends to the routing table. The old archive is
  **sealed** (`toSeq` fixed) and never written again.
- **`INITIAL_CYCLES` must exceed the new canister's freezing-threshold
  RESERVE plus `install_code` (verified 2026-06-10):** a fresh canister
  reserves cycles for its default 30-day freezing threshold *before* install,
  so an under-funded spawn creates the canister but fails to install it
  ("out of cycles"). 1 T failed this way locally (≈1 T eaten by the reserve);
  **3 T** is the working value (sidecar settles at ~2.49 T live). The earlier
  2 T figure here was also too low. On a 13-node mainnet subnet the 30-day
  reserve is larger again — size `INITIAL_CYCLES` to clear it, or create with
  a short freezing threshold (Phase B uses explicit `create_canister` with
  settings rather than the actor-class `(with cycles=…)` sugar, which can't
  set the threshold).
- **Failed spawn must not leak the half-created canister (Phase B
  hardening):** the actor-class sugar does create-then-install atomically in
  one `await`; if install fails the canister still exists, but its id is only
  in the error string, so main can't reclaim it — and the 10 s shipper retry
  creates *another* one each cycle. Phase B must split create/install so a
  failed install reuses (or deletes) the existing canister id. (Under-funding
  triggered this during 2026-06-10 testing, leaving a few orphaned empties on
  the local replica; harmless there, a real cycle drain on mainnet.)
- **Controllers:** main canister + the project's human controllers (rescue
  and upgrade possible). A blackhole/immutability decision is explicitly
  deferred — upgradability wins until governance exists.
- **Upgrades:** archive wasm version is embedded in main; a controller-only
  `adminUpgradeArchives()` rolls it out if ever needed. Archives are dumb on
  purpose (append, index, serve) so this should be rare.
- **Sim reset semantics (REVISED 2026-06-10):** the sidecar exists so resets
  stay clean. `resetExchange` (or a companion controller-only
  `adminResetArchiveChain()`, both no-ops when `IS_PRODUCTION`) clears the
  capture queue and seq counters, clears the routing table, then
  `stop_canister` + `delete_canister`s every archive in the chain (main is
  their controller) and spawns a fresh archive_0. Result: a reset leaves
  ZERO history footprint anywhere — main's heap queue is cleared and the
  deleted canisters release their storage entirely. Two notes: (a) deleting
  a canister forfeits its remaining cycles — irrelevant on the local sim,
  and mainnet never deletes archives (the reset path is dev-only by the
  production gate); (b) seq numbering restarts per sim epoch, which is
  correct — a reset is explicitly "wipe the world". In-place region reuse
  inside main was considered and rejected: regions (like wasm heap) are
  grow-only for the canister's lifetime, so only deleting a sidecar returns
  the space physically.

## 6. Cycles: funding, top-up, survival

Mainnet cost anchors (13-node subnet, approximate): storage ≈ 127k
cycles/GiB/s ≈ **4 T cycles/GiB/year** (~$5/GiB/yr); canister creation
0.1 T; an idle 16 GiB archive therefore burns ≈ 64 T/yr ≈ $85/yr. Round
numbers, three mechanisms layered:

1. **Main as treasurer (primary).** A slow heartbeat task (~6 h) polls each
   archive's self-reported `stats().cycles`. Below `LOW_WATER` (20 T ≈ 3
   months of a full archive's burn) → `deposit_cycles` up to `HIGH_WATER`
   (40 T), funded from main's own balance. Main's existing dashboard cycle
   gauge already alarms when *it* runs low, so the whole tree has one
   funding root. `deposit_cycles` needs no controller rights, so this works
   even if controller wiring is ever broken.
2. **Freezing threshold = 1 year on archives.** A frozen canister stops
   serving but is not deleted until its balance fully drains; one year of
   reserve means a quarter of total neglect still loses nothing — queries
   resume on refuel.
3. **Anyone-can-refuel (public-good fallback).** Archives are plain
   canisters; the dashboard's new "Archives" card lists each one's id,
   range, bytes, and cycle balance with the same "send cycles to…" hint the
   main canister already shows. Matches the project's existing stance.

Alternatives considered for top-ups: an external service (CycleOps) — fine
later, adds an off-chain dependency; a dedicated funding canister — more
moving parts with no benefit at this scale. Main-as-treasurer is one
heartbeat clause and keeps a single funding root.

## 7. Retrieval UX

ICRC-3's redirect pattern, app-flavoured:

- `main.getMyHistory(cursor?)` serves the hot window (existing capped lists
  + unshipped journal tail) and, when the cursor crosses into shipped
  history, returns `#archived { canisterId; method = "getMyEvents"; cursor }`
  descriptors. The frontend then queries those archives **directly** —
  archives are parallel-queryable and main stays cheap.
- All history tabs (Trades, Deposits, Adjustments, Recently Closed) gain a
  "Load older…" row that transparently walks the descriptor chain.
- **Export (the tax deliverable):** Account → "Export history (CSV)" walks
  the full cursor chain client-side, assembles one file in the browser
  (`fills.csv`, `transfers.csv`, columns chosen for tax software: time, kind,
  asset, qty, price, fee, counterparty, tx ids). No server-side state.
- Dashboard: Stats → Canister gains an **Archives** card (chain table:
  range, events, GiB, cycles, status) plus `journalUnshipped` — if shipping
  stalls, the number grows and the existing banner machinery can warn.

## 8. Failure analysis

| Failure | Behaviour |
|---|---|
| Trap in user message after journal append | Whole message rolls back — journal append included (same-message atomicity). No phantom events. |
| Shipper batch times out (unknown outcome) | Re-ship next sweep; archive dedupes by `seq`. Exactly-once effective. |
| Active archive out of cycles / stopped | Shipping pauses, journal grows (it's the durable buffer); dashboard `journalUnshipped` climbs; top-up task or a human refuels; shipping resumes where it left off. |
| Archive full mid-batch | `#err(#sealed)` → shipper finalises routing entry, switches to the spawn-ahead successor, retries the same batch there. |
| Main upgrade mid-flight | `nextSeq`/`shippedSeq`/routing are stable; the journal is a stable Region. Shipping resumes post-upgrade. |
| Journal region hits its alarm cap (e.g. 2 GiB unshipped) | Loud event-log entry + banner; capture **keeps writing** (storage is the cheap thing; losing events is the expensive thing). |
| Frontend can't reach an archive | That page of history shows a retriable error; other ranges unaffected (archives are independent). |

> **Superseded 2026-07 (see §8b).** The row above about the queue "keeping
> writing" past an alarm cap was the philosophy that *caused* the July-2026
> incident: the unshipped queue is main's HEAP, not a stable buffer, and
> letting it grow without bound starved trading-critical work (the oracle
> price-apply pipeline). "Losing events is the expensive thing" is true only
> up to the point where the buffer threatens the exchange itself — beyond
> that, a bounded, *recorded* observability gap is far cheaper than an OOM.

## 8b. Layered failure handling (added 2026-07, after the archive-backlog incident)

**What happened.** A deployed archive predating the `ensureCapacity` grow-check
filled its 4 GiB Region and **trapped** (`Region error: range out of bounds`)
on every `appendBatch` — a *hard* failure, not the graceful `#full`/`#sealed`
the shipper knew how to handle. The shipper retried the wedged canister every
10s forever; the unshipped queue grew to **2.67M events / 2.55 GB heap**, and
that heap pressure degraded the oracle price-apply cycle to ~one update per 9
minutes, dumping all order flow into the users-only fallback. A non-critical
subsystem (history) took down a critical one (the price feed) via shared heap.

**The two lessons, and the two layers** (`main.mo` — `emergencyRollArchive`,
`shedOldestEvents`, `tickShipEvents`):

- **L1 — roll on ANY persistent failure, not just a clean `#full`.** After
  `SHIP_FAIL_ROLL_THRESHOLD` (3) consecutive ship failures — trap *or* `#err` —
  seal the wedged archive at its own `shippedSeq − 1` (its acked prefix stays
  durable and routable) and roll to a fresh successor; the unshipped tail drains
  onto it. **Zero data loss.** Feasible because the seal boundary comes from
  main's own `shippedSeq`, never from the (possibly trapping) archive, and a
  trap's full rollback guarantees the wedged archive holds no partial event. A
  failure-seal is left *controlled* (not blackholed) so ops can recover/inspect
  it. Rate-limited by a 60s cooldown so a systemic fault can't spawn-storm. This
  generalises the pre-existing `#full` seal-and-roll to unanticipated hard
  failures — the exact class the incident belonged to.

- **L2 — bound the heap as a last resort.** If L1 cannot obtain a working
  archive (spawns failing, subnet fault) and the queue still reaches
  `USER_EVENTS_HARD_CAP` (250k), drop the oldest unshipped events down to the
  low-water mark (200k), advance `shippedSeq` past them, and record the dropped
  seq range as a **queryable ledger gap** (`getLedgerGaps`; coalesced per
  outage). The exchange keeps trading; the *history* in the gap is gone. A gap
  forces a chain re-anchor: the post-gap events open a fresh archive segment the
  next time L1 can roll (their `prevHash` points at a dropped event, so they
  can't extend the old chain).

  **The shed closes its own gap.** Immediately after the drop, the canister
  re-opens the tape with a **re-baseline**: one absolute re-attestation row per
  live entry of each folded ledger — `#delta` per balance, `#debtDelta` per
  loan, `#lpShareDelta` per vault LP position, `#insShareDelta` per insurance
  stake — the exact `resetExchange` epoch-genesis pattern, as ordinary chained
  events (no new kind, no hash-format change). The pending ledger journal is
  drained *first*, so the snapshot equals the state the tape reaches at the
  baseline's own position. Each snapshot's seq range is recorded in
  `getShedBaselines` (`[fromSeq, toSeqExcl)`). Replayer contract: **zero your
  fold at `fromSeq`, keep folding** — from `toSeqExcl` onward the fold again
  reproduces every live balance from the public tape alone. Invariants that
  keep this sound: a later shed never *bisects* a baseline (the drop boundary
  is extended to swallow a straddled one — it is superseded by the fresh
  baseline anyway), and baselines whose rows were themselves swallowed by a
  later gap are compacted out of the record. Baseline size is O(live ledger
  entries) (~thousands of rows), which is why the cap's headroom
  (250k − 200k = 50k) must stay well above it.

**Composition.** L1 handles the realistic failure (one archive broke) with no
loss; L2 is the true floor for "the whole archival subsystem is down," trading a
recorded observability gap for the exchange staying alive. In the incident, L1
alone would have fixed it — the queue would have drained to a fresh archive
within ~40s instead of growing for an hour.

**PoR note.** A shed drops the archived *record* of events, never the live
balances — the `#delta` rows were already APPLIED to `accounts` before the ship
queue ever saw them, so the canister's real state is intact. And because of the
re-baseline, *reconstruction from the public tape* survives too: a fold that
resets at each recorded baseline reproduces every balance exactly from the
baseline's end onward. What is irrecoverably lost is the dropped **history**
itself — the per-event story of the gap window (fills, flow attribution) — and
fold values *inside* the small window between a gap's end and its baseline are
unreliable (they're discarded at the reset). All three replayers implement the
contract: `adminReplayStep` (in-canister audit) hops recorded gaps and resets at
baselines — its zero-mismatch invariant holds **across** a shed;
`verify_ledger.mjs` resets its PoR fold and reports balances as exact from the
latest baseline; the in-app Ledger verifier explains the gap + re-baseline in
its result note. All consult `getLedgerGaps`/`getShedBaselines` (wired 2026-07)
to accept the cross-archive chain discontinuity at a gap as documented rather
than tampering.

**Telemetry.** `getCanisterInfo` exposes `shipFailStreak`, `emergencyRolls`,
`shedEvents`, `ledgerGaps` — all 0 on a healthy exchange; any non-zero value is
a distinct, high-severity `ARCHIVE FAILOVER` event in the log. Tested end-to-end
in `tests/test_archive_failover.sh` (baseline → L1 roll → L2 shed + re-baseline
→ recovery + re-anchor, with the gap width asserted == events dropped, the
post-shed queue asserted == shedTo + baseline rows, and an `adminReplay` fold
ACROSS the gap asserted to reproduce every live balance with zero mismatches on
all four ledgers).

## 9. Rollout phases (REVISED 2026-06-10 — "skip Phase A")

The original Phase A (a stable-Region journal in main acting as the durable
tier before archives exist) is DROPPED: the sim resets regularly, so a
durable tier inside main just accumulates data that resets then have to
awkwardly own. Durability comes from the sidecar from day one; main keeps
only the unavoidable transit queue (§3).

- **Phase A′ — sidecar + capture (one deliverable):** `UserEvent` + seq +
  heap capture queue; hooks at the ~8 capture sites (`recordTrade` covers
  all fills in one place); the archive actor (~200 lines, embedded wasm);
  main spawns archive_0 (the "sidecar") at init/first-event; the shipper;
  delete-on-reset wiring (§5); `journalUnshipped` + chain stats on the
  dashboard.
- **Phase B — chain growth: DONE 2026-07-04** (commit after the fuel batch).
  The shipper pre-spawns the successor at 90% of `_archiveCapEvents`
  (default 10M; dev hook `setTestArchiveCap` pins tiny caps for tests),
  SEALS the active archive at capacity (soft cap — if the spawn is failing
  the active keeps absorbing rather than dropping events) and swaps in the
  successor, which starts MID-TAPE (appendBatch anchors its base seq on the
  first event it sees). Routing table: `getArchives()` (sealed ranges +
  the open-ended active); `archiveExecute` fans its pulls newest-first
  across the chain; the frontend Archive tab pages the active archive then
  continues into sealed ones. `tickArchiveFuel` watermark-funds ALL
  archives (LOW 1T → HIGH 2T, never when main's own headroom is thin);
  `adminUpgradeArchives` upgrades the whole chain in place. Spawns are
  balance-guarded (attaching more cycles than held TRAPS — uncatchable, so
  the guard logs + arms a 10-min retry instead of silently loop-trapping).
  Lock-in: `tests/test_archive_chain.sh`.
- **Phase C — UX:** descriptor-based pagination in the history tabs, generic
  CSV export, Archives dashboard card.
- **Phase D — tamper evidence: DONE 2026-07-04** (same batch). Every event
  carries `prevHash` = the SHA-256 chain hash of its predecessor, computed
  at CAPTURE (main, `lib/EventChain.mo` — a frozen v1 canonical netstring
  form any language can re-derive; NOT candid re-encoding). The archive
  RE-VERIFIES continuity on append (a chain-breaking batch is refused) and
  publishes its head into `certified_data`: `getCertifiedHead()` returns
  head + IC certificate, `verifyChain(from, limit)` re-checks stored
  slices **within one archive only** — an archive anchors at whatever event
  arrives first and is never told its predecessor's head, so the inbound
  join is not (and cannot be) enforced on-canister. The cross-archive links
  hold because capture hashes them at emission; they are *checked* by the
  off-chain verifiers (which carry the hash across boundaries and, since
  W2-04, validate a subnet certificate per segment) and pinned by
  `tests/test_archive_chain.sh` — a shell assertion, not canister
  enforcement. Certificates make a sealed segment tamper-EVIDENT; they make
  it tamper-PROOF only once `setBlackholeAtSeal` is in force (pre-mainnet
  checklist) — until then a controller reinstall could rewrite a sealed
  segment under a fresh certificate, and the verifiers' guarantee should be
  read with that dependency stated.
  The chain starts at `chainStartSeq` (pre-chain events stay unverifiable)
  and dies with the tape on a reset. prevHash is surfaced in the Archive
  tab's CSV/JSON export. Still deferred from the original Phase-D list:
  blackholing (waits for governance — blackholed bugs are forever) and a
  stable-Region spill for the capture queue (no pathological backlog ever
  observed; `journalUnshipped` would surface one).
- **Backfill:** on Phase-A′ deploy, a one-time heartbeat-paced backfill
  ships what still exists in the hot stores (current-epoch trades, deposits,
  adjustments, liquidation events). Anything already trimmed is gone —
  the argument for shipping A′ before mainnet, not after.

## 9b. The ledger of record (added 2026-07-04)

The archive's purpose statement is inverted from "user tax history" to: **the
DEX's balances are DEFINED by a public, tamper-evident ledger — recovery and
Proof-of-Reserves fall out.** Mechanism: every balance mutation in the system
funnels through `Accounts.setBalance` (add/subtract route through it; nothing
else writes the map), which journals the exact signed delta; main drains the
journal into `#delta` archive events every heartbeat (raw balance-bearing
principal, NO owner remap — pools/vault/treasury replay under themselves).
Completeness therefore holds BY CONSTRUCTION — there is no per-feature event
enumeration to keep in sync, and rollback branches self-cancel (the do and
the undo both journal). Semantic events (fills, deposits, …) remain the
human/tax view; `#delta` rows are machine records the UI timeline skips.

The executable form of the claim is the in-canister auditor
(`adminReplayReset/Step/Report`): fold the chain's `#delta` events, diff
against live `Accounts` for EVERY account (users, pools, vault, treasury,
insurance), demand zero mismatches at a quiescent moment. Lock-in:
`tests/test_archive_replay.sh`. The same fold over the public tape is the
PoR liabilities computation; with the certified chain head it is verifiable
by anyone without trusting the operator.

The three CLAIM ledgers fold the same way (2026-07-04, second batch): pool
debt to the vault (`#debtDelta`), vault LP shares (`#lpShareDelta`,
marketId "VAULT" — the live store is vault-wide `vaultLpBalances`; the
per-market map is a legacy shell), and insurance shares (`#insShareDelta`).
These are mutated deep inside the financial libs, so instead of threading
journals through signatures they are SHADOW-DIFFED at each drain: the live
ledger (tens of entries) is compared against a stable shadow of its last
drained state and the changes emit as events — same by-construction
completeness, zero core churn. The auditor reconciles all four ledgers both
directions. Epoch semantics: `resetExchange` keeps user wallets but kills
the tape, so the reset now writes one GENESIS delta per surviving balance
into the new epoch's ledger (the leaderboard re-baselines the same way) —
without this, replay of a post-reset epoch is impossible by construction.

Blackholing landed as **blackhole-at-seal** (`setBlackholeAtSeal`,
controller, default OFF): when ON, a sealing archive's controller list is
emptied — the audited past becomes operator-proof (nobody can rewrite or
delete it; anyone can still fund it, and the watermark task keeps doing
so). Explicit opt-in because it is irreversible: enable at production
deploy (checklist), leave OFF in dev (resets cannot delete blackholed
archives — they leak as orphans). `adminUpgradeArchives` skips immutable
members by design.

Costs/caveats: tape volume roughly triples (a fill ≈ 5 deltas — absorbed by
Phase-B chain growth); adding the journal to `AccountState` and new event
kinds are stable-layout changes (REINSTALL + reseed on the sim — mainnet
ships them from genesis; note adding future UserEventKind tags to main's
stable transit queue needs an explicit migration even though archived blobs
decode fine); reserved-balance moves (pending-match holds) net out by
quiescence rather than being individually evented; margin position RECORDS
(entry prices) are derivable from the archived fills rather than folded.

## 10. Decisions (resolved 2026-06-10)

1. **Order lifecycle:** archive CLOSURES only (`#orderClosed`), not
   per-adjustment noise — executions + closures are tax-sufficient.
2. **CSV:** generic format (time, kind, asset, qty, price, fee,
   counterparty, ids); tax-tool-specific shapes can be added later.
3. **Immutability:** archives stay UPGRADABLE under current controllers;
   blackholing revisited when governance exists.
4. **Public tape:** KEEP `getEventsRange` — archives double as a public
   audit log, consistent with the already-public trade tape.
5. **Phasing:** skip the durable-journal Phase A; sidecar (archive_0) is the
   durable tier from day one; main holds a transit queue only; sim resets
   delete the chain (production-gated). See §3, §5, §9.
