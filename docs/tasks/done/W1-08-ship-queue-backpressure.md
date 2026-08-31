# W1-08 — The archive ship queue has no backpressure; free tape writes OOM the exchange canister

**Issue:** internal red-team round 2 — found while verifying finding R3; **not the finding R3 reported**
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` HIGH / `#production` HIGH — liveness attack on trading, not on history
**Effort:** S–M

## Framing

R3 reported three fee-free doors that write permanent archive tape, and priced the harm as
stable-region bloat (~$22 one-off, ~$30/yr per 3.3M calls — real, but not High; see
[W3-10](W3-10-minimum-notional-and-zero-mint.md), which carries that half).

The doors are the delivery mechanism. **The defect is that nothing throttles the queue behind
them**, and the wall it hits is the exchange canister's own heap, which halts the DEX rather than
merely growing the tape.

## What's wrong

The shipper drains at most `SHIP_BATCH_MAX = 2000` events per `HB_SHIP_NS = 10s` (`main.mo:7728`,
`:6489`) — **200 events/s, a hard ceiling**. Above roughly 67 `depositLp` calls/s (3 events each),
events are produced faster than they drain and `userEvents` accumulates in the backend's heap.
Nothing applies backpressure:

- **The L2 shed cannot fire.** It requires **both** `queue >= 250_000` **and** `_shipFailStreak >= 3`
  (`main.mo:8167`). A *healthy but backlogged* shipper is deliberately never shed — the comment at
  `:8158-8167` documents the incident that produced that rule. Correct for durability; it also means
  the queue is unbounded whenever the archive is healthy.
- **The shed floor cannot see it.** `recomputeShedFloor` (`:6727-6733`) keys **only** on
  `Map.size(deferredExecs)` — staged-order depth. An attacker who places zero orders never raises
  the floor, so `inspect` never refuses their calls.

Order of magnitude: sustained ~200 calls/s gives ~400 events/s net growth; the code's own figure is
250k events ≈ 230 MB (`:7762`), so on the order of 10 GB/day against a ~6 GiB wall
(`docs/archive-design.md:39`) — main-canister OOM well inside a day. That stops trading, liquidation
and withdrawal, not just history.

Note the archive-capacity path is *not* the binding constraint: forcing an archive roll needs ~3.3M
calls and ≥14 hours purely because of the 200 events/s ship ceiling. The heap fills first.

## Fix

Feed `List.size(userEvents)` into `recomputeShedFloor` (`:6727`) alongside staged depth, so
ship-queue pressure raises the shed floor and `inspect` starts refusing sheddable methods
pre-consensus. The exit-set carve-out (`:8892-8897`) already keeps users able to exit during
congestion, and `W1-05` already made that set explicit.

This is the change that bounds the damage, and it closes the **class**: any future fee-free
tape-writing method reopens the hole otherwise. The per-method minimums in W3-10 close the three
instances but not the class.

## Done when

- [x] Ship-queue depth is an input to the shed floor — `recomputeShedFloor` now runs TWO
      hysteresis signals (`shedTierOf`, per-signal tier state) and takes their max. Bands:
      `SHED_SOFT_SHIP = 50_000` → floor 1, `SHED_HARD_SHIP = 100_000` → floor 2 (2.5× under the
      L2 cap), lowers at the same 0.7 ratio as the staged bands. A healthy shipper clears 50k in
      ~4 min, so only sustained overproduction holds the floor up
- [x] Proven behaviourally — `tests/test_ship_backpressure.sh` (PASS, 10 assertions, scratch
      #dev venue 2026-08-17): timers paused → real faucet writes grow the queue (2 → 14) →
      bands pinned under the depth (`setTestShipShedBands`, dev-gated) → **floor rose to 2 from
      REAL queue depth through the real recompute path** (no pin, zero staged orders — exactly
      the attacker shape) → `placeLimitOrder` refused pre-consensus, `whyAmIRefused` agrees →
      `withdraw` still reached its body (W1-05 exit set) → bands released → floor 0, entry
      admitted. `test_load_shed_exits.sh` re-run green (13✓) against the refactored floor
- [x] The L2 interaction is stated at the gate comment: admission is the backpressure; the
      both-conditions rule stays the last-resort choice to drop history rather than halt trading
- [x] Observable: `getAccessPolicy` gains `shipQueueDepth` + `shedSoftShip`/`shedHardShip`
      thresholds (candid-compatible additions; lint/candid-subtype/hygiene all green)

---
## Status 2026-08-17 — CLOSED

Landed with W1-07's scratch-venue verification cycle. One new dev hook
(`setTestShipShedBands`, controller + dev-gated, classified in the inspect
msg variant) so the gate is testable without 50k real events. The heartbeat
call site keeps its inline-by-choice property (still trap-free: compares,
two O(1) sizes, `Nat.max`).
