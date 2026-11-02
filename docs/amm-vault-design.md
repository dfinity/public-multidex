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
  zero for its whole life and has been deleted (the empty stable map was
  fossil-parked in `main.mo` for EOP compatibility until the fifth one-shot
  migration dropped it on both mainnet targets, 2026-09-03). Wiring it was REJECTED
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
* **LP exit fee** (`LP_EXIT_FEE_BPS = 40`): withdrawals pay the redeemed
  value (NAV per share, below) × 99.6%, in kind from the held basket; the
  remainder stays in the vault for remaining LPs. This prices the
  deposit→withdraw round trip strictly above the cost of the same swap
  through the book (~30 bp worst case), closing the "free at-mid basket
  swap" leak. One-time, disclosed, accrues to LPs — not a protocol take.
* **Mint freshness** (`LP_DEPOSIT_MAX_REF_AGE_NS = 60 s`, plus the existing
  breaker-pend gate): deposits mint against marks no staler than the AMM
  itself will quote tightly on. (Residual: sub-2.5% real moves inside 60 s can
  mis-mark a mint by <0.6% — bounded, rare, and mostly eaten by the exit fee;
  a TWAP mint valuation is the known upgrade if it ever matters.)
* **Redeem freshness** (task 1788513125, 2026-09-04): `withdrawLp` runs the SAME
  three held-leg checks (unpriced, breaker-pended, stale — one shared
  `vaultHeldLegMarkIssue`, refusing "LP withdrawal paused: …" with the deposit
  texts' wording) but ONLY while `NAV != holdings`, i.e. while the loan book,
  the impairment reserve or insurance arrears are non-zero. Why the asymmetry
  is exact, not a threshold: redemption pays each leg as
  held × f × keepBps × NAV/holdings (below). At NAV == holdings the ratio is 1,
  every leg is the exiter's own slice and the marks CANCEL — a mis-marked leg
  is handed to the exiter pro rata, the stayers keep their slices, nothing
  moves between them; so a vault with no loans can always be drained in kind
  whatever the feed is doing (the property the GHSA-h888 final-exit sweep and
  the #54.6 zero-basket guard rely on). With loans out, the exiter's loan-book
  claim — a cash receivable, price-invariant — is paid as an extra L/H slice
  of the held basket at the FROZEN mark: an up-pend on a held leg gives the
  exiter ≈ jump × (loan-book share) × (their slice) at the stayers' expense,
  the class M1 closed on the mint side, timeable by anyone watching the feed.
  `getMaxInstantWithdraw` keeps quoting through a pause and reports the exact
  refusal text in `withdrawalPaused : opt text` (null when an exit would go
  through). Pinned in `tests/test_breaker_widening.sh` §4: a pended exit at
  zero utilisation redeems (control), the same pend under a live loan refuses,
  a backdated (stale) mark refuses both sides, a fresh mark lifts it. Dust
  note: a repaid loan leaves ~$0.001 of principal, so a vault that has ever
  lent stays gated on a pend / stale mark until that clears — a "retry
  shortly" refusal, the deposit side's existing behaviour, never a loss.

### Redemption at NAV + pro-rata instant liquidity (operator decision, 2026-09-03, task 1788465539)

**What it replaced.** Until 2026-09-03 `withdrawLp` paid every share redeemed its
fraction of what the vault physically HELD and *forfeited* that share's slice
of the loan book to the LPs who stayed — documented at the time as "the
intentional loan-book undershoot" and "the safe direction". At 50% utilisation
an exiter received half of NAV per share, permanently; partial withdrawal did
not help (the haircut was per share). Mint priced against NAV, so entry and
exit disagreed and the leaderboard's NAV credit was not realisable. That was a
product decision left open; it is now made.

**The model** (`withdrawLp`, `getMaxInstantWithdraw`, `VaultMath.redeemValue`
/ `redeemLeg`, and — since task 1788475756 — `VaultLock.withinCap` /
`capLp` / `capUsd` / `lockAfterExit` / `settle`):

1. **Every share redeems at NAV per share** — `valuePerLP` =
   (held basket + loan book − insurance arrears) / supply, the SAME figure
   deposits are minted at. A deposit-then-withdraw round trip is therefore
   exactly −fee by construction, on every axis: the loan book is neither
   forfeited nor paid before it is collected, and the arrears liability is
   deducted ONCE, inside NAV (GHSA-3j44's separate W spreading at payout is
   subsumed — mint and redeem read one number).
2. **Capped by liquidity, pro rata — and race-proof under repetition.** A
   loan cannot be handed out in kind, so an LP's maximum INSTANT withdrawal
   is their share of the HELD basket. The share is computed over UNLOCKED
   shares (the locked-share model, next paragraph): with ℓ = the caller's
   locked shares and Λ = the vault's locked total,
   `withdrawableNowUsd = (lpBal − ℓ)/(supply − Λ) × holdings × (1 − fee)`,
   and a request of `lpAmount` is accepted iff `lpAmount ≤ lpBal − ℓ` and
   `lpAmount × NAV × (supply − Λ) ≤ (lpBal − ℓ) × holdings × supply` (exact
   integers, no rounding). With no locks that is the stateless
   `lpAmount × NAV ≤ lpBal × holdings` of 2026-09-03, byte for byte. A
   request past the cap is REFUSED with an error naming the cap and the
   reason ("$N of your $NAV is lent out … Withdrawable now: $X"); nothing is
   clamped, nothing is queued.

   **Locked shares (operator decision 2026-09-06, task 1788475756;
   `src/backend/lib/VaultLock.mo` carries the derivation).** The stateless
   cap held F1 for ONE call: after taking their share an LP's retained
   shares again claimed a pro-rata slice of the REMAINING cash, so repeated
   max exits drained the stayers' liquidity harmonically (two equal LPs,
   H = L: ten successive max exits by one took ≈ 91% of their NAV as cash
   and left the other's instant cap at ≈ 8% of theirs). Now every LP holds
   ℓ_i LOCKED shares (a per-LP raw lock × one global lock-scale index,
   10^24 fixed point) and the cash is shared by UNLOCKED shares only: LP i's
   cash entitlement is e_i = (s_i − ℓ_i)/(S − Λ) × H, which sums to H by
   construction. On a withdrawal of x shares the exiter's remaining shares
   are locked by Δℓ = (S − Λ)·x·NAV/(S·H) − x — exactly what keeps every
   OTHER LP's e_j unchanged — so a max exit leaves the exiter fully locked
   (cap 0, however often they call) and the stayers' caps where they were
   (they rise by their slice of the 40bp fee the exit left as cash). A net
   repayment R hands cash to every LP pro rata to their LOAN claim (all
   loans are one class), which in the lock representation is one COMMON
   factor on every lock, c = S·(H − R)·Lx_post / (H·S·Lx_pre − Λ·R·NAV)
   with Lx = NAV − H — applied to the index, no per-LP loop; c = 0 (every
   lock released) at a full repayment. Issuance, interest and mark moves
   change no lock. Repayment is detected as the shrink of the per-token
   loan-book units since the last settle, priced at current marks, and the
   index settles at every loan-book mutation (task 1788727876:
   `reprovisionPool` — the borrow at the fill, every repayment, write-off and
   seize — runs `settleVaultLocksOnMutation`, synchronously, on the
   provision it just refreshed) with the LP touches (withdraw, deposit, the
   heartbeat beat, and the query view) as the belt — no BorrowEngine hooks,
   the lib stays pure. Locked shares can never claim more loan value
   than exists (Λ·NAV ≤ S·Lx, clamped at every settle; every lock clears
   when NAV ≤ H). Locks round UP, caps and the index DOWN (F5). A deposit
   mints UNLOCKED shares (its cash joins the shared liquidity — F6). State:
   `vaultLockRaw`, `vaultLockRawSum`, `vaultLockScale`, `vaultLockLoanSnap`
   — additive stable fields; cleared with the vault and at zero supply.

   **The quote drifts; the Earn card under-asks (operator policy (a),
   2026-11-01, task 1788746837).** The cap is exact at the instant it is
   quoted and the settlement check is the same inequality, exact — but a
   withdrawal is staged and settles at the next fresh mark (the sealed
   pipeline below), NAV carries the loan book, which ACCRUES (every pool
   interaction and the 30 s sweep; every mark update and heartbeat beat too
   once task 1788736589 lands), and every mark move re-prices H and NAV
   besides. So a request for EXACTLY `withdrawableNowLp` is refused — naming
   a cap a few base units under what was asked — whenever any of those lands
   between the quote and the settlement: on `test_vault_lp` §7's fixture a
   few seconds of 5 % interest on a $135k book move the cap by thousands of
   base units (Δcap = cap × ΔL / NAV); on a live feed the window is a few
   seconds out of every thirty. The decision: the BACKEND STAYS EXACT (no
   tolerance, no clamp, no new reply shape — the rule above stands) and the
   FRONTEND under-asks: the Earn card's "max now" is `withdrawableNowLp ×
   (1 − 0.01 %)`, floored to the LP base unit (`LP_WITHDRAW_DRIFT_ALLOWANCE
   = 1e-4`, one named constant, and `lpWithdrawMaxFill` in
   `src/frontend/src/main.js` — the placeholder's figure and the one-tap Max
   button beside the field, task 1793553361, both fill through it), named as
   such beside the figure and in the card's note. 0.01 % covers ≈ 22 days of
   accrual against the seconds the
   race spans; what it leaves — $10 on a $100k position — stays the LP's
   (≈ 0.01 % of their shares stay unlocked after such a max exit, with a cap
   of their own) and is theirs to take later, never the stayers'. The
   suite's own "max exit" fixtures ask the same way (`underask`, §7 / §8 /
   §8b) and settle under a mark re-stamp between quote and settlement; §7
   also stages the race itself — the exact quote, requested after an
   accrual, is cancelled — and every "cap + 1 is refused" pin stays at the
   exact cap.
3. **Burn only what is paid.** The shares an LP does not redeem stay theirs —
   one share class, so they mark at the common `valuePerLP`, keep earning
   spread, fees and interest exactly like every other share, and become
   redeemable as repayments raise holdings. The constraint is the TIMING of
   withdrawals, not a loss of equity.
4. **Paid in kind** from the held basket, each leg = held × payout / holdings
   in one `mulDiv`, floored (the vault's favour at the base unit; a BTC leg
   can fall short of the quote by one satoshi). The GHSA-h888 zero-supply
   sweeps (final exit and genesis deposit) are unchanged.
5. **Query surface.** `getMaxInstantWithdraw()` (caller-scoped) returns
   `{withdrawableNowUsd, withdrawableNowLp, totalNavUsd, lpBalance,
   lentOutFraction, vaultHoldingsUsd, vaultLentOutUsd, vaultNavUsd,
   exitFeeBps, …, lockedLp, vaultLockedLp, vaultLockedNavUsd}` (the last
   three since task 1788475756: the caller's locked shares, the vault's
   locked total, and the NAV those locked shares carry). The Earn card shows
   "withdrawable now / total" and the vault's lent-out share, and — BEFORE a
   deposit — what fraction of a deposit made now would be instantly
   withdrawable: `(H + V)(1 − fee) / (NAV − lockedNAV + V)` — only unlocked
   shares share the cash (a deposit's cash joins the pool's shared
   liquidity; correct, never a surprise).

**Fairness properties, each pinned in `tests/test_vault_lp.sh` §7 (F1–F6):**
no LP can take more than their own share of held assets — in one withdrawal
or across ANY number of them: an Earn-card max exit (the cap less the 0.01 %
drift allowance, above) leaves the exiter's cap at the allowance's residue
and every other retained share locked, one base unit past that residual cap
is refused naming it, five further max exits take at most the residue —
across every exit one share of held cash, to the cent — and the other LP's
cap is unchanged bar their slice of the fee — so a first-come drain of the
cash is impossible by construction (F1); mint and redeem at the same NAV, so an exit
neither penalises the exiter nor gifts the stayers — `valuePerLP` and every
other LP's NAV are untouched (they rise by the retained fee only), the exit
removes exactly the exiter's share of cash and leaves the loan book
untouched, and the retained shares are worth the exiter's share of the loan
book (F2); fee and arrears applied once (F3 — the §5 round trip with arrears
outstanding is exactly −$160 on $40k); retained shares earn identically and
redeem after a real repayment: a PARTIAL repayment (closing one of two
borrowing pools) releases the exiter's cash pro rata to their loan claim
(R × NAV_i / Lx) and shrinks their lock without clearing it, the full
repayment clears every lock and the cap equals the balance (F4); Σ LP balances == supply, payout ≤ quote by at most one base unit per leg
(F5); the pre-deposit prediction matches the post-deposit quote (F6).

**Accepted #play trade-offs (risk disclosed, not hidden).**
* Both LP sides are mark-gated (the "Redeem freshness" bullet above): mint
  always, redeem while NAV != holdings. The redeem gate is what stops a
  feed-watcher exiting into a frozen up-mark and taking the stayers' share of
  the held basket; the zero-utilisation exit stays ungated because there the
  in-kind basket is price-neutral by arithmetic, not by policy.
* NAV marks the loan book at face value net of KNOWN arrears AND net of the
  per-loan impairment reserve (next section, task 1788475754). A default
  beyond what the reserve provisioned still hits NAV for whoever holds shares
  at that moment — the reserve narrows the window, it does not close it: a
  loss larger than the 15% stress, or one realised between two mark updates,
  is borne by the holders of record. Inherent to mark-to-market.
* ~~The lock model's repayment detection is LAZY … a repay-then-reborrow of
  the same token BETWEEN two touches nets to nothing and releases no lock~~
  — no longer accepted: since task 1788727876 the index settles at every
  loan-book mutation (repay, write-off, seize AND the borrow at the fill,
  which moves the snapshot so the reverse order cannot net either), so a
  repayment's release lands in the same message as the repayment; the LP
  touches remain only as a belt. ~~What remains approximate in the detection
  is not timing but CLASSIFICATION: the units-diff cannot tell a write-off
  or seize from a repayment, so a loss written off scales the locks as if
  its USD had come back as cash~~ — closed by task 1788752774: the
  write-off site (`absorbBadDebt`, via `reprovisionPoolAfterWriteOff`)
  nets the uncovered write-off out of the shrink before the settle
  (`settleVaultLocksNet`), so a pure loss is `settle(…, repaidUsd = 0)` —
  no lock moves, every e_i is unchanged, only the consistency clamp may act.
  Classification is by SITE, not by measurement: every other mutator is
  cash-backed and keeps scaling the locks — repayments, the seize (the
  collateral lands in the basket in kind, so H rises by what the debt fell,
  net of the penalty the fund is paid), the netted pair (both legs in kind),
  and the fund's covered slice (it pays the vault in the same message; a
  seize that ends `#insolvent` is one message of seize + covered cash +
  uncovered loss, and only the loss is netted). What remains, disclosed
  rather than approximate: (i) the loss itself lands on NAV ONE SHARE
  CLASS — NAV_i = s_i·NAV/S always, so a locked LP's loan claim falls by
  U·s_i/S where the per-LP model would say U·λ_i/Lx; their cash entitlement
  is unchanged either way, and the difference is bounded by the loss; (ii)
  a loss large enough that the locked shares' NAV exceeds the loan value
  left (Λ·NAV > S·Lx) trips the clamp, which releases locks by exactly the
  excess — the one lock movement a loss can cause, again bounded by the
  loss; (iii) the netting rounds in the vault's favour (the diff prices the
  units DOWN where the write-off was booked UP), so a lock releases by base
  units less than the cash that came, never more. Interest accrued between
  two settles is likewise measured only net of what it grows the book by.
  The fee an exit leaves behind lands on the UNLOCKED shares' cash: a
  stayer's cap rises by their slice of it, a fully-locked exiter's does not
  (their NAV still does — one share class).
