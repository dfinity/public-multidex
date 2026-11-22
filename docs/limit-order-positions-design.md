# Limit-order position entry

*2026-06-11. Implemented. Lets a user open (and close) a margin position with a limit order — exact price, no slippage — instead of a market order.*

*Amended 2026-09-05 — borrow timing changed: leverage is borrowed at the FILL, never at placement (operator decision D5 option (d), task `1788467597`; landed `ab917b0`, task `1788467631`). The analysis that forced the change is the hardening plan's H-34 (`docs/hardening-plan-2026-09.md` §H-34): a leveraged entry that pre-borrowed at placement held vault capacity it was not using for as long as it rested. 2026-10-31: the user-facing copy (docs.js, the order ticket, `getApiDoc`) and the sibling design notes were aligned to this section (task `1793461378`).*

## Why it's small

The sealed model is already a deferred-order system: `parkDeferred(marketId, baseToken, owner, side, kind, price, qty, …)` takes a `kind` of `#market` or `#limit`, and `releaseDeferred` already *rests* a `#limit` leftover on the book. `openPosition` previously hardcoded `#market` with a slippage-cap price; limit entry is "thread a price through."

- **Market**: ceiling = slippage cap; releases and fills on the next GEPTOR (~1–2 s).
- **Limit**: ceiling = the user's price (no slippage); the leftover RESTS on the book owned by the pool principal and fills when the market reaches it. The Phase-3 settlement hook books each fill at the exact fill price — so the entry is exact — and each fill is where the leverage is borrowed (below): a resting entry holds no debt.

## The one real decision: borrow timing — BORROW AT FILL (D5 option (d), 2026-09-05)

*Superseded design (2026-06-11 → 2026-09-05): `openPosition` pre-borrowed the leveraged shortfall at placement, sized at the price ceiling, and the borrow sat reserved against the staged/resting order accruing carry until it filled, cancelled, or was killed (H-07 repaid the idle part). The original version of this section weighed borrow-at-fill and rejected it; the hardening plan's H-34 analysis (`docs/hardening-plan-2026-09.md` §H-34, F36) showed the vault-capacity consequence that weighing had missed: a far-off resting bid held vault quote it was not using, and `borrowCheck`'s 0.5 × holdings cap let one pool starve every later borrower. H-34's brief offered a distance-from-mark bound (a), a TTL (b) or a per-pool share of the cap (c); the operator ruled (task `1788467597`, D5, 2026-09-05) for option (d) instead: **a leveraged entry reserves NOTHING from the vault until it executes.***

