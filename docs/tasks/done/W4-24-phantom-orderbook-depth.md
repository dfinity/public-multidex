# W4-24 — Public order-book depth is unfiltered by maker funding; unfunded cancels are silent

**Issue:** internal red-team round 2, finding R5(c) — **retargeted**: the premise is true and
deliberate, the escalation is wrong, and the real defect is downstream
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` LOW–MEDIUM / `#production` MEDIUM
**Effort:** M

## What is true, and what is not

**True and deliberate:** resting orders hold no reservation. `subReserved` releases the full soft
lock at the top of `releaseDeferred` (`main.mo:2707`) and the rested remainder gets none. The
codebase states it in three places — `:4845-4847` ("a resting order carries no reserve … so its
borrowed working capital looks 'available'") and `:4668-4669`. `poolRestingOrderNeeds` (`:4853`) is
**not** a general earmark; it is a narrow protective subtraction used only by `deleveragePool`, and
does not affect `getMyAvailableBalance`.

**Not true — there is no solvency hole.** R5 escalates this toward a fund-less fill.
`MatchingEngine.mo:317-319` is a **graceful cancel**:

```motoko
if (makerBal < makerNeeds) { ignore OrderBook.cancelOrder(store, best.id); continue matchLoop; };
```

Every fill path re-checks live available balance before settling — immediate `:306-319`, limit
`:724-737`, FOK pre-check `:544-556`. An unfunded maker is removed and the taker walks to the next
level. **No undercollateralized fill exists.**

## The two genuine defects

**1. Phantom public depth — the one that matters.** `getOrderBookDepth` → `OrderBook.getSnapshot`
(`mixins/MarketData.mo:26`, `lib/OrderBook.mo:1250-1278`) reads the raw level aggregate with **no
funding filter**. Arbitrary depth is therefore free to display and costs nothing to create, and
every consumer sizes off it: the arbitrageur (`src/arb/main.mo:233`), the frontend, and any
third-party bot.

This is also the enabler for R5(b) (see [W4-25](W4-25-arb-tick-hardening.md)). A *funded* spoof bid
loses the attacker ~60 bps when the arb's sell fills it at the maker price; the attack only works
because unfunded depth is free and resting cancels carry no commitment window — the 3s anti-free-look
(`main.mo:12737`, `:12753`) applies only to staged entries.

**2. The unfunded-maker cancel is silent.** `ProtectionCtx` (`MatchingEngine.mo:22-44`) has
`onSelfTrade` but no unfunded-maker callback, so `:318` is a bare cancel with no notice. That is
inconsistent with `cancelPoolRestingOrder` (`main.mo:4677`) and `cancelSelfMaker` (`:4685-4691`),
both documented "NEVER silent — the owner gets a notice." A legitimate user whose balance moved
loses an order with no explanation.

## Fix

1. Expose funded depth as a query. The backend already has the exact walker — `walkFillable` /
   `fokFillableDepth` (`main.mo:2612`, `:2687`) computes takeable depth net of maker funding and
   pending locks. Point the arb at it, and decide whether the public `getOrderBookDepth` should
   serve funded depth, raw depth, or both (a raw/funded pair is the honest answer, since the raw
   book is genuine information — the orders exist — and the funded figure is what a taker can rely
   on).
2. Add an `onUnfundedMaker` hook to `ProtectionCtx` so `MatchingEngine.mo:318` records a
   `recordReleaseRejection`, restoring the "never silent" doctrine.

## Done when

- [x] `getTakeableDepth(marketId, side, capPrice)` public query (wraps the FOK-trusted
      `fokFillableDepth` walk); the arb's RICH and CHEAP branches size against it (the raw
      top-of-book price stays the deviation SIGNAL — genuine information)
- [x] DECIDED: `getOrderBookDepth` keeps RAW depth, with the decision written at the mixin and
      in getApiDoc, both pointing sizers at the funded query
- [x] `ProtectionCtx.onUnfundedMaker` reports all three real graceful-cancel sites (market path
      + both limit self-cancel branches; the FOK sim branch cancels nothing) →
      `recordReleaseRejection` notice, restoring the "never silent" doctrine. Compiles, all
      static gates green