* A close the pool can cover repays its loan IN FULL (task 1788515291): the
  "~$0.001 dust residue" a repaid loan used to leave was never rounding — it
  was the interest accrued between the close's own accrual and the fill's
  settlement message, which `deleveragePool` read the debt BEFORE and so
  never asked for. It now accrues first, so the borrower pays that interest
  too, the loan entry is deleted, `vaultLentOutUsd` returns to exactly 0, the
  LAST LP's cap equals their balance, and the redeem-side mark gate (above)
  disarms; nothing is forgiven or booked anywhere. Only a pool that cannot
  cover its debt leaves a claim on the book — a real loan, handled by the
  liquidator, not dust.

A redemption QUEUE (ordering pending withdrawals as loans repay) is
deliberately NOT built: with pro-rata caps every LP can always take their
share instantly.

### Per-loan impairment reserve — the loan book net of expected loss (task 1788475754, 2026-09-04)

**The gap it closes.** NAV carried every loan at face value (principal × mark)
until the loss was REALISED — a liquidation that came up short, `absorbBadDebt`
writing the residual off. Between a pool going under water and its write-off,
NAV was too high by exactly the coming loss: an LP who redeemed in that window
took face value for loans that were about to be written down, and the LPs who
stayed ate the whole loss. A credit book is marked net of expected loss, not at
face; this section is that mark.

