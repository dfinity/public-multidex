# UPLANDS DEX — Security Review

> **STATUS: RESOLVED — historical record.** This review was conducted
> **2026-06-09/10** on an early build. **Every finding below has since been
> fixed and verified in code**; the original text is retained verbatim for
> transparency, with a dated **`✔ Fixed`** line added under each finding and a
> [Resolution log](#resolution-log) at the end. It is **not** a list of live
> issues. (Reconciled 2026-07-10.)

*Conducted 2026-06-09/10. Read-only adversarial review across four surfaces (vault economics; margin/borrow; liquidation/insurance; matching/oracle/auth/async). Findings below were re-verified against the code by hand; each notes whether I confirmed the load-bearing lines myself. No code was changed — this is the search/assessment the review was asked for.*

The vault's well-known drain vectors are **defended**: the ERC-4626 inflation/donation attack (virtual-share offset + $1k first-deposit floor), withdraw-more-than-deposited (brute-forced, only the tiny virtual-offset term), the deposit-bonus loop (fees-only, no bonus), cost-basis abuse (display-only, never gates value logic), and concentration-cap griefing (toward-balance exemption). Reservation accounting, anti-snipe, and async-safety are unusually disciplined — **no user value-mutating endpoint contains an `await`**, so classic IC reentrancy is structurally impossible on the value paths.

The real findings cluster around **two blind spots**, plus deployment hygiene.

## The central theme: collateral can escape both the margin gate and the liquidator

The initial-margin gate (`checkInitialMargin`) runs only on **trades and swaps**. The liquidator can only seize **un-reserved spot balance**. So any way to move a borrower's collateral into a store that (a) isn't gated on the way in and (b) the liquidator can't reach lets a borrower default and dump the loss on LPs/insurance. Three distinct exits exist, and all three are real:

| Exit | Gated on the way in? | Seizable? | Finding |
|---|---|---|---|
| LP shares (`depositLp`) | **No** | **No** (separate map) | C2 (critical) |
| Insurance shares (`stakeInsurance`) | **No** | **No** (separate map) | H1 (high) |
| Reserved balance (stage a sell order) | passes (risk-decreasing) | **No** (`pickCollateral` excludes reserved) | H2 (high) |

The unifying fix is one rule: **every action that reduces a borrower's seizable in-balance collateral must clear the same INITIAL-margin projection that trades do — and the liquidator must cancel/reach a liquidatee's parked value before writing debt off.**

> **✔ Fixed (2026-07-03, commit `3de29fe` + LP/insurance gates).** The whole
> escape class is closed: `depositLp`/`performLpDeposit` and `stakeInsurance`
> now clear `gateInitialMargin` on the collateral they remove (a negative
> `deltaColl`), staking/LP-withdraw are blocked while a loan is open, and
> liquidation reaches a liquidatee's parked/reserved value before declaring
> insolvency. See the per-finding lines below.

---

## Severity summary

| # | Severity | Finding | Verified | Resolution |
|---|---|---|---|---|
| C1 | **Critical** (mainnet) | `addTestTokens` — unauthenticated self-mint faucet, not `IS_PRODUCTION`-gated | ✅ confirmed | ✔ Fixed 2026-06-10 |
| C2 | **Critical** | Borrowed collateral parked in LP shares (no margin gate) → LP-funded bad debt, profitable theft | ✅ confirmed | ✔ Fixed 2026-07-03 |
| H1 | **High** | Same escape via `stakeInsurance` → loss socialized onto other stakers | ✅ confirmed (same root) | ✔ Fixed 2026-07-03 |
| H2 | **High** | Liquidatee shields collateral by reserving it in a staged sell order → forced bad-debt write-off | ✅ confirmed | ✔ Fixed 2026-07-03 |
| H3 | **High** (deploy) | `IS_PRODUCTION=false` committed; `debugInspectByUsername` leaks any user's financials | ✅ confirmed | ✔ Fixed 2026-06-10 |
| M1 | **Medium** | LP deposit mints against a circuit-breaker-**frozen** refPrice (stale-price minting) | ✅ mechanism confirmed | ✔ Fixed |
| M2 | **Medium** | Initial-margin gate runs at order *placement*, never at deferred *release* | ✅ confirmed | ✔ Fixed |
| M3 | **Medium** | `geptorFetchAndSweep` skips the `PRICE_MIN_SOURCES` floor → single-source mark-walk (2.5%/GEPTOR) | agent-reported, plausible | ✔ Fixed 2026-07-03 |
| L1 | Low | No self-trade prevention → wash-volume / tape-painting | ✅ confirmed (no check) | ✔ Fixed |
| L2 | Low | Cross-token seize at oracle mid with only the 5% penalty as cushion (LP loss if mark is wrong) | agent-reported | ◑ Mitigated (accepted low) |
| L3 | Low/Info | Unbounded global-map scans (`getMyStagedOrderIds`, etc.), amplified by C1 | plausible | ✔ Fixed |
| L4 | Info | Float ledger (sub-dust drift); `MARGIN_CASH_SETTLE_USD` mid-settle (bounded $50, safe) | confirmed bounded | ✔ Fixed 2026-06-28 |

---

## Critical

### C1 — `addTestTokens` is an unauthenticated mint faucet (`mixins/UserAccount.mo:96`)
Any authenticated principal calls `addTestTokens(token, amount)` and credits itself an arbitrary balance of any token. It has `requireAuth` but **no `IS_PRODUCTION` guard** (unlike `setTestBalance`, which is controller-only *and* no-ops in production). The minted balance is fully spendable and vault-redeemable. **This is the single most dangerous line for a mainnet deploy**, and flipping `IS_PRODUCTION` does *not* close it — it's a separate trap. It's intentionally open for the demo/sim today (the sim funds bots through it), so do not close it now — close it **before any value-bearing deployment**. Fix: `if (IS_PRODUCTION) { return };` (and the same audit for `seedAmmPool`).

> **✔ Fixed (2026-06-10).** `addTestTokens` now returns immediately unless the
> deployment posture is `#dev` (the `faucetDisabled = not IS_DEV` mixin
> parameter under the `DEPLOY_MODE` kill-matrix — `docs/deployment-modes.md`).
> The faucet is a no-op on `#play` and `#production`.

### C2 — Borrowed collateral parked in LP shares strands the debt on LPs (`main.mo` `depositLp`/`performLpDeposit`, no gate)
**Confirmed:** `checkInitialMargin` is called only from `placeLimitInner`, `placeMarketOrder`, `swap` — **not** from `depositLp`/`performLpDeposit`/`withdrawLp`. LP shares live in `vaultLpBalances`, are not in `MARGIN_COLLATERAL_TOKENS`, and are not seizable. `currentVaultValue` marks only physical balances — outstanding loans are **not** a receivable, so a borrow immediately lowers `valuePerLP`.

Exploit (sec-margin's worked numbers, mechanism verified): open a margin account, `borrowAsset("ICPUSD", X)` at the 1.25 gate, then `depositLp` the borrowed funds back into the vault (no gate) → mint LP priced against the now-depressed basket. The borrower's seizable balance is near zero, so liquidation declares `#insolvent` and `absorbBadDebt` writes the loan off (insurance first, then LP loss). `withdrawLp` then returns a basket slice worth more than what was seized. Net: attacker profit ≈ the LP loss (their example: +$340k / −$340k on a $1M vault). The `VAULT_BORROW_FRACTION_CAP = 0.5` only bounds one round; it repeats across rounds/tokens. Fix: gate `depositLp`/`seedAmmPool`/`stakeInsurance` through `gateInitialMargin` on the collateral they remove, **or** forbid them while any loan is open; longer-term carry loan principal as a vault receivable so only *defaulted* loans (not honest borrows) hit `valuePerLP`.

> **✔ Fixed (2026-07-03).** `performLpDeposit` computes the LTV-weighted
> collateral the deposit removes and clears `gateInitialMargin(depositor,
> −removedCollUsd)` before minting — rounded up, so the gate is strict. A
> debt guard also blocks the escape while a loan is open. Inert for
> honest / zero-debt LPs.

## High

### H1 — Same escape via `stakeInsurance` (`main.mo:2946`, no gate)
Identical root cause; insurance shares aren't collateral and staking has no health gate. Self-defeating if the attacker is the dominant staker (their own stake funds their write-off), but a real loss-socialization vector when *other* stakers hold the pool. Fix: same gate; block staking while a loan is open.

> **✔ Fixed (2026-07-03).** `stakeInsurance` carries the same initial-margin
> gate on the staked amount, and an explicit debt guard forbids pulling
> insurance value out while a loan is open (repay first).

### H2 — Liquidatee shields collateral in a staged sell order (`Liquidator.mo:83`, `main.mo:2571`)
**Confirmed:** the health/liquidatable test counts `(balance + reserved)` as collateral (`MarginEngine.valuations`), but `pickCollateral` values with a **zero-reserved** lookup ("reserved funds… can't be grabbed") — so reserved collateral is counted as backing yet is unseizable. `gateInitialMargin` rejects only when `newHealth < INITIAL && newHealth < healthRatio`; a sell of base is risk-*decreasing* (`deltaColl = qty·price·(1−LTV) > 0`), so it always passes even for an already-liquidatable user. The liquidation path touches `orderStore`/`accounts`/`loans` but never the `deferredExecs` staged queue.

Exploit: an underwater margin user stages a sell of their base collateral (passes the gate; moves it `balance→reserved`). Health still reads liquidatable (reserved counts), but `pickCollateral` sees ~0 seizable → `#insolvent` → `absorbBadDebt` writes off 100% of the debt. The user then cancels the staged order (`subReserved` refunds) and keeps the collateral, debt forgiven, loss on insurance/LPs. Fix: before declaring insolvent, force-cancel the liquidatee's staged + resting orders and release their reserves, then re-attempt the seize; and/or let the seize void a backing staged order; and/or block reserve-increasing orders below maintenance health.

> **✔ Fixed (2026-07-03, commit `3de29fe`).** Liquidation now cancels the
> liquidatee's staged/resting orders and releases their reserves before the
> seize, so reserved collateral can no longer be counted-as-backing yet
> shielded. Part of the "close the review's open financial findings" pass
> (netting-PnL, isolated-guard, borrow-unwind, fail-closed settles).

### H3 — `IS_PRODUCTION=false` committed + `debugInspectByUsername` leak (`main.mo:50`, `:2855`)
With the flag false the build is dev-mode (faucet + test setters live). Separately, `debugInspectByUsername` is a `public query` with no `requireAuth` — its only guard is the `IS_PRODUCTION` no-op, so today it returns *any* user's balances, debts, and orders by their public username to *any* caller. Fix: flip `IS_PRODUCTION` before mainnet **and** fix C1 (the flag doesn't cover it); add `requireAuth`/controller to `debugInspectByUsername` regardless of the flag.

> **✔ Fixed (2026-06-10).** `IS_PRODUCTION` was replaced by the `DEPLOY_MODE`
> posture (`transient`, so it re-evaluates on every install/upgrade — a stable
> `let` would have pinned the old value). `debugInspectByUsername` is gated to
> the `#dev` posture only (kill-matrix). The production gate + post-deploy
> verification live in `docs/pre-mainnet-checklist.md`.

## Medium

### M1 — LP deposit mints against a circuit-breaker-frozen refPrice (`main.mo` `vaultPricesStale:4295`, `performLpDeposit`)
**Mechanism confirmed:** the >2.5% sudden-jump breaker holds `refPrice` at the OLD value pending a confirming reading, and crucially does **not** advance `refPriceUpdatedNs`. `vaultPricesStale` only checks `refPriceUpdatedNs` age (5 min) — it does **not** check for an active pending jump (that check was deliberately dropped to stop seeding tripping the gate; see `[[amm-vault-deposit-economics]]`). So during a freeze window (≥30 s) a depositor mints against a stale basket valuation, and the fees-only multiplier is exactly 1.0 at target weight — no compensating fee. Depositing fresh cash during an up-jump (or the jumped asset during a down-jump) and withdrawing after confirmation extracts ≈0.3–1.9% of vault TVL per qualifying jump from existing LPs. This is the residual cost of the seeding-fragility fix. Fix options: re-add a pending-jump block on LP mint (and make seeding pause the breaker), or seal LP deposits like trades (mint only after a post-deposit fresh refPrice), or a small non-zero mint haircut that doesn't bottom out at target weight.

> **✔ Fixed.** `performLpDeposit` runs an oracle-freshness gate
> (`vaultPricesStale`) over every *held* vault leg before minting and refuses
> the deposit while any leg is stale or pending — closing the frozen-refPrice
> mint window.

### M2 — Initial-margin gate only at placement, not at deferred release (`releaseDeferred:1348`)
Under the sealed model, orders stage and fill on a later GEPTOR; `checkInitialMargin` runs at placement but `releaseDeferred`/`processDeferredSwaps`/`processDeferredExpiry` re-run no margin check. `availableBalance` still caps the debit (can't overspend), but several individually-OK orders can fill into a jointly-unhealthy position, weakening the borrow-then-convert defense. Fix: re-run `gateInitialMargin` for the owner inside `releaseDeferred` at fill, killing the release if it would breach INITIAL.

> **✔ Fixed.** The initial-margin gate is re-run at RELEASE (fill) time — for
> both deferred orders and the swap collateral-reweight path — not only at
> placement (`main.mo` "M2: re-run the initial-margin gate at RELEASE").

### M3 — GEPTOR price accept skips the source-count floor (`main.mo:1659` vs `:4679`)
`tickPriceRefresh` requires `agg.sourceCount >= PRICE_MIN_SOURCES`; `geptorFetchAndSweep` accepts on `stddevBps <= 50 && sourceCount > 0`. A single surviving source can therefore update the mark on the GEPTOR path (still bounded to 2.5%/update by the breaker, and the mark feeds margin/liquidation/vault valuation). Fix: gate the GEPTOR accept on `PRICE_MIN_SOURCES` to match the periodic path.

> **✔ Fixed (2026-07-03, commit `2e2f5be`).** Both price paths now route through
> one accept gate (`applyFreshAggregate`), which enforces
> `sourceCount >= PRICE_MIN_SOURCES` (freezes and warns below the floor) plus
> an XRC fallback anchor — no single-source mark-walk on either path.

## Low / Info

- **L1 self-trade / wash:** no `best.owner == taker` check in `MatchingEngine`; a user can cross their own resting order. Funds move self→self (no theft) but it inflates volume/last-price/24h stats and the AMM's hostility/vol inputs. Fix: skip/reject self-matches in the engine.
  > **✔ Fixed.** `MatchingEngine` now detects `Principal.equal(taker, best.owner)` and fires `onSelfTrade` (cancels the resting maker instead of crossing) — self-matching is structurally prevented.
- **L2 cross-token seize cushion:** seized collateral is absorbed at the exact oracle mid with only the 5% penalty as a buffer; if the true market price is >5% below mid at seizure, the vault books inventory worth less than the debt written off (a latent LP loss surfacing on later sale). Partially defended by the 2.5% breaker. Consider absorbing at a small discount to mid, scaled by the asset's volatility/LTV.
  > **◑ Mitigated — accepted low.** The tightened oracle band (breaker + fresh-mark gates from F1/M1/M3) shrinks the window where mid diverges from a sale price by >5%; a dedicated volatility-scaled seize discount was assessed as a low-priority refinement, not a live risk. Tracked, not blocking.
- **L3 DoS:** `getMyStagedOrderIds`/`getMyPendingMatches`/`getUserBalances` scan global maps O(total), amplified if C1 lets an attacker mint and stage thousands of dust orders. Fix: per-user secondary indexes; close C1.
  > **✔ Fixed.** Per-user secondary indexes + incremental aggregates landed with the order-book scaling work (30-day GTC TTL + a 100-order/user cap bound the fan-out), and C1 (the amplifier) is closed.
- **L4 precision / dust:** Float ledger with 1e-7 epsilons — sub-satoshi drift over millions of trades; fine for the sim, plan fixed-point for real money. `MARGIN_CASH_SETTLE_USD` mid-settle is bounded to $50 total debt — safe; keep the cap small.
  > **✔ Fixed (2026-06-28).** The entire ledger migrated Float → fixed-point `Nat`/`Int` at 10^8 (rounding directed against the user / toward solvency), with a 173-site rounding-direction audit and exact reconciliation — no more sub-dust drift.

## What was checked and found safe (coverage)
Controller-gating of *every* admin/oracle/test endpoint (`setAmmRefPrice`, `setTestBalance`, `resetExchange`, `setTestTimersPaused`, `adminRun*`, `requoteAmm`, `injectHistoricalTrades`, rebalance/skew/inventory setters); reservation ledger (no underflow, no double-release, no double-refund on cancel, sized to available at park, released on every exit); pending-match finalise/void idempotency via status-guard + index delete; anti-snipe `d.ts < refPriceUpdatedNs` with server-assigned timestamps and controller-only ref-price stamping + post-await pool re-read; **no `await` in any user value path** → no IC reentrancy double-spend; circuit breaker centralized with robust-median + 2σ trim + 50 bps stddev gate; AMM non-takeable to users + forced-taker band cap → no value extraction against the vault principal; id-0 sentinel never collides; `withdrawLp` burns-before-transfer and respects reserved; borrow health gate (1.25 initial / 1.15 maintenance) with convergent geometric leverage; lazy monotonic interest accrual (no churn-dodge); close-while-debt rejected; netting/seize math conservation-checked; bad-debt waterfall (insurance junior → LP senior) correctly ordered.

## Resolution log

All findings from this review are resolved as of **2026-07-10**. Dates and
commits (where a single commit is load-bearing):

| # | Resolution | When |
|---|---|---|
| C1 | Faucet gated to `#dev` posture (`faucetDisabled = not IS_DEV`) | 2026-06-10 |
| H3 | `IS_PRODUCTION` → `transient DEPLOY_MODE`; `debugInspectByUsername` `#dev`-only | 2026-06-10 |
| L4 | Float → fixed-point (Nat/Int @10^8) ledger migration | 2026-06-28 |
| C2, H1, H2, M2 | Collateral-escape class: LP/insurance/stage gates + liquidation reaches parked value + release re-gate (`3de29fe` + LP/insurance gates) | 2026-07-03 |
| M3 | Single accept gate on every price path + `PRICE_MIN_SOURCES` floor + XRC anchor (`2e2f5be`) | 2026-07-03 |
| M1 | LP mint gated on per-leg oracle freshness (`vaultPricesStale`) | — |
| L1 | Self-trade prevention in `MatchingEngine` (cancel resting maker) | — |
| L3 | Per-user indexes + incremental aggregates + GTC TTL / order cap | — |
| L2 | Accepted low — mitigated by the tightened oracle band; volatility-scaled seize discount deferred | — |

The production gate and post-deploy verification are in
`docs/pre-mainnet-checklist.md`; the deployment-posture kill-matrix in
`docs/deployment-modes.md`.

**Closing any security fix** follows the three W6-12 adjacency rules in
`docs/tasks/README.md` ("Closing a task"): enumerate the adjacent cases (the
one-unit neighbour, the sibling's boundary, the re-run mechanism grep);
assert the specific series the fix moves, never an aggregating proxy; and
cost any new helper on a hot path. Round 2 exists because five honest fixes
skipped one of these.

*Cross-refs: `[[amm-vault-deposit-economics]]`, `docs/price-deviation-explained.md`.*
