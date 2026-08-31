# Access Prioritization & QoS — design

**Status: PROPOSAL** (nothing here is implemented; companion to the deposit-gated
`inspect` that already ships). Defines how the DEX guarantees access for the
principals that keep it healthy — depositors always, contributing market makers
first — on today's Internet Computer, and what protocol changes would deepen the
guarantee.

---

## 1. Problem

The deposit gate (see `system func inspect`, `src/backend/main.mo`) already
prices participation: in production a principal cannot make an ingress update
call until a chain-key deposit has registered them (the Bridge's
`creditAndRegister` arrives as an inter-canister call, which bypasses `inspect`
by design). That kills anonymous spam. It does nothing further:

- **Under load, everyone degrades equally.** A canister has a bounded in-flight
  ingress queue; when registered-but-idle principals (or a hostile registered
  swarm — registration costs one deposit, ever) fill it, a market maker's
  cancel bounces exactly like a tourist's.
- **No notion of contribution.** An MM streaming two-sided quotes all day and a
  one-shot depositor get identical treatment at every layer.
- **The canister itself can lose access** — to execution rounds on a busy
  subnet, or to life itself when cycles run dry (the recurring freeze incident;
  there is still no auto-top-up).

Goal, in one line: *those who fund and make the market never lose access to it,
and their intent takes effect first — enforced by on-chain, auditable policy.*

## 2. What the IC gives us (and doesn't)

| Layer | Today | Consequence |
| --- | --- | --- |
| `inspect` | Binary accept/shed per ingress message; runs per-replica, pre-consensus, non-replicated; **read-only** access to canister state; query-class instruction budget; ingress-only (inter-canister bypasses it) | Can *shed selectively*, cannot *reorder*, cannot count (no writes) |
| Ingress ordering | Block makers include pool messages effectively by arrival; per-block and per-canister in-flight caps; **no priority field, no fee market** (reverse-gas is deliberate) | "MM first on the wire" does not exist |
| Execution scheduling | **Compute allocation** (0–100, cycles-priced) guarantees the *canister* a share of rounds | Canister-level QoS is buyable today; per-caller is not |
| Boundary nodes | Central rate-limiting rules (DFINITY/NNS-operated), not canister-configurable | No per-principal QoS at the edge |
| Subnet capacity | Shared with every other canister on the subnet | Third-party congestion is not shed-able by us |

The pivotal architectural fact: **our matching is already sealed-batch.** Every
order stages (`deferredExecs`) and takes effect only at a GEPTOR release
(`processDeferred`). Wire arrival order inside a batch window is *already*
irrelevant — the release pass decides effect order, and the release pass is our
code. Prioritization therefore moves from the network (where we have no lever)
into application state (where we have every lever).

## 3. Design overview — three layers

```
            ┌────────────────────────────────────────────────┐
   ingress  │ L1 ADMISSION (inspect): tier-aware load shed   │  who gets in
            ├────────────────────────────────────────────────┤
   staged   │ L2 EFFECT ORDER (GEPTOR release): tier priority │  whose intent
            │    + MM quote freshness protection              │  lands first
            ├────────────────────────────────────────────────┤
   substrate│ L3 SURVIVAL: compute allocation, auto-top-up,  │  the canister
            │    subnet placement                             │  itself
            └────────────────────────────────────────────────┘
```

A single **tier map** drives L1 and L2.

## 4. The tier model

```motoko
// types.mo
public type AccessTier = {
  #depositor;     // default on registration (first deposit)
  #trader;        // sustained taker/maker activity
  #marketMaker;   // contracted or scorecard-qualified MM
};
// main.mo state
let accessTiers = Map.empty<Text, AccessTier>();   // principalText → tier (absent = #depositor)
transient var _shedFloor : Nat = 0;                // 0=open, 1=shed depositors, 2=shed traders too
```

Rank: `#marketMaker` = 2, `#trader` = 1, `#depositor` = 0. Controllers and the
internal principals (AMM, insurance, treasury, pools) sit outside the ladder —
`inspect` already fast-paths controllers, and internal principals never make
ingress calls.

