# W4-22 — AMM-swept makers are charged and credited as takers

**Issue:** internal red-team round 2, finding R2 — the role half of
[W4-18](done/W4-18-volume-credit-consolidation.md)
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` MEDIUM (published-contract violation + the level/badge economy *is* the
product on `#play`) / `#production` MEDIUM
**Effort:** M

## Framing, and a correction to the finding's severity

R2 rates this High on the premise that swept makers are harmed. **They usually are not**, and the
report never checked the counterfactual.

`ammSweepResting` exists *specifically to give the swept user a better price*. The design note at
`main.mo:1930-1936` is explicit: the AMM must never take a crossing resting order at the user's own
(maker) price — "that was a windfall to the AMM and a worse fill for the user". The fill price is
the AMM's quote (`MatchingEngine.mo:705`) and the sweep only fires when the user's resting price is
at or beyond it (`main.mo:2339`, `:2364`), so the user is **never** filled worse than their limit.

- Deep cross (a real mark move — the venue's own fixture drops the mark 10.00 → 9.40 against a bid
  at 9.60, `tests/test_volume_credit.sh:70-76`): ~190 bps of price improvement against ~5 bps of
  extra fee. Enormously net positive.
- Shallow cross (slow drift; the ladder snaps to a 5-significant-figure grid, ~1 bp/step,
  `main.mo:2111-2136`): ~1 bp improvement against a 4.5–6 bp fee delta — net worse by ~3.5–5 bps.
- Exact equality (admitted by the `<`/`>` tests): zero improvement, full fee delta lost.

Also: "double fee" is 2× only at L0, and it is **one** fee at the taker rate — nothing is
double-charged anywhere on this path. And "the order would never fill otherwise" is false: staged
releases, the AMM rebalancer (`:3489`, `:3526-3529` — which correctly books the user as maker at
their own price) and the arbitrageur all fill resting orders.

What remains is still worth fixing, in this order.

## 1. `placeLimitOrderPO` violates its own published guarantee (the strongest part, uncited in R2)

The venue's public API doc states post-only is "maker-or-kill at release, **never pays taker**"
(`main.mo:10119`). `releaseDeferred` **deletes** the post-only flag at release (`:2712`), enforcement
exists only at release (`:2754-2772`), and nothing in `ammSweepResting` (`:2301-2430`) consults it.
A post-only order that successfully rests and is then swept pays the full taker rate. With
`MAKER_TENTH_BPS = [50,45,35,25,0]` and `TAKER_TENTH_BPS = [100,90,80,70,60]` (`:786-787`) the L4
row is 0 bps → 6.0 bps — an L4 quoter whose entire economics is maker-fee-zero silently paying 6 bps.

That is a documented-contract violation, not an economics preference.

Same path also bypasses the L4 MM freshness shield: `sweepCtx` sets
`isNonTakeable = func(_, _) { false }` (`:2389`) where `processDeferred` honours it (`:2993`).

## 2. The incentive program mis-measures the population it exists to recruit

Maker attribution keys off the trade record's order ids (`:12491-12492`) and the engine stamps `0`
on the aggressing side unconditionally (`MatchingEngine.mo:754-757`). The swept user is the
aggressor, so `isMaker = false`: their volume lands in `takerVolCur`, never in `lifetimeMakerVol`
(`:857-862`). They lose the `MAKER_W_MULT = 2` weighting in `weightedWinOf` (`:789`, applied `:874`)
— which drives level progression — and all progress toward `BADGE_MAKER_CLOUT` / `BADGE_PILLAR`
(`:812`, `:817`, awarded `:1007`, `:1010`).

The AMM owns most of the book and the sweep is how near-mid resting orders actually fill, so the
*better* a maker quotes, the more of their flow is relabelled aggressive. On `#play` the level and
badge economy is the product, so this lands fully even though the fees are play money.

## 3. Docs and the covering test state the opposite of the code

- `docs/progressive-incentives-design.md:31-32` claims "both ids non-zero (two resting orders
  crossed by a sweep) ⇒ both sides count as makers". The engine cannot produce that on this path.
- `tests/test_volume_credit.sh:67-84` — the only test exercising the sweep — calls the user "the
  swept maker" and "M never takes", but asserts only the role-agnostic lifetime-volume badge. **It
  passes on the wrong behaviour.** This is why W4-18 closed with the role bug intact.

## Confirmed: no compensating mechanism exists

Searched exhaustively. No rebate path (`main.mo:784` explicitly forbids negative maker rates).
`ProtectionCtx` (`MatchingEngine.mo:22-97`) has no role or side field — the engine picks the role,
and every shipped `quoteFee =` binding is plain `quoteFeeFor` (`:2379`, `:2980`, `:3044`, `:3192`,
`:9517`), which takes only `(party, gross, role)` and cannot distinguish a sweep even in principle.
`Types.Trade` is immutable, so no post-hoc re-stamping. Maker volume is written only by
`bumpPartyVolume`.

## Fix

The price mechanic and the fee role are independent; the code currently derives the role from the
price mechanic by accident. The user should get the AMM's price **and** the maker role.

**(a) Fee role.** Add `aggressorIsMaker : Bool` to `ProtectionCtx`, set `true` only in `sweepCtx`
(`main.mo:2378-2392`). At `MatchingEngine.mo:711-713`, when set, map the aggressor's role token
`#takerDebit → #makerDebit` / `#takerCredit → #makerCredit`, leaving the resting side untouched.
Safe by construction: reservations are sized at the taker rate worst case (`main.mo:2503-2506`), so
charging maker can never under-reserve. This also makes `:10119`'s promise true again without
carrying the post-only flag forward.