**The provision, per pool** (`VaultMath.expectedLoss(debtUsd, collUsd)` — pure
integer math, pinned at the band edges in `tests/VaultMath.test.mo`). Every
margin pool `p` carrying debt is read through the SAME health metric the
liquidator acts on (`BorrowEngine.getHealth`): `D` = debt at marks (rounded UP),
`C` = LTV-weighted collateral (Σ balance × mark × LTV, rounded DOWN — the LTV
IS the liquidation haircut, so `C` = "collateral × (1 − haircut)"), and
`h = C / D`. Expected loss = PD × LGD:

```
LGD(p) = max(0, D − C × (1 − IMPAIRMENT_STRESS))        IMPAIRMENT_STRESS = 0.15
PD(h)  = 0                          h ≥ MAINTENANCE (1.15)   performing — no provision
       = (1.15 − h) / 0.15          1.0 ≤ h < 1.15          liquidatable — ramps 0 → 1
       = 1                          h < 1.0                  under water on the haircut basis
EL(p)  = PD(h) × LGD(p), rounded UP (the vault's favour)
```

* *LGD* is the loss if the loan defaults and the haircut collateral gaps by a
  further 15% before the seizure completes. 15% is the size of the maintenance
  cushion itself (1.15 − 1.0): the stress asks what the collateral is worth
  after the buffer that triggered the liquidation is consumed a second time.
  The LTV haircut is a margin REQUIREMENT, not a loss estimate — a loan at
  h = 1.0 still liquidates whole at today's marks (raw BTC collateral is
  D/0.9); the provision is what a reserve is for: the adverse case, released
  when it does not happen.
