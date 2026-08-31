# AMM & Vault — drain-proof market making for synthetic assets

Status: SHIPPED (backend + arb canister). Companion user-facing pages: in-app
Docs → "The AMM & its vault", "The arbitrageur", "Earn". Predecessor context:
`docs/oracle-settlement-and-transparency.md` (GEPTOR / sealed matching),
`docs/oracle-xrc-fallback-design.md` (the mark), `SPEC.md` §"The AMM".

This document records the vault's economic design after the July 2026 redesign,
why each rule exists, and the adversarial analysis ("war game") the design was
tested against. It replaces the earlier symmetric-skew design, which was
exploited on the play network within hours of seeding.

---

## 1. The incident that forced the redesign

The first seeded play vault ($1.0M, 50% cash / 12.5% × BTC·ETH·SOL·ICP) lost
**$183k in 5.3 hours** to pure trading P&L while external prices moved less
than ±0.2%. Bot flow cycled one pattern:

1. **Drain.** Buy one side of the AMM ladder repeatedly. The ladder refilled
   its tightest levels (mark ± 20 bp) on every 1–2 s requote, so the whole
   sellable inventory went out the door at ~mark + 20 bp.
2. **Whipsaw.** Once short, the old *symmetric* inventory skew shifted BOTH
   ladder mids up by up to ±200 bp — past the 20 bp half-spread — so the AMM
   **bid above the mark** to chase its inventory target: a standing offer to
   buy back, above fair value, the inventory it had just sold at fair + 20 bp.
   Dump into it; repeat in the other direction.
3. Assists: the auto-rebalancer market-bought every 2 s inside a "band" cap
   that had silently grown to ±5% (15 ladder levels × 35 bp), and every fee
   went to the treasury — the vault carried all the risk on spread income
   alone.

The core lesson is old: **a market maker that will cross its own mark to fix
inventory is a money pump.** Uniswap never has this bug because price is a
monotone function of inventory — a round trip through the pool always pays the
pool. The redesign makes the ladder behave like that curve.

## 2. Design principle: the pool is a curve around the mark

The oracle **mark** (robust median of 8 sources, breaker-guarded — see the
oracle docs) is the venue's estimate of fair value. The vault's rules:

* **R1 — never cross the mark.** Every AMM bid < mark < every AMM ask, at all
  times, whatever the inventory state. Inventory pressure may only *widen* a
  side away from the mark, never pull it across.
* **R2 — depletion raises the price of further depletion.** The scarcer a
  reserve, the more the next unit costs (ask premium grows with deficit,
  hyperbolically near the floor); symmetrically, the more overweight a
  holding, the further the bid backs away.
* **R3 — inventory recovers through price, not through chasing.** The AMM
  never takes; it posts the most competitive quote *allowed by R1* on the side
  that needs flow (bid pinned at mark − spread when short; ask pinned at
  mark + spread when long) and waits for the market to come to it.
* **R4 — the vault is paid for the risk it warehouses.** Half of every
  settled trading fee accrues to the vault, on top of the spread.
* **R5 — every off-book path prices no better than the book.** LP mint/burn,
  the external-market simulator, forced-taker slippage caps: nothing lets
  value exit the vault cheaper than trading through the spread.

A round trip through the vault therefore always pays it ≥ the full spread plus
fees — under *any* flow, including deliberately adversarial flow. Replaying
the July attack against the new geometry on a local replica: **3 whipsaw
cycles → vault +$29.2k, attacker −$30.5k**, inventory mean-reverting to target
with no rebalancer.

## 3. Quote geometry (`AMM.mo`, `ammRequote` in `main.mo`)

Let `lean = computeInventorySkewBps(pool, held)` — positive when short of the
inventory target, negative when long, |lean| ≤ `skewIntensityBps` (200).

```
bidSkew = min(lean, 0)                    // long → bids back away
askSkew = max(lean, 0) + floorBarrier     // short → asks carry a premium
bidMid  = min(ref, ref × (1 + bidSkew))   // hard clamp: bidMid ≤ ref
askMid  = max(ref, ref × (1 + askSkew))   // hard clamp: askMid ≥ ref
half    = spreadBps + 0.5 × (volRegime + 2×staleness + 2×breakerGap)
bids    = bidMid × (1 − half − i×spacing),  i = 0…numLevels−1
asks    = askMid × (1 + half + i×spacing)
```

