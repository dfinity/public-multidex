# Design: simplify margin into long/short "positions"

*Written 2026-06-09. A design proposal, not an implementation. Grounded in `MarginEngine.mo`, `BorrowEngine.mo`, `Types.mo`, and the sealed-matching model in `main.mo`. The HyperLiquid positions screenshot is the UX target, not a literal instruction.*

*Note (2026-10-31): the orchestration below is written borrow-THEN-trade — borrow the leveraged portion, then place the order. That timing is history. Since 2026-09-05 (operator decision D5 option (d); `docs/limit-order-positions-design.md`) leverage is borrowed when an order FILLS (`poolFundForFill`): a staged or resting entry holds no debt and accrues no interest, cancelling it repays nothing, and the vault's lending capacity is consumed by live positions only. The position/PnL presentation layer this proposal argued for is what shipped as margin pools (`docs/margin-pools-design.md`).*

## Goal

A trader with a margin account should think in **positions**, not in borrows. They press **Long** or **Short** on a coin, pick a size/leverage, and see one row per open position plus two headline numbers — **net account value** and **% to liquidation**. All the machinery that actually backs this (cross-margin collateral, per-asset LTV, borrow APR, health ratio, liquidation) stays exactly as it is underneath; we add a *presentation + orchestration* layer on top. No rip-and-replace.

## What exists today (and why it's hard to read)

The margin model is **cross-margin and borrow-based** (`MarginEngine.mo` header):

- Opening a margin account is just an opt-in flag (`{ openedAt }`). From then on the user's **entire portfolio** is collateral, valued LTV-weighted: `collateralUsd = Σ_t (balance_t + reserved_t) · price_t · LTV_t` over `MARGIN_COLLATERAL_TOKENS = [ICPUSD, BTC, ETH, SOL, ICP]`, with `LTV = ICPUSD 1.00, BTC/ETH 0.85, SOL 0.75, ICP 0.70`.
- Leverage comes from **borrowing**: borrowed tokens land in the user's spendable balance and themselves count as collateral. So "go long BTC" today is a **two-step manual recipe**: `borrowAsset("ICPUSD", X)` → `placeMarketOrder(BTC-ICPUSD, #buy, …)`. "Go short BTC" is `borrowAsset("BTC", S)` → sell it.
- Risk is summarised by `getMyMarginHealth() : MarginHealth` = `{ collateralUsd, debtUsd, equityUsd, healthRatio = collateralUsd/debtUsd, maintenanceRatio = 1.15, isLiquidatable }`. Open/increase requires health ≥ 1.25 (`INITIAL_HEALTH_RATIO`); liquidation triggers below 1.15 (`MAINTENANCE_HEALTH_RATIO`).

**The friction:** the user has to (a) know the borrow-then-trade recipe, (b) reason about LTV haircuts and a unit-less health *ratio*, and (c) mentally reconstruct "what is my actual BTC exposure and where do I get liquidated." There is no position object anywhere — exposure is implicit in `(spot balances − debts)`. Nothing tracks an entry price, so there's no PnL or ROE to show.

## The core idea: a *derived* position layer

In a cross-margin account, the position in coin **X** is simply the user's **net exposure** to X:

```
sizeX  =  (spotX + reservedX)  −  debtX          // signed, in base units
```