**Do not** wrap `quoteFee` in `sweepCtx` with a role-flipping closure. `isNonTakeable` is `false`
there, so the re-submitted order can also hit *other users'* resting orders, and a blanket flip
would mis-rate those legs.

**(b) Volume attribution.** Under the same flag, stamp the taker's created order id rather than `0`
at `MatchingEngine.mo:754-757`. `bumpPartyVolume` then credits maker with **zero** change to the
credit loop, preserving W4-18's single-writer invariant. Ordering caveat: the taker's order record
is created after the match loop (`MatchingEngine.mo:840`), so the id must be reserved up front or
the trades patched at the end of `executeLimitOrderProtected` — a small ordering change, not a
redesign.

## Done when

- [x] An AMM-swept maker is charged the **maker** rate — `aggressorIsMaker` in ProtectionCtx
      (true ONLY in sweepCtx), fee-role map on the aggressor leg alone; proven live:
      fee = exactly 5 bps (L0 maker) on a swept fill where taker would be 10 bps
- [x] The swept fill lands in maker volume — the engine PRE-RESERVES the aggressor's id
      (`OrderBook.allocateId` + `createOrderWithId`) and stamps it on trade records, so
      `bumpPartyVolume`'s non-zero-id rule credits maker with zero credit-loop changes;
      seen live on the tape as `buyOrderId = 59` beside the AMM's `sellOrderId = 54`
- [x] §2 asserts `myMakerVolUsd` — **verified red pre-fix** (`myMakerVolUsd=0` while the
      role-agnostic badge passed — W6-12 rule 2's worked example), green post-fix ($10,476)
- [x] The fee-rate pin asserts on the swept maker's own fill (§3): the aggressor-leg fee site
      is IDENTICAL for a rested post-only and a plain limit (the PO flag is consumed at
      release), so this IS the `:10119` promise on the swept path. A PO-specific end-to-end
      choreography hit five interacting venue-physics traps (breaker holds >6% moves, vol-EWMA
      feeds the W4-23 clamp, pend widening, GEPTOR staging of crossing entries, bid-above-ref
      geometry) — documented in the test comment; the follow-up fixture has since LANDED as
      `tests/test_po_sweep_fee.sh` (placeLimitOrderPO 5-arg → rests → swept → fee exactly
      5.0 bps maker where taker is 10.0; red-verified: under `aggressorIsMaker = false` the
      fee equals the taker rate TO THE UNIT and `myMakerVolUsd = 0`) — see the final status
- [x] `progressive-incentives-design.md` corrected (both-ids ⇒ both-makers is now REAL on the
      sweep path; the attribution-loop comment updated to match)
- [x] `isNonTakeable` DECISION recorded in sweepCtx: deliberately bypassed — the sweep fills at
      the venue's FRESH quote (price improvement), the opposite of the stale-quote pick-off the
      shield exists to stop; honouring it would exempt the best quoters from the venue's own
      price-improvement path

---
## Status 2026-08-17 (PO fixture) — follow-up landed: test_po_sweep_fee.sh 4/4, red/green proven

The spun-off post-only end-to-end fixture is done on a scratch worktree
venue (fresh ICP_HOME, gateway.port 0, cold_start --mode full
--no-simulate, #dev). Choreography that dodges all five traps: PO bid 9.60
under ref 10.00 (rests — no funded cross below the ~10.02 ask; kill-gate
uses walkFillable), release via the setAmmRefPrice re-stamp + requote
(the anti-snipe gate needs a fresh price postdating the entry — the dev
override also clears pending jumps), then a single −6.0% hop to 9.40 whose
requote sweeps the bid at the fresh ask. GREEN: fee = 142_186_460 e8 on
$-value 284_372_920_000 e8 — exactly 5.0 bps (L0 maker; taker 10.0) — and
myMakerVolUsd = $10,476 (matches §2's proven figure). RED (sweepCtx
aggressorIsMaker flipped false, reinstall): fee == taker-rate to the unit,
myMakerVolUsd = 0, while §1 rest + §2 sweep stay green — the pin
discriminates on the fix alone. Timers stay paused end-to-end (volume
credit is inline via bumpPartyVolume), so the fixture is deterministic and
self-seeding (survives a bare reinstalled venue: ensureInit creates the
default markets).

---
## Status 2026-08-17 (final) — CLOSED; test_volume_credit 5/5 green, red-verified

---
## Status 2026-08-17 — implemented; red/green cycle pending on the scratch venue

Landed: ProtectionCtx.aggressorIsMaker (true ONLY in sweepCtx; false in the
four other ctx literals + the engine's unprotected()); fee-role map on the
limit-protected immediate branch (aggressor leg taker→maker, resting leg
untouched); aggressor id PRE-RESERVED (OrderBook.allocateId) and stamped on
trade records, order materialized via new OrderBook.createOrderWithId — so
bumpPartyVolume's non-zero-id rule credits maker with zero changes to the
credit loop. The pending path is unreachable under the sweep (onPendingFill
= null), so the flag maps onto the immediate branch alone.
isNonTakeable DECISION recorded in sweepCtx: the sweep deliberately bypasses
the freshness shield (it fills at the venue's FRESH quote — the opposite of
the stale-pick-off the shield stops). progressive-incentives-design.md and
the attribution-loop comment corrected (both-ids ⇒ both-makers is now REAL
on the sweep path). test_volume_credit.sh: §2 asserts myMakerVolUsd (W6-12
rule 2), §3 pins post-only end-to-end (rests → swept → fee ≤ 6bps ≪ taker).
Remaining: red (pre-fix build) + green (post-fix) runs on the scratch venue.