**Earning `#marketMaker` — the scorecard.** Measured on-chain, not asserted:

- *Quote uptime*: fraction of GEPTOR passes over the window where the principal
  had two-sided resting quotes within `MM_MAX_SPREAD_BPS` of mid, at
  ≥ `MM_MIN_DEPTH` per side. Sampled by the pass itself (it already walks the
  book).
- *Maker share*: maker-side fill value over the window. (`CounterpartyStats`
  was once suggested as the seed of this, but that machinery was RETIRED
  2026-08-20 — #49.5: its map was provably never fed, and per-counterparty
  scoring was rejected as attacker-influenceable. A maker-share metric would
  be built fresh, with a maker/taker split and a rolling window.)
- *Toxicity guard*: an adverse-selection rate below a ceiling — a "maker" who
  only snipes doesn't qualify. (The retired `adverseRate` EWMA is NOT the
  input here; any such measure would be designed fresh — markout-based.)

A new heartbeat task (`HB_TIER_NS = 60s`, alongside the existing `HB_*` family)
folds the window into tier assignments with **hysteresis** (qualify above X,
demote below Y < X, minimum dwell time) so tiers don't flap at boundaries.
`#trader` is the same machinery with lower bars. Manual override
(`setAccessTier`, controller-only → NNS-governed on mainnet) covers contracted
MMs during bootstrap, before the scorecard has data.

**Transparency.** Tiers gate access to a shared venue, so the policy must be
inspectable: a `getAccessPolicy` query exposes the thresholds, the current
`_shedFloor`, and the caller's own tier + scorecard; tier changes append to the
event log like every other silent action.

## 5. Layer 1 — admission: tier-aware load shedding in `inspect`

`inspect` cannot count (read-only), so the *load signal* is maintained by the
code paths that can write, and `inspect` merely reads it:

- Every accepted ingress update bumps a transient per-window counter (one line
  in the shared entry helper); staged-queue depth (`Map.size(deferredExecs)`)
  and ingress-queue pressure are read directly.
- The finalise heartbeat (already at 500ms) folds these into `_shedFloor`:
  `0` in normal operation, `1` (shed `#depositor`) past the soft ceiling, `2`
  (shed `#trader` too — MMs and controllers only) past the hard ceiling.
  Hysteresis again: raise fast, lower slow.

```motoko
system func inspect({ caller : Principal }) : Bool {
  if (Principal.isController(caller)) { return true };
  if (Principal.isAnonymous(caller)) { return false };
  let key = Principal.toText(caller);
  if (Map.get(registeredUsers, Text.compare, key) == null) { return not IS_PRODUCTION };
  if (_shedFloor == 0) { return true };                     // normal: all registered pass
  let rank = tierRank(Map.get(accessTiers, Text.compare, key));
  rank >= _shedFloor                                        // under load: floor rises
};
```

Properties and constraints, stated honestly:

- **What it protects:** the canister's bounded in-flight ingress queue and its
  execution budget. Shedding at `inspect` means low-tier floods never occupy
  the queue slots an MM cancel needs, and never cost replicated execution.
- **Non-replicated ⇒ eventually consistent.** Each replica evaluates against
  its own state height; `_shedFloor` may differ across replicas for a round or
  two. Acceptable: this is a shed, not an entitlement — a message that slips
  through still executes normal checks; one shed over-eagerly can be retried.
- **Cheap by construction.** Two map lookups + two transient reads, far inside
  the query-class instruction budget. The tier map is bounded by the registered
  set (which the deposit gate bounds economically).
- **It cannot rate-limit per principal** (no writes). Per-principal quotas stay
  application-level: the maker/taker fee prices spam from the funded set, and a
  per-caller staged-order cap (cheap `Map` check in `placeLimitInner`) bounds
  queue occupancy per principal — worth adding regardless of tiers.