* *PD* is the "distance to maintenance" the brief asks for. At or above
  maintenance the loan is what the operator's own ladder calls adequately
  secured — provisioning there would tax every honest LP for every loan on the
  book, i.e. a tax on utilisation. Below maintenance the loan is in the
  liquidator's queue and the exposure is the gap risk before seizure; the
  ramp is linear in `h` so it is continuous at both edges (0 at 1.15; at 1.0 it
  meets the under-water band, where PD is 1 and the specific shortfall
  dominates). Under water the full stressed shortfall is provisioned.
* Monotone in the right directions: falls as `h` rises, rises as `C` falls,
  equals `D` at `C = 0`, is 0 at `D = 0`. Band-edge values for D = $100k:
  h = 1.25 → 0; h = 1.15 → 0; h = 1.075 → $4,312.50 (PD ½ × LGD $8,625);
  h = 1.0 → $15,000; h = 0.5 → $57,500; C = 0 → $100,000.

**No double count with the insurance fund's first-loss.** `insuranceValueUsd`
(the fund's ICPUSD, `insurancePoolValue()`) is the JUNIOR tranche:
`absorbBadDebt` pays `min(residual, fund)` from the fund to the vault before
the vault loses a cent, and NAV never included the fund's cash (it is the
insurance principal's balance, not the vault's). Provisioning the gross
expected loss would therefore deduct from NAV a loss the fund contractually
bears first — the double count. So the vault-level reserve is the EXCESS of
the book's expected loss over the fund, netted in AGGREGATE:

```
reserve R = min(L, max(0, Σ_p EL(p) − insurancePoolValue()))
NAV       = H + (L − R) − W        (H held basket, L loan book, W insurance arrears)
```

* Aggregate, not per loan: the fund covers realised losses in order of
  occurrence out of ONE balance; netting each loan against the whole fund
  would let N provisions hide behind the same dollar.
* The fund's cash only — not `insuranceOwedUsd` (W, what the vault owes the
  fund). `absorbBadDebt` can draw only on cash the fund actually holds, and
  W > 0 is precisely the cash-poor cascade state in which the vault has NOT
  delivered it; counting undelivered arrears as first-loss capacity would
  have NAV claim protection that does not exist yet. The reserve is therefore
  overstated by at most W while arrears are outstanding — the conservative
  direction, and W settles every heartbeat as cash returns. Arrears stay a
  liability deducted ONCE (F3 is unchanged: mint and redeem still read one
  NAV).
* `R ≤ L`: the reserve can never exceed the book it impairs (each `EL ≤ D`,
  but D rounds up while L rounds down — the clamp absorbs the base units).
* The netting is deterministic: `max(0, ΣEL − I)` is the loss the vault would
  bear if every provisioned loss were realised today, not an expectation over
  outcomes (which would be larger by convexity). The 15% stress inside each
  EL is what carries the conservatism, not the netting.