* The **clamp inside `buildQuoteLadder` is the invariant** (R1). It holds even
  if a future caller passes garbage skews; unit tests drive ±100% skews both
  directions and assert the book still straddles the mark, uncrossed.
* The **floor barrier** (unchanged, #92) grows hyperbolically as base
  approaches the 15%-of-target floor and withdraws asks entirely at the floor;
  the **cash floor** (5%) does the same for bids. Sustained one-way flow ends
  with the reserve intact, not empty (verified: `test_inventory_floor.sh`
  drains 100 → exactly 15.0 and stops dead).
* **Depth multipliers** (up to 4× on the deficit side) still apply — size is
  welcome at prices that favour the vault, never across the mark.
* **Breaker widening** is new: while the price-jump circuit breaker holds a
  pending >2.5% candidate, the half-spread widens by the full proposed gap
  immediately. Without it, the frozen mark + tight quotes would be a free
  option during real gap moves for the ~60 s until staleness widening engages
  (`ammBreakerWidenBps`; pends are cleared on `resetExchange` and by the
  dev-only direct price setter, and ignored past their confirm-TTL).
* **Adverse-flow ("hostility") widening is UNIMPLEMENTED — retired 2026-08-20**
  (#49.5, operator-ratified). The formula once advertised a per-counterparty
  adverse-flow term, but its data source was provably never fed: the AMM is
  non-takeable and never a pending-match party, so the term was identically
  zero for its whole life and has been deleted (the empty stable map is
  fossil-parked in `main.mo` for EOP compatibility). Wiring it was REJECTED
  because per-counterparty hostility is an attacker-influenceable input to
  public quotes (widen-by-griefing; Sybil laundering zeroes the score); any
  future adverse-selection protection will be designed fresh against real
  requirements — markout / vol / inventory-based (the AMM already tracks vol
  and inventory) — not by resurrecting this mechanism.

## 4. Inventory recovery & the rebalancer

The 2-second taker-rebalancer is **off by default** (`_ammRebalanceEnabled`,
controller-settable). With one-sided skew the drained side is always quoting
the most competitive price R1 allows, so recovery is passive — and, critically,
*bounded*: the vault never pays above mark to refill, so persistent inventory
deviation costs opportunity, not capital.

The controller-only manual `rebalanceAmm` remains for ops, and the forced-taker
slippage cap (`bandCappedSlippage`, shared with liquidation collateral sales)
is tightened from the full quote band (~±5%) to **spread + one level**
(~55 bp): near-mark fills only; anything else stays warehoused. "Park an order
a few percent out and wait for the vault to take it" no longer has a taker.

## 5. Fee & LP economics

* **Fee split** (`creditTreasury`): `LP_FEE_SHARE_BPS = 5000` — 50% of every
  settled fee credits the vault (`lifetimeVaultFees`, published via
  `getTreasury`), the rest funds the treasury/fuel as before. Same total per
  fill, so Σ-balance reconciliation is unchanged. Rationale: the vault is the
  venue's always-on maker, sole margin lender, and senior bad-debt absorber;
  spread-only compensation was structurally below its risk. A wash trader
  cannot farm the split (pays a whole fee to recover at most their LP share of
  half of it).
* **LP exit fee** (`LP_EXIT_FEE_BPS = 40`): withdrawals pay the pro-rata
  basket × 99.6%; the remainder stays in the vault for remaining LPs. This
  prices the deposit→withdraw round trip strictly above the cost of the same
  swap through the book (~30 bp worst case), closing the "free at-mid basket
  swap" leak. One-time, disclosed, accrues to LPs — not a protocol take.
* **Mint freshness** (`LP_DEPOSIT_MAX_REF_AGE_NS = 60 s`, plus the existing
  breaker-pend gate): deposits mint against marks no staler than the AMM
  itself will quote tightly on. (Residual: sub-2.5% real moves inside 60 s can
  mis-mark a mint by <0.6% — bounded, rare, and mostly eaten by the exit fee;
  a TWAP mint valuation is the known upgrade if it ever matters.)

## 6. Order-flow protections (unchanged + one addition)

Sealed/staged matching, the GEPTOR anti-snipe (`ts < refPriceUpdatedNs`), the
ladder-edge clamp on market releases, and the users-only stall fallback are as
documented in `oracle-settlement-and-transparency.md`. One addition:

* **Staged commitment** (`DEFERRED_COMMIT_NS = 3 s`): a staged taker entry
  (market, marketable limit, or cross-swap) cannot be cancelled by its owner
  for its first 3 seconds — past the ~1–2 s release, so in normal operation it
  has already filled or died. This removes the *free look*: stage an order,
  watch a faster external feed for a second, cancel if the move goes against
  you — a free option the AMM used to write on every staged order. POST-ONLY
  stages are exempt (they can never take the AMM; quoting bots keep instant
  cancel/replace), and the liquidation seize path bypasses the gate.

## 7. The missing arbitrageur (`src/arb/main.mo` + `extMarketSwap`)

**Problem.** These are *synthetic* assets. On a real venue, when the pool
price diverges from the wider market, arbitrageurs move assets between venues
until it converges — that external force is what lets a passive, never-chasing
AMM work. Here there is no external venue: bots can hold the venue price away
from the mark indefinitely, and R1–R3 only guarantee the *vault* doesn't pay
for it — nothing converges the price.

**Solution.** A dedicated **Arbitrage canister** simulates the missing force by
"moving assets in and out" of the venue:

* The backend exposes `extMarketSwap(token, #importBase | #exportBase, qty)` —
  restricted to the wired arb principal — which exchanges base ↔ ICPUSD **at
  the mark ± a 10 bp haircut**, minting/burning the base side exactly like a
  bridge deposit/withdrawal (recorded through `recordExternalFlow`, so
  leaderboard accounting sees capital movement, not fake profit).
* The arb canister ticks every 5 s (heartbeat; `tickOnce` for deterministic
  tests). Per market: **flatten** any base inventory at the mark, then read
  the top of book and act only when it deviates beyond `BAND_BPS = 50`:
  * venue **rich** (best bid ≥ mark + 50 bp): import at the mark, sell into
    the rich bids with a short-TTL limit pinned at mark + 20 bp;
  * venue **cheap** (best ask ≤ mark − 50 bp): buy the cheap asks (limit
    pinned at mark − 20 bp), export at the mark next tick.
* Its venue legs use the **ordinary taker path** — staged, anti-sniped,
  fee-paying, no matching privileges — and the limit pins mean it can *never*
  trade with the vault's AMM (whose quotes never cross the mark). Its
  counterparties are exclusively orders priced off-mark; its profit is
  extracted from whoever pushed the price there. **Manipulation becomes a
  taxed activity.**

**Safety rails** (all enforced backend-side, where they can't be bypassed):
wired-principal-only; mark must be fresh (≤60 s) with no pending breaker jump;
a per-leg price bound (`maxMarkE8`) the DEX checks against its current mark;
per-call cap $5k; hourly import budget $512.5k — exports (the flatten/unwind
leg) are exempt, so a tripped budget pauses imports but can never strand
inventory, and the trip is logged (W4-17); every flow event-logged
(`arb.flow`) and queryable (`getArbStats`). The arb pays normal taker fees, is
not registered (never appears on the leaderboard), and its working capital is
funded (`fundArbitrageur`) and skimmed (`skimArbitrageur`, → treasury) by the
controller as explicit, event-logged external flows.

**War-gaming the arb itself:**

* *Bait the import*: post a rich bid, let the arb import, cancel before its
  sell releases. Cost to the arb: one round trip of the 10 bp haircut on ≤$5k
  (~$10), and every cycle starts with a budgeted import, so the $512.5k/h
  import budget bounds the bleed to ~$1k/h — while the baiter risks their bid
  actually filling and pays fees on every dance. Not economical.
* *Farm a wrong mark*: if the oracle lags a real move, "off-mark" orders may
  be right. The arb stands down on stale marks and pending jumps — the same
  trust bar as the AMM and LP minting — and its caps bound the residual to
  the low tens of $k per hour (sub-breaker mispricing on a $512.5k/h import
  budget; the hourly-exempt export leg stays per-call- and per-tick-capped),
  versus the venue-wide exposure a wrong mark already implies.
* *Supply manipulation*: import/export changes synthetic supply, but only at
  the mark ± haircut and only within caps; it cannot move the mark (external
  medians) and cannot out-trade the invariant. `#production` deployments with
  real custody must simply never wire an arbitrageur (real ones exist there).

## 8. Attack playbook → outcome

| Attack | Outcome under this design |
|---|---|
| Whipsaw (drain asks, dump into bids) | Pays the vault the spread twice + fees (simulated: −$30.5k attacker / +$29.2k vault over 3 cycles) |
| One-way drain to the floor | Progressively dearer (lean + barrier), hard stop at the 15% floor, asks withdrawn |
| Park far orders for the rebalancer | Auto loop off; manual path capped at spread + 1 level |
| Pick off quotes during a >2.5% gap | Breaker widening spans the pending gap immediately |
| Stage → free look → cancel | 3 s commitment ≥ release latency |
| LP deposit/withdraw as an at-mid swap | 40 bp exit fee > trading route; 60 s mint freshness |
| Wash-trade the LP fee share | Pays 1 to recover ≤ 0.5 × LP share |
| Hold venue price off-mark | Arbitrageur imports/exports at the mark until it converges; deviation is taxed |
| Bait/farm the arbitrageur | Bounded by haircut × caps (~$1k/h max); baiter pays fees and fill risk |
| Oracle stall / breaker freeze | Widen → pause (5 min) → panic cancel (10 min); users-only fallback ±2%; arb stands down |

**Residual risks, accepted and stated:** vault inventory beta on genuine
repricings (bounded by floors + 50% cash); systemic oracle risk (median of 8,
USD/USDT blending); sub-breaker stale-mark LP mints (<0.6%, one-shot, mostly
eaten by the exit fee); the last LP's exit-fee residue seeds the next genesis
deposit.

## 9. Constants & knobs

| Constant | Value | Where |
|---|---|---|
| `spreadBps` / levels / spacing | 20 bp / 15 / 35 bp | pool config |
| `skewIntensityBps` | 200 | pool config |
| Floor / cash floor | 15% of target / 5% cash | `AMM.mo` / `main.mo` |
| `AMM_FORCE_REQUOTE_DRIFT_BPS` | 25 bp | `main.mo` |
| `_ammRebalanceEnabled` | **false** | `setAmmRebalanceEnabled` |
| Forced-taker cap | spread + 1 level | `bandCappedSlippage` |
| `LP_FEE_SHARE_BPS` | 5 000 (50%) | `creditTreasury` |
| `LP_EXIT_FEE_BPS` | 40 | `withdrawLp` |
| `LP_DEPOSIT_MAX_REF_AGE_NS` | 60 s | `vaultPricesStale` |
| `DEFERRED_COMMIT_NS` | 3 s | cancel paths |
| Arb band / edge / per-tick | 50 bp / 20 bp / $5k (= per-call) | `src/arb/main.mo` |
| Arb haircut / per-call / hourly | 10 bp / $5k / $512.5k (imports only) | `extMarketSwap` |

## 10. Verification

* Unit: `tests/AMM.test.mo` (never-cross under hostile skews, one-sided
  intent, round-trip pays the vault) — `mops test`.
* Integration: `test_skew_direction` (new geometry on a live book),
  `test_inventory_floor` (hard floor under relentless buying — driver fixed to
  clear the 100× fat-finger guard), `test_rebalance` (default-off + tight
  cap), `test_vault_lp` (exit-fee payouts), `test_treasury_fees` (split
  invariants), `test_staged_cancel_refund` (commit window), `test_arbitrage`
  (rich/cheap convergence, gates, arb profit), plus the pre-existing suite.
* Simulation: scripted whipsaw and floor-drain attacks on a local replica —
  outcomes in §2 and §8.

## 11. Ops runbook

* Deploy: the arb ships with `play_start.sh` (reinstall → `setArbitrageur` /
  `arb.setDex` → `fundArbitrageur` ($1.28M default, `ARB_USD` env) →
  `setEnabled(true)`). `#production` must not wire it.
* Watch: `getVaultValueHistory` (valuePerLP should drift up with fees),
  `getTreasury` (`lifetimeVaultFeesUsd`), `getArbStats`, event tags
  `amm.*` / `arb.*`, and the Status tab cards.
* Levers: `setAmmRebalanceEnabled` (emergency only), `skimArbitrageur`
  (harvest arb profits to treasury), `setAmmSkewConfig` / `setAmmConfig`
  (per-market geometry), `ARB_USD` at seed time.

## Deposit fee weight (W4-11, 2026-08-15)

The concentration fee is priced at the **midpoint weight** of the deposit —
`(cur + legAdd/2) / (T + totalAdd/2)` per leg — not the pre-deposit snapshot.
The snapshot short-circuited to 1.0 whenever the current weight sat at/under
target, so a single deposit from an under-weight state skewed the vault for
free while chunking the same total cost more. The midpoint rule is the
discrete integral: single-shot and chunked deposits price out the same (to
second order), and every unit pays for the skew it causes. Rejection
(`depositRejectsConcentration`) still uses the full post-deposit weight.