- **Placement is a CHECK, not a borrow.** `openPosition` runs `BorrowEngine.borrowCheck` for the shortfall at the ceiling (the same gate the fill will run — vault cap + post-borrow initial health on fresh marks) and refuses up front with the vault's reason; then it stages the whole size. `parkDeferred`'s pool-ENTRY branch soft-locks only what the pool owns toward the size (possibly nothing) and parks the full quantity — the rest is the fill's borrow. A staged or resting entry holds **zero vault debt**, pays **no carry**, and never moves the vault's balance or `getMaxInstantWithdraw` (`tests/test_initial_margin.sh` §G1).
- **The fill borrows exactly its quantity.** The matching engine's `ProtectionCtx.fundForFill` hook (`poolFundForFill` in main.mo) is called for each party of each slice before that party's funding gate; a margin pool borrows exactly the slice's shortfall (cost + its fee − its free quote for a long; the base short for a short) from the vault right there — synchronously, inside the matching pass, `BorrowEngine.borrow` is await-free — gated by `borrowCheck` on fresh marks (F1's traded token + H-06's basket). Interest accrues from that instant. Both roles are covered: the pool as TAKER (`releaseDeferred`) and as MAKER (a resting entry hit by a later taker, the AMM sweep, or the rebalancer). `reprovisionPool` follows every fill-borrow (§G2: debt == cost + maker fee − own quote, to the unit).
- **Fail closed when the vault cannot lend.** A refusal (vault cap, health, stale mark) makes the hook return `false`: the engine treats the pool as an UNFUNDED party — a resting maker is cancelled with W4-24's one notice, an aggressor stops and its remainder is cancelled (never rested, never re-parked — H-10's shape). Slices already settled stand; the refused slice settles nothing. `onUnfundedMakerNotice` names the vault's reason for a pool (`"Pool order cancelled mid-match: the vault could not lend …"`). A resting entry may therefore fail to fill if the vault has run dry since placement — the correct outcome for a reservation the pool was never using (§G3).
- **Only entries borrow.** The hook fires for exposure-INCREASING fills only (`poolOrderAddsExposure`: buy with net ≥ 0, sell with net ≤ 0). Exits are funded by the pool's holdings exactly as before (`closePosition`'s reservation, the mark-sized trim of task `1788557389`), so "closing is always available" never meets a borrow refusal. The same predicate scopes the resting-order EARMARK (`poolRestingOrderNeeds` — exits only; an entry needs no cash held back from debt repayment) and the post-debit adjuster (`LiquidityManager.adjustPoolOrders` — the balance shrink applies to a pool's exits, never to its borrow-at-fill entries; the wallet-shaped 2.5× / cross-market bid caps never bound pools).
- **The release clamp speaks the fill's language.** `clampToInitialMargin`'s re-levering bound for a pool now scores each unit of excess as borrowed at the fill — `ltv·mark − INITIAL_HEALTH_RATIO·price` for a buy, `price − INITIAL_HEALTH_RATIO·mark` for a sell (the fill-time `borrowCheck` inequality; conservative, the pool's own free funds are not credited) — and a debt-free pool no longer skips the gate (its first entry IS the borrow-at-fill case). H-05's raw-equity bound and de-lever pass-through are unchanged.
- **H-07's idle-repay paths are dead-safe, not deleted.** `repayIdlePoolBorrow` (every kill arm, `releaseDeferred`'s tail, `cancelPoolOrderInternal`, `cancelPoolRestingOrder`, `cancelSelfMaker`) still runs `deleveragePool`, which spends only free, non-earmarked funds against debt that exists — with no placement borrow to strand it is a no-op for the loan book on every kill path and stays as the invariant's backstop: an order that is gone holds no borrow. Cancel repays nothing because there is nothing (§G1).
- Not adopted (D5): (a) a distance-from-mark gate and (c) a per-pool share of the vault cap — optional follow-ups; (b) a TTL — rejected.

## The correctness piece: settle fills everywhere

Because limit entries **rest**, the pool's order can be filled *outside* `releaseDeferred` — by the AMM sweep or the rebalancer. `releaseDeferred` already covers fills where any deferred release crosses a pool's resting limit (the fill is in that release's trades), so the only gaps are the two AMM-as-taker paths. `settlePoolFills` is now called at: `releaseDeferred` (existing), `ammSweepResting`, and `ammExecuteRebalance`. The paths are disjoint (each trade is produced in exactly one), so no double-booking.

## Surfacing + cancelling pool orders

Pool orders are owned by the *pool principal*, not the user, so they don't appear in `getMyOrders` and `cancelMyOrder` rejects them (owner ≠ caller). Two pool-scoped endpoints fill the gap:
- `getPoolOrders(poolId)` — the pool's open + staged orders (resting limit entries), owner-gated.
- `cancelPoolOrder(poolId, orderId)` — cancel a staged or resting pool order; releases whatever of the pool's OWN funds the order soft-locked and repays nothing — an unfilled entry holds no borrow (the `deleveragePool` backstop it still runs is a no-op for the loan book, §G1).
- `repayPoolDebt(poolId, token, amount)` — the owner's lever for debt left idle against FREE pool funds (task 1788523828): pays `min(amount, debt, free)` in kind, where free excludes the earmark of the pool's resting EXITS (`poolRestingOrderNeeds` — a resting close must stay funded; an entry borrows at its fill and holds nothing back); returns the amount paid. The liquidation batch deliberately does not reconcile idle debt (a top-up is margin until the owner says otherwise).

The frontend shows the selected pool's resting orders under the open-position form with a Cancel button.

## What it unlocks for free

`closePosition` got the same optional `limitPrice` → **limit exits / take-profit**. Post-only/maker entry is the same `#limit` path. (Stop-loss is genuinely different — it needs a price-trigger watcher — and is out of scope.)

## API
- `openPosition(poolId, marketId, side, sizeBase, maxSlippage, limitPrice : ?Float)` — `null` = market (today's behavior); `?price` = limit.
- `closePosition(poolId, marketId, maxSlippage, limitPrice : ?Float)` — same.
- `getPoolOrders(poolId) : [Order]`, `cancelPoolOrder(poolId, orderId)`.
- Frontend: Market/Limit toggle + limit-price input on the open-position form; resting-orders list with cancel.
