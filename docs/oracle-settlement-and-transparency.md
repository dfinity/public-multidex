# Oracle-settled liquidation & why the ledger is public

*Reference / design note (2026-07-10). Explains two deliberate, related properties:
liquidations settle off an **external oracle**, and the account ledger is **public**.
Together they make MULTI/DEX transparent AND resistant to price-manipulation cascades.
Companion to the archive design (chain verifier / Proof-of-Reserves) and the margin design.*

---

## 1. Liquidations settle off the external oracle, never the local price

A position's health — and therefore its liquidation — is valued at `pool.refPrice`
(`marginPriceLookup`), and **`refPrice` is written only by the external price feed**, never
by trading on this venue:

- The sole value-writer is `applyFreshAggregate`, fed by a multi-source aggregate
  (Coinbase / OKX / KuCoin / CoinGecko) and gated three ways: a **minimum source count**,
  a cross-check against the **independent XRC oracle** with a divergence alarm, and a
  **jump breaker** (`acceptOrPendPrice`) that makes any large move wait for a second
  confirming sample before it is accepted.
- The trade / matching path only stamps the freshness *timestamp* (`refPriceUpdatedNs`),
  not the price. Local fills, order-book pressure, and AMM swaps do **not** move the mark.
- The only manual override, `setAmmRefPrice`, is hard-disabled outside `#dev`
  (`if (not IS_DEV) return #err`) — an operator cannot move the mark by hand on play or
  production.
- The margin engine additionally **refuses to act on a stale mark** (`marginPriceFresh` /
  `userMarksFresh`, `MARGIN_MAX_REFPRICE_AGE_NS`): it blocks opening/withdrawing and skips
  liquidation for any account whose valuation touches a mark older than the freshness
  window, rather than liquidating on frozen data.

**Consequence:** a trader cannot push the local price to trigger anyone's liquidation.
To move a liquidation trigger you must move the *global* spot price of the underlying
across major exchanges at once — impossible on a play venue, far beyond retail on a real
one, and if you could do it you would trade the deep global market directly. This is the
structural defense against engineered margin-call cascades.

## 2. The account ledger is public — on purpose

Every balance change is journalled to a tamper-evident event chain (the archive), and the
public Ledger page lets anyone re-hash that chain against the subnet-certified head and
**fold it into the liabilities half of a Proof of Reserves**: total owed to users,
verifiable by anyone, trustlessly. The reserves half — total assets held ≥ that figure —
becomes computable only once real custody exists (the bridge's NNS-custody target state,
`docs/bridge-and-cks-design.md` §11; on the play venue deposits are play money, so there
are no held assets to attest). Deposits and withdrawals (the money-flow ledger) and the
raw event tape stay open precisely so this proof works. Positions, fills, and debts are visible for
the same reason every on-chain perp venue makes them visible: solvency you can check
yourself beats solvency you have to trust.

## 3. The honest trade-off: a liquidation map is observable, but not weaponizable here

Because the ledger is public, a determined observer can fold per-pool collateral and debt
and, with the open-source margin constants and the public oracle price, compute where
liquidation levels cluster — a "liquidation map." This is inherent to any transparent
per-account ledger (Hyperliquid, GMX, dYdX all have public liquidation maps); you cannot
both prove per-account reserves and hide per-account liquidation levels.

What matters is that on this venue the map is **observability without a control lever**
(§1): knowing where the stops are buys you nothing you can act on locally, because you
cannot move the trigger. The residual — positioning ahead of a *genuine*, oracle-driven
liquidation wave — is mostly liquidity-providing, is bounded by the AMM's band-capped
backstop bid and the liquidation batch's oracle-mid netting, and exists on every
transparent venue. The thing worth protecting is therefore **oracle integrity**
(multi-source + XRC cross-check + jump breaker + staleness gate), not position secrecy.

## 4. What *is* kept private, and why

The one thing worth denying is cheap, **targeted** de-anonymization — the leaderboard
publishes principals, so "look up this named rival's exact position and liquidation price"
should not be a one-query operation. So:

- The archive's by-principal lookup (`getEventsForPrincipals`) is **owner-gated**: only the
  exchange may call it, and a user reaches their *own* history through the exchange's
  `getMyArchivedEvents` federation.
- The live order book is served **unattributed** (the public OQL `order` entity carries no
  owner), and per-user pools / positions / balances are owner-scoped.

Deep de-anonymization by scraping the whole public tape remains possible in principle (it
must, for the reserve proof) — but it is expensive and, per §3, not weaponizable for
cascade engineering on an oracle-settled venue. The public tape is a spectator's view, not
a control panel.

---

**Summary.** Transparency and manipulation-resistance are not in tension here because they
rest on different mechanisms: the ledger is public for verifiable solvency, and
liquidations are safe from that publicity because they settle off an external oracle no
local trader can move. Protect the oracle; publish the ledger; gate only the cheap
targeted lookups.