- `sizeX > 0` → **long** X (you hold more X than you owe). A cash-funded or borrowed-ICPUSD-funded BTC buy gives `+S`.
- `sizeX < 0` → **short** X (you owe more X than you hold). Borrowing S BTC and selling it gives `−S`.
- ICPUSD is the **margin/settlement** asset, not a position (it's the unit everything is quoted in).

This needs **no change to the core ledger** — net exposure is already fully determined by balances and debts. The only thing missing for a HyperLiquid-style table is an **entry price** (cost basis), which is one small addition (below). Everything else — collateral, debt, health, liquidation — is reused verbatim.

## The two headline numbers

### Net Account Value (equity)

Show the **raw, un-haircut** liquidation value of the account (this is what HyperLiquid calls "account value"):

```
netAccountValue  =  Σ_t (balance_t + reserved_t) · price_t   −   Σ debt · price      // no LTV
```

LTV is a *risk* haircut used only for the liquidation test; for "what is my account worth right now" the user wants the un-haircut figure. (Keep `MarginHealth.equityUsd`, the LTV-weighted version, internally — it drives liquidation, not display.)

### % to liquidation

Offer a robust account-level gauge plus an intuitive per-position price distance.

- **Account-level margin usage** (primary, always well-defined): `usage = maintenanceRatio · debtUsd / collateralUsd` ∈ [0,1]. `usage → 100%` is the liquidation line; "% to liquidation" `= 1 − usage`. This is monotone, never divides awkwardly, and works for multi-position accounts. (Equivalent to HyperLiquid's "margin ratio" gauge.)
- **Per-position liquidation price** (for the table): the mark at which *this* market's move alone brings the account to maintenance, holding other marks fixed — i.e. solve `collateralUsd(price_X) = 1.15 · debtUsd(price_X)` for `price_X`. For the common one-directional position the closed forms are:
  - **Long X** (debt is ICPUSD `D`, you hold `S` of X): `liqPriceX = (1.15·D − otherCollateralUsd) / (S · LTV_X)`. Falls below this → liquidation. `%toLiq = (markX − liqPriceX)/markX`.
  - **Short X** (debt is `S` of X, collateral is cash/other): `liqPriceX = otherCollateralUsd / (1.15 · S)`. Rises above this → liquidation. `%toLiq = (liqPriceX − markX)/markX`.

  Be explicit in the UI that liq price is a **cross-margin projection** (other positions held constant) — HyperLiquid shows the same caveat for cross positions.

## The positions table (each column → exact UPLANDS formula)

| HyperLiquid column | UPLANDS definition |
|---|---|
| **Coin** | market base token (BTC, ETH, SOL, ICP) |
| **Size** | `sizeX = (spotX + reservedX) − debtX`, signed (long +, short −) |
| **Position Value** | `|sizeX| · markX` where `markX` = pool `refPrice` (oracle mid) |
| **Entry Price** | VWAP cost basis from the new tracker (below) |
| **Mark Price** | pool `refPrice` |
| **PNL (ROE %)** | unrealized `= (markX − entryX) · sizeX` (signed handles shorts). ROE `= unrealizedPnL / marginAllocated` |
| **Liq. Price** | per-position projection above |
| **Margin** | cross-margin: account equity backs all positions. Display either the whole-account equity, or an allocation `= positionValue / Σ positionValue · equity` |
| **Funding** | **borrow interest accrued** on the debt funding this position. UPLANDS is spot+margin, not a perp — there is no funding *rate*, but the borrow APR (`DebtEntry.apr`, already surfaced) is the exact economic analog (cost of carry). Label it "Borrow cost" if "Funding" is misleading. |

The honest mapping note on **Funding**: a perp's funding rate keeps the perp pegged to spot; here there is no perp, so carry = the APR you pay to borrow the asset you're short (or the ICPUSD you borrowed to go long). Same role (it's what your position costs you to hold over time), different mechanism.

## One-click actions (the real simplification)

Replace the manual borrow-then-trade recipe with intent-level macros that orchestrate the existing primitives atomically:

- **Open Long(coin, size, leverage)** → borrow the ICPUSD needed for the leveraged portion (capped so post-trade health ≥ `INITIAL_HEALTH_RATIO` 1.25), then place the buy.
- **Open Short(coin, size, leverage)** → borrow `size` of the base, then place the sell.
- **Increase / Decrease(coin, Δsize)** → borrow/repay + trade the delta.
- **Close(coin)** → trade out of the net exposure and repay the matching debt; settle interest dust via the existing `MARGIN_CASH_SETTLE_USD` path.

The backend already has the safety rails these macros need: `checkInitialMargin` (the 1.25 gate on the order leg), `BorrowEngine.borrow` (post-borrow health ≥ 1.15, vault borrow cap), and the cross-margin valuation. The macro just composes them and rolls back if a leg fails.

**Critical interaction with the sealed model:** orders don't fill synchronously — `placeMarketOrder` *seals* the order and it releases on the next fresh-price GEPTOR (~1–2 s; see `docs/price-deviation-explained.md`). So "Open Long" can't report a filled position instantly. The UX should show the position as **pending** (the order already appears in Open Orders) and resolve it when settlement lands — exactly how every order behaves today. The cost-basis tracker must update at **settlement** time, not submit time.

## Backend additions (scoped — reuse existing patterns)

1. **Cost-basis tracker** — `Map<(user, marketId), { sizeBase, vwapEntry, realizedPnl }>`, updated in the trade-settlement path for both sides of every fill (mirror the `vaultCostBasis` pattern already used for the LP vault). Increasing exposure updates VWAP; reducing/flipping realizes PnL. This is the only genuinely new state.
2. **`getMyPositions() : [Position]`** — derives `size` from balances/debts, joins the cost-basis tracker, computes value/PnL/ROE/liqPrice per the formulas above. Pure read.
3. **Account summary** — extend `getMyMarginHealth` (or a new `getMyAccountSummary`) with `netAccountValue` (raw) and `marginUsage` (% to liq). Pure read.
4. **Liq-price solver** — a small 1-D solver (closed-form for one-directional positions; Newton/bisection for mixed). Pure read.
5. **Orchestration endpoints** — `openLong / openShort / adjustPosition / closePosition`, each a thin wrapper over `borrow* + place*Order` with the initial-margin gate and rollback. No new risk logic.

## Edge cases & honest caveats

- **Cross vs isolated.** This is cross-margin: one liquidation condition for the whole account, per-position liq price is a projection. HyperLiquid offers isolated margin too; defer that to a later phase (it needs per-position collateral segregation the current model doesn't have).
- **LTV asymmetry** means leverage differs by asset (≈3.3× into BTC at 0.85 LTV, less into ICP at 0.70). The "leverage" the macro offers must respect this; surface the achievable max per coin rather than a flat number.
- **Settlement latency** (sealed model): positions are eventually-consistent within ~2 s. Never show a just-submitted position as realized.
- **Partial fills / kills**: a market order is fill-or-kill or partial-drop on release; the macro must reconcile the actual fill with the borrow it took (repay the unused borrow if the trade leg under-fills).
- **Dust & interest**: closing should zero the position *and* the financing debt; reuse `settleAllFromQuote` / `MARGIN_CASH_SETTLE_USD` for residual interest so users aren't stranded needing a token they no longer hold.
- **Net-exposure ambiguity**: if a user *also* holds a coin as a plain spot investment (not as a leveraged position), `size = spot − debt` lumps it in. That's acceptable and correct for a cross-margin account (it *is* all one collateral pool), but the entry price shown is the blended VWAP of all their acquisitions — worth a tooltip.

## Suggested phasing

- **Phase 1 — display only (no risk-logic change):** cost-basis tracker + `getMyPositions` + `netAccountValue` + `marginUsage`. Delivers the entire "understand my exposure and risk" value with zero new trust surface. This is the bulk of what the user asked for ("net value of their account… and their % away from liquidation").
- **Phase 2 — one-click actions:** the open/short/close orchestration macros.
- **Phase 3 — refinements:** isolated-margin option, volatility-tuned LTV (already on the roadmap), and a "Funding"/borrow-cost history panel.

Phase 1 is self-contained, low-risk, and independently shippable — recommended starting point.