- [x] Behavioral red/green: `tests/test_unfunded_maker_notice.sh` — RED on a stubbed
      `onUnfundedMakerNotice` (§4 alone fails: cancel silent, before=0 after=0; §1–3 stay
      green because the graceful cancel itself predates the fix), GREEN 5/5 on the real
      build (scratch worktree venue, 2026-08-17). The stall hypothesis was WRONG: user
      orders never carry a settlement window (sole `orderSettlementWindows` writer is the
      AMM's own quote placement, gated on `pool.protectionWindowSec`) and releases run with
      `getMakerWindow = 0` — nothing defers. The real stall was processDeferred's anti-snipe
      release gate (`d.ts < refPriceUpdatedNs`): with timers paused there is no GEPTOR
      keeper, the test never re-stamped the ref price, so BOTH orders sat STAGED-open —
      and `getMyOrders` includes staged entries, which is why the old §1 "rests" check
      lied. Fixture now re-stamps `setAmmRefPrice` (same price) before each releasing
      requote (the proven test_volume_credit pattern) and pins released-vs-staged via
      `getMyStagedOrderIds = (vec {})`

---
## Status 2026-08-17 (final) — CLOSED; red/green proven on a scratch worktree venue

test_unfunded_maker_notice 5/5 green; red run (hook stubbed to a no-op,
build reinstalled) fails §4 ALONE — cancel executes, taker walks on and
fills, no notice — which is exactly the finding. Venue: worktree pattern
(fresh ICP_HOME, gateway.port 0, gen-did, cold_start --mode full
--no-simulate, #dev). Fixture note: build swaps on the scratch venue used
`icp build` + `icp canister install --mode reinstall` (the play_start
pattern) — a plain `icp deploy` upgrade was refused with IC0503
"Memory-incompatible program upgrade" even for an IDENTICAL wasm (cause
RESOLVED 2026-08-17 by factory task 1786991552: the W2-04 one-shot
migration's domain reads the pre-widening element type, and a venue
cold-started from post-W2-04 code is born widened, so its first plain
upgrade can never match — designed one-shot behavior, not corruption; see
the KNOWN LOCAL SYMPTOM comment at src/backend/main.mo above the actor.
Both tests are self-seeding so reinstall costs nothing).

---
## Implementation notes 2026-08-17 (design settled, code pending)

- New public query `getTakeableDepth(marketId, takerSide, capPrice) : Nat` —
  wraps `fokFillableDepth` (main.mo ~:2810, itself `walkFillable(...).base`),
  baseToken from the markets map. Add `#getTakeableDepth : Any` to the
  inspect msg variant (alphabetical, after #getStagedIndexAudit) + a
  getApiDoc line. Decision for box 2: `getOrderBookDepth` KEEPS raw depth
  (genuine info) with a comment in mixins/MarketData.mo pointing sizers at
  the funded query.
- Arb (src/arb/main.mo): Dex type += the query; RICH branch keeps
  `depth.bids[0].price` as the signal but sizes
  `q = min(getTakeableDepth(mkt, #sell, bpsUp(mark, EDGE_BPS)), capBase)`;
  CHEAP branch sizes `min(min(getTakeableDepth(mkt, #buy, limitPx), capBase),
  maxByCash)`.
- `onUnfundedMaker : (marketId, owner, side, price, qty) -> ()` in
  ProtectionCtx; engine calls it before each of the THREE real graceful
  cancels (market path `makerBal < makerNeeds` at ~:329; the limit path's two
  self-cancel branches where `Principal.equal(buyer|seller, best.owner)`).
  The FOK sim branch (~:567) does NOT cancel — no hook. main.mo: one shared
  `onUnfundedMakerNotice` helper → `recordReleaseRejection(owner, marketId,
  side, qty, null, price, "resting order cancelled mid-match — available
  balance no longer covers it")`; wired in the four real ctx literals +
  sweepCtx; engine `unprotected()` gets a no-op.
- Test: rest a bid AT ref (between the AMM spread) on a #dev venue, drain
  the maker via setTestBalance 0, cross with a taker sell at ref, assert
  the taker's fill walked on gracefully AND the maker's
  getMyReleaseRejections gained the notice. Venue-physics rules from the
  W4-22 fixture apply (timers paused; releases need the ~2s GEPTOR delay
  before the releasing requote; moves ≤5.5%; clear pends before sweeps).