- **Inter-canister traffic bypasses `inspect`** (that is what makes the
  Bridge's `creditAndRegister` work). A caller routing through their own proxy
  canister skips L1 entirely — but gains nothing: canister-to-canister messages
  queue through consensus with their own backpressure, add a hop of latency,
  and land in the same L2 ordering. L1 is a pressure valve, not the security
  boundary; L2 is where priority is actually enforced, replicated.

## 6. Layer 2 — effect ordering: tier priority at the GEPTOR release

Today `processDeferred` executes the market's staged orders strictly by request
time (`stagedForMarketSorted` → `sortDeferredByTs`). The change is one sort key:

```motoko
// (tierRank DESC, ts ASC): within a release pass, MM intents take effect
// first, then traders, then depositors; FIFO within a tier. Deterministic,
// replicated, and visible in the event log — this IS the priority mechanism.
func sortDeferredByPriority(arr : [DeferredExec]) : [DeferredExec] {
  Array.sort(arr, func(a : DeferredExec, b : DeferredExec) : Order.Order {
    let ra = tierRankOf(a.owner);  let rb = tierRankOf(b.owner);
    if (ra != rb) { return Nat.compare(rb, ra) };   // higher tier first
    Int.compare(a.ts, b.ts);
  });
};
```

Why this is the *right* place: within one batch window the sealed model has
already severed "arrived first" from "fills first" (that anti-snipe severing is
the model's whole point). Ordering inside the pass is pure policy. MM requotes
hitting the book before taker flow in the same pass means takers always meet
refreshed MM liquidity — better prices for takers, less stale-quote risk for
MMs. Everyone benefits; the event log (`[tag]+principal` folding) makes the
ordering auditable after the fact.

**MM quote protection — structural, not racy.** The classic MM ask is "my
cancels process first." On the IC that is not literally implementable: a cancel
is an ingress message, its position in the block is consensus's, and message
execution is atomic — there is no moment where a canister can hold a release
pass and let a not-yet-arrived cancel overtake it. Chasing cancel-priority is
chasing wire ordering again. The sealed model offers something stronger,
already proven for the AMM: **freshness protection**. The AMM's quotes are
non-takeable except on a fresh-price pass (the `isNonTakeable` hook in
`ProtectionCtx` — see the users-only ctx marking the AMM's quotes). Extend the
same shield to `#marketMaker` resting quotes:

```motoko
// releases run with:
isNonTakeable = func(_, makerOwner) {
  Principal.equal(makerOwner, ammPrincipal()) or isProtectedMM(makerOwner)
  // …non-takeable on any pass whose price is NOT fresher than the
  // maker's last requote — exactly the AMM's anti-snipe shield.
};
```

Mechanically: an `mmQuoteStamp : Map<Text, Int>` records each MM's last requote
time; a pass may take an MM quote only if `pool.refPriceUpdatedNs >
stamp` (the MM has "seen" — had the chance to react to — the price that fills
them, because their tier-priority requote/cancel in that same pass runs first).
A stale MM that stops requoting loses the shield after `MM_STAMP_TTL` (and,
via the scorecard, eventually the tier) — protection is earned by the same
behavior that earns the tier, so it cannot be farmed by parking dead quotes.

**Cancels stay immediate.** `cancelMyOrder` already works on both staged and
resting orders and executes the moment its message does; nothing here delays
it. The shield above removes the window in which a cancel could be "too late,"
which is what cancel-priority was ever for.

## 7. Layer 3 — the canister itself

Guaranteed user access is meaningless if the canister loses its own:

1. **Compute allocation.** Set a paid allocation so the DEX keeps its execution
   share under subnet load (today it competes at allocation 0). Straightforward
   settings change; cost scales with the guarantee.
2. **Auto-top-up from the treasury.** The known gap — the canister has frozen
   mid-session more than once. The freeze-check heartbeat (`HB_FREEZE_NS`)
   already computes liquid headroom; wire it to `convertTreasuryToFuel`
   (Stage 2, the commented ICP→cycles CMC path) with a floor and a rate cap.
   Fee revenue funding survival is the correct economics: the treasury exists
   for this (cycles must never come from vault LP funds or user balances).
3. **Subnet placement.** Shared-subnet congestion is the one load source no
   layer above can shed. Near-term: deploy to a quiet subnet. Structural:
   subnet rental — a rented subnet's ingress/block capacity is not shared with
   strangers, making it the closest available thing to a wire-level guarantee.

## 8. What this does not solve, and the IC wishlist

Not solvable in application code today:

- **Wire-level ordering** — priority among messages *within* consensus.
- **Shared-subnet congestion** — traffic to other canisters consuming block
  space (mitigated only by placement/rental, §7.3).
- **Per-principal quotas at the edge** — boundary-node rules are centrally
  operated.

Protocol changes that would deepen the guarantee, in rough order of fit:

1. **`inspect` returns a priority score** (not a bool); block makers order
   ingress by (score, arrival) within the canister's allotment. The canister
   stays the policy author; L1 shedding generalizes into true wire priority
   with one signature change.
2. **Declarative ingress QoS**: a canister-published document (quotas,
   allowlists, per-principal-set weights) enforced at boundary/induction
   *without executing canister code* — cheaper than `inspect`, protects block
   space itself, and consistent across replicas (fixes the eventual-consistency
   caveat in §5).
3. **Canister-configurable boundary-node rate rules** — the existing central
   rate-limit machinery, opened to canister controllers.
4. **Reserved ingress capacity** per canister, the ingress twin of compute
   allocation.
5. User-attached cycle "tips" would also work but cut against the reverse-gas
   model; the canister-authored variants above fit the IC's design language.

## 9. Rollout

- **Phase 0 (now buildable, no behavior change):** tier map + scorecard
  heartbeat + `getAccessPolicy`, tiers observable but not enforced. Per-caller
  staged-order cap. Compute allocation + treasury auto-top-up (§7 — worth
  shipping regardless of tiers).
- **Phase 1:** L2 ordering (`sortDeferredByPriority`) + MM freshness shield.
  Deterministic, easiest to test — extends the now-green release-ordering
  tests (`test_orderbook_priority` pattern: stage mixed-tier orders, assert
  MM-first effect order; shield test: stale-pass take of an MM quote refused,
  fresh-pass allowed).
- **Phase 2:** L1 shedding (`_shedFloor` + inspect change). Test via the
  `test_authorization` pattern: force the floor with a test hook
  (`setTestShedFloor`), assert a `#depositor` ingress call is refused at the
  gate while a `#marketMaker`'s passes, then floor back to 0.
- **Phase 3 (policy):** scorecard thresholds tuned on sim data; NNS-governed
  overrides on mainnet.

Invariants to pin in tests: tier changes are logged; `_shedFloor` never sheds
controllers or blocks the Bridge path (inter-canister, unaffected by
construction); release ordering is FIFO within a tier (no starvation *inside*
a tier); shield TTL expiry makes an idle MM's quotes takeable again; the
scorecard cannot be inflated by self-trades (STP already cancels those) or by
wash volume (fees make it net-negative — the DOS-defense argument, restated).

## 10. Open questions

1. Should `#trader` exist at all, or is a two-tier model (depositor/MM)
   simpler and sufficient? Three tiers gives the shed ladder a middle step;
   two is easier to explain.
2. Scorecard window length (24h rolling vs. epoch-based) and whether
   qualification requires a stake (slashable MM bond in the insurance pool —
   dovetails with the staking tranche).
3. Does the MM freshness shield apply on the *users-only* fallback path
   (oracle stall)? Leaning yes — a stall is exactly when stale-quote sniping
   is most profitable — but it shrinks fallback liquidity to non-MM quotes
   inside the ±2% clamp.
4. Whether Phase 2's ingress-pressure signal can be made robust enough without
   per-principal counters (which `inspect` can't maintain) — or whether the
   per-caller staged-order cap alone suffices and `_shedFloor` keys only on
   queue depth.