**Where it is computed, and when it moves** (`refreshVaultImpairment`,
`vaultImpairmentReserveUsd` in `main.mo`). The scan is one `getHealth` per
pool (bounded by `HEAT_MAX_POOLS`, the same bound as the heat map and the risk
summary) and its result is CACHED in three stable scalars
(`vaultImpairmentGrossUsd` = Σ EL, `vaultImpairedLoans`,
`vaultImpairmentComputedNs`); the netting against the fund and the `L` clamp
are applied LIVE at every NAV read, so the reserve tracks the fund balance and
the loan book instantly and only the per-pool health scan is cached. The
cache is refreshed at every moment its inputs move: every mark update (the
dev override and both feed arms of `applyFreshAggregate` — the provision is a
mark-to-market figure and NAV's basket is marked live at the same instant),
every heartbeat beat with the risk summary (covers borrow/repay/liquidation
between mark updates), and SYNCHRONOUSLY at the top of `performLpDeposit` and
`withdrawLp` — so the two operations that convert NAV into shares or shares
into assets always price on a fresh scan, and no LP can enter or leave on a
stale provision. Between full scans the LOAN BOOK itself moves, and a staged
fill lands on the mark update that releases it — AFTER that call's own scan —
so every loan-book mutation re-provisions the ONE pool it touched
(`reprovisionPool`, task 1788480502): the settlement hook's repayment
(`deleveragePool`), a new borrow (`poolFundForFill` — the fill-time borrow of
H-34 / D5 (d); `openPosition` itself borrows nothing), a seize (`tryLiquidate` on
#liquidated / #insolvent, `settleNettedPair` for both netted sides) and a
write-off (`absorbBadDebt`). Each is one `getHealth` on that pool; a transient
per-pool map (`vaultProvisionByPool`, poolId → EL) holds the split so the
aggregate moves by the delta — no O(pools) rescan per fill. The map is
derivable, hence transient (no stable-schema change): after an upgrade the
first incremental request runs the full scan once instead, so the stable gross
never double-counts. A repayment therefore releases its provision in the same
message that books it. Queries (`getVaultValue`, `getMaxInstantWithdraw`,
`getVaultImpairment`, the leaderboard's NAV credit) read the cache, which is
now exact for the loan book and at most one mark-update behind for health
moves that are pure price moves. A world wipe zeroes the cache (map included)
with the loan book.

**Release.** The provision is a pure function of the loan's current health at
current marks — it releases the moment health recovers (a repayment, a
collateral top-up, the price coming back) and disappears with the loan on
close, so honest LPs are never permanently taxed: the deduction lives exactly
as long as the risk does. If the loss IS realised (`absorbBadDebt`), the
write-off drops `L` and the provision for that pool at the same time — NAV
moves only by the difference between the realised loss and what was
provisioned, which is the point.

**Disclosure.** `getMaxInstantWithdraw` carries `vaultImpairmentReserveUsd`
(the vault-level reserve) and `provisionedLossUsd` (the caller's pro-rata share
of it, i.e. how much lower their NAV is than face value); `getVaultImpairment`
publishes the full figure set (gross Σ EL, the fund netted against it, the
reserve, impaired-loan count, the stress and maintenance constants, the scan
timestamp — and, since task 1788733762, `impairedDebtUsd` /
`impairedCollateralUsd`: the Σ D and Σ C of the impaired pools exactly as the
scan priced them. A pool's debt accrues interest on every read; a WORLD-driven
scan (a mark update, the heartbeat beat) accrues each pool's loans to the scan
instant before pricing it (task 1788736589 — D is then the liquidator's own
figure at `computedNs`, and every scanned pool's `lastAccrualNs` moves with
it, the cadence the 30 s sweep already accrues at; cost HEAT_MAX_POOLS × one
≤5-entry map rewrite per scan), while an LP-driven scan (`performLpDeposit` /
`performLpWithdraw`, the staged settlement included) prices the book as
BOOKED: an LP's own message must not move the NAV they were quoted at (the
Earn card under-asks the cap by 0.01 % for the accrual a settlement STAMP
books — 1788746837 — and the backend stays exact). So a reader re-deriving the
gross from a later `getMyMarginPools` read lands only the scan-to-read seconds
of interest above the published D; from the published pair,
`gross == VaultMath.expectedLoss(D, C)` holds to the base unit for a one-pool
book, and test_vault_lp §8 pins exactly that plus the scan-to-read bound);
`getMarginRiskSummary` carries the reserve beside its
`insuranceValueUsd`. The Earn card shows "Provisioned for expected loss" beside
"Withdrawable now / total" — the mark-down is disclosed, not hidden.

**Posture: live in every posture, no gate.** The brief allowed a #play no-op if
gated. Not taken, on the merits: the posture doctrine is `#dev` = `#play` +
dev hooks with IDENTICAL economics, and a gate would make the play-era NAV
(and the leaderboard's LP equity, decision D) mean something different from
the production one — the exact divergence the doctrine exists to prevent. The
figure is a disclosure; there is no fairness argument for hiding it from play
LPs, and the reserve is zero on a healthy book (every pool at h ≥ 1.15), which
is the normal state of the seeded venue.

**Pins.** `tests/VaultMath.test.mo` (band edges, monotonicity, netting,
clamp); `tests/test_vault_lp.sh` §8: a near-liquidation pool lowers
`valuePerLP` by the reserve BEFORE any liquidation (loan book unchanged), the
reserve equals Σ EL − fund from the pool's own health figures, an exiter at
that NAV is paid the provisioned figure (strictly less than face), and the
provision releases on repayment (close) with the price unchanged.

### Sealed LP requests — deposits and withdrawals settle at a post-request mark (operator decision 2026-09-06, task 1788503312)

**The gap it closes.** Both LP doors price against the basket's `refPrice`
marks and refuse when a HELD leg's mark is older than
`LP_DEPOSIT_MAX_REF_AGE_NS` (60 s). Measured on a seat venue (task
1788503312, 600 s at 3 s samples, 40 intervals): every pool's mark advances in
~60 s steps — by CODE, not by replica artefact: the heartbeat dispatches a
refresh every `HB_PRICE_NS` (30 s) but a pool is fetched only once its mark is
≥ `PRICE_STALE_AFTER_NS` (45 s) old, so a pool marked at t is skipped at the
next beat (~30 s) and refreshed at the one after (~60 s): the per-pool cadence
quantises to two beats, plus beat overshoot and sequential-fetch latency. The
60 s grace therefore EQUALS the cadence and every pool sits over-grace for
0.1–4.5 s before nearly every refresh ("LP deposit paused: … refPrice is
stale" flickers; the staleness widening engages on the same ticks). Raising
the grace would only widen the window in which a depositor can mint against a
mark the market has left; lowering the stale gate would double outcall spend.
The structural fix is the sealed model's own rule.

**The rule (`depositLp`, `withdrawLp`, `processStagedLp` — the doors themselves
since apiVersion 6.0.0, task 1788731608; 5.1.0 landed the rule additively as
`stageLpDeposit` / `stageLpWithdraw`, since dropped).** An LP
request is STAGED, not settled: the request record carries `ts` (its stamp)
and settles at the first NAV whose basket marks ALL postdate it — the
price-postdates-entry rule parked entries release on (anti-snipe: the
depositor commits BEFORE the settlement price is fetched, so a stale mark is
unexploitable by construction), in the multi-market form the cross-swap uses
(`crossSwapLegFresh`: every market the request waits on has done a fetch
DISPATCHED after the request). Concretely, for a request R:

* `waitingOn(R)` = the `X-ICPUSD` market of every HELD vault leg (balance > 0
  — the same set `vaultHeldLegMarkIssue` gates), plus the deposit's own market
  for a deposit (its base leg is priced at that mark even when the vault does
  not hold it yet). ICPUSD has no mark. Recomputed at every pass — the held
  set can change while a request waits. A genesis deposit into an empty vault
  waits on its own market only.
* R is READY when, for every m in `waitingOn(R)`, `releaseRefOf(m).dispatchNs
  > R.ts` — the dispatch clock (H-23), never `refPriceUpdatedNs` — AND no held
  leg is breaker-pended (`pendingPriceJumps`). A pend WAITS for its
  confirmation tick; it never cancels the request.
* A READY request settles through the immediate path's own helper —
  `performLpDeposit` / `performLpWithdraw` — on the fresh marks: the
  impairment-netted NAV (`refreshVaultImpairment` at the top of both), the
  lock settle (the touch-side belt behind the mutation-time settle), and the
  two-bucket instant cap (`VaultLock.withinCap`)
  are all evaluated AT SETTLEMENT, exactly as a call made at that instant
  would see them. A request the settlement-time state refuses (cap exceeded,
  concentration cap, zero-mint dust, a leg that became unpriced) is
  CANCELLED with that refusal as its reason — nothing is clamped or retried.
  The exit fee applies once, so a staged deposit-then-withdraw round trip is
  exactly −fee, as the immediate path is.

**The request arms the price.** Staging arms a GEPTOR (`_geptorDeadline`,
Nagle-debounced by `GEPTOR_DELAY_NS`) on every `waitingOn` market, as a
cross-swap does on both its legs — so settlement latency is one fetch
(~1–2 s), not the 60 s cadence. While a request is unsettled the pass re-arms
the markets that have not yet postdated it, at most once per
`STAGED_LP_REARM_NS` (15 s) per request, so a failing feed costs one fan-out
per 15 s per market, not one per finaliser beat. The pass runs inside every
`ammRequote(_, release = true)` (the GEPTOR's fresh-mark requote and
`requoteAmm`) and from the finaliser (`finaliseExpiredPending`); `#dev`'s
`setAmmRefPrice` stamps the release reference like a fetch, so the sealed
suites' re-stamp idiom releases staged LP requests too.

**The freshness gate becomes a backstop.** `LP_DEPOSIT_MAX_REF_AGE_NS` is no
longer a correctness mechanism on the staged path (a READY request's marks
are fresher than any grace by construction); it stays inside
`performLpDeposit` / `vaultWithdrawPaused` as the belt at settlement and for
the controller's immediate `seedAmmPool`. The backstop for the staged path is a TTL: a request no postdating
marks reach within `STAGED_LP_TTL_NS` (5 min — a dead feed) is CANCELLED and
refunded, fail-closed: the reservation is released (the funds never left the
wallet; the shares never left the balance), a `vault` row goes on the public
tape (`getRecentEvents`: "staged LP <kind> #<id> cancelled — no fresh marks
for <markets> within 300 s") and the owner's outcome list records
`#cancelled(reason)`.

**Reservation semantics (funds/shares reserved at request time).**
* A deposit's legs are soft-locked in `reservedBalances` (`addReserved`, the
  same lock staged orders and cross-swaps use), so `getAvailable` — and with
  it every order, swap and transfer — sees the funds as spoken for. Released
  at settlement (just before the mint) or at cancellation.
* A withdrawal's shares are reserved in `vaultLpReserved` (principal → LP):
  a second `withdrawLp` sees `balance − reserved`. Released at settlement
  (just before the burn) or at cancellation. `getMaxInstantWithdraw` is
  UNMOVED by staged requests until they settle — it quotes the cap on the
  full balance; the reservation only stops the same shares being staged
  twice.
* One pending request per owner per kind (a second `depositLp` /
  `withdrawLp` is refused naming the pending id), which bounds the store at
  2 × LPs and needs no per-owner cap.
* Cleared with the vault on a world wipe (the reservations die with the
  balances they guard — `reservedBalances` is cleared there too).

**Tape and notice.** Settlement emits the existing permanent rows —
`#lpDeposit` (inside `performLpDeposit`) and `#lpWithdraw` (inside
`performLpWithdraw`, folded by the H-32 exit window like any exit). A
cancellation moved no value, so it writes no permanent row: it logs a public
`vault` event and records the owner's outcome. No new `UserEventKind` arm is
added: proved 2026-09-06 with `mops check-candid` that a new arm on the
`UserEvent` kind variant is a BREAKING change under Candid subtyping for a
return type (rc 1), while new methods with new types and a new `opt` field
on a returned record both pass (rc 0).

**Surface (apiVersion 6.0.0 — the doors themselves, task 1788731608; 5.1.0 had
landed the same shape additively as `stageLpDeposit` / `stageLpWithdraw`,
dropped at the bump — `candid/README.md` "Major bumps so far").**
* `depositLp(marketId, baseAmount, quoteAmount) : {#ok : StagedLpRequest;
  #err : Text}` and `withdrawLp(lpAmount) : {#ok : StagedLpRequest; #err :
  Text}` — `#ok` is the REQUEST. The request-time refusals are the cheap
  ones (nothing to deposit, no pool / unpriced, insufficient available
  balance or shares, a pending request of the same kind, the season-seal
  latch); everything the settlement-time state decides is decided then.
  `withdrawLp` keeps its place in `EXIT_METHOD_SET` (inspect admits it at
  every load floor — staging the exit IS the exit a shed LP needs).
* `getMyStagedLpRequests() : {pending : [StagedLpRequest]; recent :
  [LpRequestOutcome]}` (caller-scoped): `pending` carries `waitingOn` (the
  markets that have not yet postdated the request at query time — empty means
  it settles on the next pass); `recent` is the caller's last 8 outcomes,
  `#minted(lp) | #redeemed(basket) | #cancelled(reason)`. Each pending request
  also carries `cancelRefusal : opt text` (task 1788731609, below).
* `cancelStagedLpRequest(requestId) : {#ok; #err : Text}` — the owner cancel
  under the commit rule (below).
* `adminRunStagedLp()` (controller — run the pass now, normally
  heartbeat-driven) and `setTestStagedLpExpiry(id, ns)` (`#dev` — force a
  request's TTL for the outage pin).
* `seedAmmPool` is the ONE immediate mint door and is CONTROLLER-ONLY since
  6.0.0 (it was `requireAuth` only): `seed.sh` / `play_start.sh` seed the
  vault through it under paused timers, where no GEPTOR fires and the marks
  were stamped moments before; for everyone else an open immediate mint
  would be exactly the pre-6.0.0 sniping window this ruling closed. Test
  fixtures that seeded as ad-hoc identities mint through `tests/_lib.sh`'s
  `mdx_lp_deposit` / `mdx_lp_withdraw` (stage → re-stamp the waited markets
  → requote → run the pass → read the outcome).

**Pinned in `tests/test_vault_lp.sh` §10:** a deposit staged BEFORE a mark move
settles at the POST-move NAV (the mint equals the immediate-path mint at the
post-move marks, never the pre-move one — no cheap shares), and a withdrawal
staged before a move redeems at the post-move NAV (symmetric); a request
whose marks are frozen (timers paused) stays pending with `waitingOn` naming
the stale markets, and the TTL backstop cancels + refunds it (reservation
released, balance restored, tape row, `#cancelled` outcome); the staged
round trip is exactly −fee; `getMaxInstantWithdraw` is byte-identical before
and after a staged withdrawal is pending; a second request of the same kind
is refused; a second request of the same kind cannot stage the reserved
shares twice. `tests/test_breaker_widening.sh` §2–§4 and
`tests/test_margin_collateral_escape.sh` §3 pin the pend and stale-mark
semantics at the doors: a request under a breaker pend on any market it
waits on, or under a mark no fresh dispatch postdates, stays PENDING and
settles on the clearing / fresh stamp — never refused, never settled early.

**Owner cancel under the commit rule (task 1788731609).**
`cancelStagedLpRequest(requestId) : {#ok; #err : Text}` (owner-only) lets a
depositor withdraw a staged request without waiting out the 5-min TTL — but
never as a free look at the settling price. It reuses the staged-order cancel
predicate's two halves verbatim (`stagedLpCancelReason`, beside
`deferredCommitReason` / `swapCommitReason`): refused inside
`DEFERRED_COMMIT_NS` (3 s) of the request's `ts`, and past the window while a
price fetch DISPATCHED after `ts` is still in flight for ANY market in the
request's set (`fetchInFlightSince` — the H-23 lock: a GEPTOR arm, the tick's
or the admin fetch's stamp, within the arm's TTL), naming that market. The set
is `stagedLpMarkets` (every held leg + the deposit's own), not the
still-to-postdate subset: a fresher mark on an already-postdated market still
moves the settlement NAV. Since the request itself arms a GEPTOR, on a live
feed the lock holds until that fetch lands — and then the request settles; the
cancel matters exactly when the feed stalls. Past `expiresAt` the TTL owns the
request (cancellable, as an expired staged order is). A permitted cancel runs
the TTL backstop's own body (`cancelStagedLp`): the reservation is released —
the refund is the reservation ONLY, a withdrawal's locked shares are never
touched — the owner's outcome records `#cancelled("cancelled by owner")`, and
the public `vault` tape row is written. Ownership is checked before the
commit phase (a non-owner probe reads "Not your staged LP request"). The
request view carries the same verdict as `cancelRefusal : ?Text` (additive
`opt` field on `StagedLpRequest`; null = cancellable now), so the Earn card's
per-request Cancel button is disabled with the exact refusal text and never
re-derives the rule. The method is in inspect's `EXIT_METHOD_SET` (the tenth
exit) — it releases the owner's own reservation and nothing else, the argument
that put the staged-order cancels there — and carries no season latch for
the same reason; hygiene §8b lists it in `NOAWAIT_SETTLE` (one hop:
`cancelStagedLp`). Pinned in `test_vault_lp.sh` §10(e): cancel inside 3 s
refused; a non-owner refused without a commit-phase leak; cancel after 3 s
with timers paused succeeds, refunds, writes the tape row; with a
`devStallSource #hold` admin fetch for BTC-ICPUSD whose fan-out is left OPEN
to the 8 s deadline sweep after the request (the primary floor forced
unreachable so quorum cannot close it), the cancel of an ETH-ICPUSD deposit
is refused naming BTC-ICPUSD until the sweep finalizes the fan-out, then
succeeds.

**Season boundary — the seal CANCELS pending requests on the tape (operator
decision B, 2026-11-01, task 1788731610; filed 2026-09-06 as "must an
in-flight staged request block a season seal").** A staged request caught by
a season boundary is CANCELLED, visibly — never a silent clear, and never a
seal that waits. `performWorldWipe` (both `resetSeason` and `resetExchange`),
BEFORE the store / vault / balance clears, runs the TTL backstop's own body
(`cancelStagedLp`) over every pending request: the reservation is released
(deposit legs out of `reservedBalances`, shares out of `vaultLpReserved`),
the owner's outcome records `#cancelled("season sealed before settlement;
nothing settled, funds released")` (`"exchange reset before settlement; …"`
under `resetExchange`), and the public `vault` row goes on the tape
(`getRecentEvents`) — the same row and outcome a feed-stall expiry writes,
the reason naming the boundary. Then the wipe proceeds as before. Two
orderings make the cancellation OUTLIVE the wipe it precedes: the ring log
(`eventLog`) and the outcome lists (`lpRequestOutcomes`) are cleared FIRST,
so the boundary's cancellations are what the new epoch's ring and each
owner's `recent` open with (the rule `resetSeason`'s own "Season N closed"
line already follows — written after the clear), and the pass runs before
the reservation stores are cleared, so the release is the real path over
live maps. `getMyStagedLpRequests` after the seal therefore reads exactly as
it does after a TTL cancel — `pending` empty, the request in `recent` with
its `#cancelled` reason — and wallets / LP are zero as before (nothing of
value is lost: the boundary zeroes them anyway). No permanent `UserEventKind`
row and no new Candid shape (the TTL cancel's own constraint, above); the
seal is NOT coupled to feed liveness — a bounded loop over a store capped at
2 × LPs, no await. **Latch:** `withdrawLp` stays EXEMPT from the sealing
latch, like every other exit ("cancels, closes, unstakes and withdrawals
still pass"); `depositLp` keeps its `sealingRefusal()`. A withdrawal staged
inside the latch window either settles on the next fresh mark once the
window closes (normal, 1–2 s; timers are held under the latch) or is
cancelled by the seal per the rule above. Pinned in
`tests/test_season_seal.sh` §5: a pending staged deposit AND a pending staged
withdrawal at the seal both surface post-seal as cancelled with the seal
reason (tape row + `recent`), reservations released, balances / LP at zero;
a withdrawal staged inside the latch is accepted and settles on the next
fresh mark once the latch clears; a deposit staged inside the latch is
refused. The 6.0.0 flip of the doors landed 2026-09-07 (task 1788731608);
the owner cancel above landed the same day (task 1788731609).

### LP equity on the leaderboard (decision D, 2026-09-03)

An LP's equity on the competition board (`accountCrossSection`, the term
`getMyAccountSummary` and the sealed season record share) is their **NAV per
share**: pro-rata `currentVaultValue().totalQuoteValue` = held basket + loan
book − insurance arrears. The loan book is a vault asset expected to be repaid,
so it is INCLUDED (net of arrears); that it cannot be redeemed *instantly* is a
liquidity / timing property of exits, not a reduction of equity — excluding it
would show zero equity to a fully-lent vault's LPs, and since mint prices
against the same NAV, crediting holdings only would make every deposit into a
lent vault a fake trading loss and every repayment fake profit. Instant
withdrawability is a **separate liquidity limit**: an LP's maximum instant
withdrawal is their pro-rata share of the held basket, with the remainder
redeemable as loans repay — shipped by task `1788465539` (the section above:
NAV redemption + pro-rata instant liquidity + `getMaxInstantWithdraw`), so
board equity is fully realizable over time. This answers GHSA-h888 clause 4 (operator decision
on task `0288283668`): the reporter's measured inflation was entirely the
supply-0 mint bug, fixed in `3eda0c5` + `dc2cef2`; the NAV basis stays.

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
| `LP_EXIT_FEE_BPS` | 40 | `withdrawLp` (applied to the NAV value redeemed; the instant cap is `lpBal/supply × holdings`, `VaultMath.withinInstantCap`) |
| `LP_DEPOSIT_MAX_REF_AGE_NS` | 60 s | `vaultPricesStale` |
| `IMPAIRMENT_STRESS` | 0.15 (= the maintenance cushion) | `VaultMath.expectedLoss` — PD × LGD provision per pool below `MAINTENANCE_HEALTH_RATIO`; reserve = Σ EL − insurance fund, ≤ loan book (`vaultImpairmentReserveUsd`) |
| `DEFERRED_COMMIT_NS` | 3 s | cancel paths |
| Arb band / edge / per-tick | 50 bp / 20 bp / $5k (= per-call) | `src/arb/main.mo` |
| Arb haircut / per-call / hourly | 10 bp / $5k / $512.5k (imports only) | `extMarketSwap` |

## 10. Verification

* Unit: `tests/AMM.test.mo` (never-cross under hostile skews, one-sided
  intent, round-trip pays the vault), `tests/VaultMath.test.mo` (mint guard,
  NAV redemption + instant cap, impairment band edges) — `mops test`.
* Integration: `test_skew_direction` (new geometry on a live book),
  `test_inventory_floor` (hard floor under relentless buying — driver fixed to
  clear the 100× fat-finger guard), `test_rebalance` (default-off + tight
  cap), `test_vault_lp` (exit-fee payouts, NAV redemption F1–F6, the
  impairment reserve §8), `test_treasury_fees` (split
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
