# Margin Pools — design & implementation contract

*2026-06-10. The architecture agreed in discussion ("C with shared pools"): first-class positions, margin-segregated, with optional cross-margin via shared pools. This is the spec the code satisfies; it supersedes the derived-positions Phase-1 in `docs/margin-simplification-design.md`.*

## The one idea

The existing engine — `Accounts`, `BorrowEngine`, `MarginEngine.valuations`, `Liquidator`, and the matching engine — is **already keyed by principal**. Today each user has exactly one implicit margin context (their whole wallet), which is why cross-margin is a whole-portfolio property and why collateral can escape it.

A **margin pool is a user-owned sub-account principal.** Everything principal-scoped already works on it unchanged:

- A pool's **collateral** = the balances held at the pool's principal.
- A pool's **debt** = the loans `BorrowEngine` holds for the pool's principal.
- A pool's **health** = the existing `getHealth(...)` applied to the pool's principal. *No new health math.*
- **Liquidation** already iterates loan-holding principals — point it at pools.

So:
- **Isolated margin** = a pool with one position.
- **Cross margin** = a pool with several positions sharing its collateral.
- **Spot trading** = the free wallet (no pool, no leverage) — unchanged.

Solvency stays **local** (per pool, a handful of positions), the vault stays a **lender** (pools borrow from it), and the **collateral-escape class is structurally gone**: the free wallet is no longer collateral, and a pool only ever borrows / trades / repays — it never `depositLp`s or `stakeInsurance`s, so there is nothing to gate and nothing to escape into.

## Schemas

New module `src/backend/lib/MarginPools.mo`. Two stable record types plus a registry; positions carry the one genuinely-new piece of state (entry price).

```motoko
// A user-owned margin sub-account. Its balances/loans ARE its collateral/debt.
public type Pool = {
  id        : Nat;
  owner     : Principal;        // who may act on it
  label     : Text;            // user-facing name ("BTC swing", "hedge")
  mode      : { #isolated; #cross };  // isolated => engine refuses a 2nd market
  createdAt : Int;
};

// A first-class position inside a pool. `size` is RECONCILED to the pool's
// real net exposure in the market (base held + reserved − base borrowed);
// `entryPrice` and `realizedPnl` are the new STORED truths (not derivable).
public type Position = {
  poolId      : Nat;
  marketId    : Types.MarketId;   // "BTC-ICPUSD"
  baseToken   : Types.TokenId;    // "BTC"
  size        : Float;            // signed base units: + long, − short
  entryPrice  : Float;           // VWAP, in quote
  realizedPnl : Float;           // cumulative, in quote (ICPUSD)
  openedAt    : Int;
};
```

Registry state (lives in main.mo, all stable):
```motoko
var nextPoolId    : Nat = 1;
let pools         : Map<Nat, Pool>                    // poolId → Pool
let poolsByOwner  : Map<Text, [Nat]>                  // ownerText → poolIds (UX index)
let positions     : Map<Text, Position>              // key = poolId#marketId → Position
```

### Pool principal derivation (deterministic, pure)
A pool needs a stable principal to hold balances and borrow under. Derive it from the owner + id, mirroring the existing `insurancePrincipal()` self-derived pattern:

```
poolPrincipal(owner, poolId) = Principal.fromBlob( sha256( "uplands-pool" ‖ owner.toBlob ‖ poolId ) )[..29]
```

Self-authenticating-shaped, collision-resistant, and **not a signable identity** — it is an internal balance bucket the engine operates on behalf of `owner` (exactly how `ammPrincipal`/`insurancePrincipal` already work). The map `pools` records `owner`, so authorization is "does `msg.caller` own this pool?".

## Invariants (the verifiable core)

For a pool with principal `P`:

```
collateralUsd(P) = Σ_token (balance(P,token) + reserved(P,token)) · price · LTV   // MarginEngine.valuations — EXISTS
debtUsd(P)       = Σ loans(P)                                                       // BorrowEngine.debtUsdTotal — EXISTS
equityUsd(P)     = collateralUsd(P) − debtUsd(P)
healthy(P)       ⟺  debtUsd(P) ≤ ε  ∨  collateralUsd(P) / debtUsd(P) ≥ MAINTENANCE (1.15)
```

This is the existing `getHealth`, now scoped to a pool instead of a whole portfolio. Cross-margin is just `Σ` over the pool's several positions' tokens; isolated is the one-term case. **Same function, same proof obligation, local scope.**

Position display (pure, in MarginPools.mo, fully unit-testable):
```
notional       = |size| · markPrice
unrealizedPnl  = (markPrice − entryPrice) · size            // signed: short (size<0) profits when mark<entry
roe            = unrealizedPnl / pool.marginContribution    // pool equity attributable to this position
```

Account-level UX numbers (per pool, and summed for the owner):
```
netAccountValue = Σ_pool equityUsd(pool)  +  free-wallet spot value      // raw, not LTV-weighted, for display
marginUsage     = MAINTENANCE · debtUsd(P) / collateralUsd(P) ∈ [0,1]    // % to liquidation = 1 − usage
```

### Liquidation price (pure solver)
The mark at which a single market's move brings pool `P` to maintenance, holding other marks fixed — solve `collateralUsd(P; price_X) = MAINTENANCE · debtUsd(P; price_X)` for `price_X`. Closed-form for the one-directional cases (long: collateral falls as price falls; short: debt rises as price rises); 1-D bisection for mixed. Implemented as `liqPrice(otherCollateralUsd, debtUsdExX, sizeX, ltvX, side) : ?Float`.

## Position accounting (the heart — pure `applyFill`)

On every fill that touches a pool, update the position's VWAP entry and realized PnL. Standard perp accounting, pure and exhaustively testable:

```
applyFill(size, entry, fillSize, fillPrice) -> (newSize, newEntry, realizedDelta):
  newSize = size + fillSize
  if size == 0 or sign(fillSize) == sign(size):            // open or increase
     newEntry      = (|size|·entry + |fillSize|·fillPrice) / (|size| + |fillSize|)   // = fillPrice when size==0
     realizedDelta = 0
  else:                                                     // reduce or flip
     reduceQty     = min(|fillSize|, |size|)
     realizedDelta = (fillPrice − entry) · reduceQty · sign(size)
     newEntry      = if |fillSize| ≤ |size| then entry      // reduce: entry unchanged
                     else fillPrice                          // flip: remainder opens at fill price
  if newSize == 0: newEntry = 0
```

Conservation check (a test): for any sequence of fills, `realizedTotal + (markPrice − entry)·size == Σ (markPrice − fillPrice)·fillSize` — i.e. the position's marked PnL equals the cash-flow PnL. This is the invariant that makes the accounting "obviously correct."

## How user actions map (orchestration, Phase 2)

All scoped to the pool principal `P = poolPrincipal(owner, poolId)`, reusing existing primitives:

| Action | Steps (engine acts as `P`) |
|---|---|
| **Create pool** | allocate id; record `Pool`; (no funds yet) |
| **Fund margin** | transfer ICPUSD `owner` free wallet → `P` (the segregation boundary) |
| **Open/Increase Long** (size S) | `BorrowEngine.borrowCheck(P, QUOTE, …)` for the leveraged part (gated to INITIAL on `P`, reserving nothing), stage a buy for `S` as `P`; each FILL slice borrows exactly its shortfall (`poolFundForFill`, H-34 / D5 (d)); `applyFill` updates the position |
| **Open/Increase Short** (S) | `borrowCheck(P, base, S)`, stage a sell for `S` as `P`; the fill borrows the base it delivers; `applyFill` |
| **Decrease / Close** | trade out of the net exposure as `P`, `repay` the matching debt; `applyFill` realizes PnL; settle interest dust via `settleAllFromQuote` |
| **Withdraw margin** | only down to keeping `health(P) ≥ INITIAL`; transfer `P` → owner free wallet |

`mode = #isolated` ⇒ refuse opening a second `marketId` in that pool. `#cross` ⇒ allow many.

Sealed-model interaction is unchanged: these place orders that stage and fill on the next GEPTOR (~1–2 s), so a freshly-opened position is **pending** until settlement, and `applyFill` runs at settlement (hook the existing fill/settle path for pool principals), never at submit.

## What gets reused vs. new vs. retired

**Reused unchanged (principal-scoped already):** `Accounts`, `BorrowEngine` (borrow/repay/accrue/health), `MarginEngine.valuations`, `Liquidator` (operates per-principal), the matching/sealed engine, the oracle, the vault.

**New:** `MarginPools.mo` (types + pure math + principal derivation); the registry state; the fund/withdraw + open/close/adjust endpoints; `getMyPools`/`getMyPositions`; the `applyFill` hook in the settlement path for pool principals; per-pool liquidation iteration; pool-scoped order/position views.

**NOT retired (Phase 4 decision — revised after investigation):** the whole-wallet cross-margin model **stays**, coexisting with pools. See "Phase 4" below for why. The collateral-escape gates added 2026-06-10 (`gateInitialMargin` on `depositLp`/`stakeInsurance`, `softLockedReserved`, the `withdrawLp` debt-block) **stay permanently** as defense-in-depth — they're inert for pool-only users and are the subject of the security regression tests.

## Phase 4 — coexistence, not migration (decision, 2026-06-10)

The original sketch was "force-migrate the loan ledger into default pools and retire whole-wallet cross-margin." Investigation changed the call:

- **Nothing to migrate.** The live sim uses *no* whole-wallet margin (no loans, no margin accounts, insurance buffer $0, netted volume $0). An eager migration would convert an empty set.
- **Whole-wallet margin is load-bearing for the test suite.** Ten test files plus the two security-regression tests (`test_margin_collateral_escape`, `test_liquidation_staged_shield`) exercise `openMarginAccount`/`borrowAsset`. Removing the model would delete that coverage and the subject of the gates.
- **The gates are now correct and inert.** The 2026-06-10 fixes made whole-wallet margin safe; the gates are harmless for pool-only users. Removing them strips working safety for no benefit.
- **The two models compose cleanly** because both are principal-scoped. Whole-wallet = margin against your own principal; a pool = margin against a sub-account principal.

**Decision:** pools and whole-wallet cross-margin **coexist**. Pools are the segregated, recommended, position-native path (the product emphasis); whole-wallet remains for existing tests/users and winds down naturally (no new-use is forced off, but nothing depends on it for new flows). **No data migration. Gates stay permanently.** If a forced eager migration is ever wanted, it's a separate, explicit decision — it would need to resolve the "whole wallet → which collateral backs which loan" ambiguity, which is exactly the imprecision pools remove.

What Phase 4 *did* add: a consolidated **`getMyAccountSummary`** — net account value and "% to liquidation" aggregated across the free wallet, the (legacy) whole-wallet margin, and every pool. That's the original UX ask ("net value of their account, and their % away from liquidation"), now answered for the whole account in one read. Net worth nets each principal's raw holdings against its debt (separate principals → no double-count); "% to liquidation" is `1 − worst margin usage` across all leveraged contexts.

## Phasing
1. **Design** (this doc).
2. **Pure core** — `MarginPools.mo` types + math + `tests/MarginPools.test.mo`, verified by `mops test`. No canister change. ← *next*
3. **Registry + endpoints** — fund/open/close/adjust + queries, build-verified, not deployed.
4. **Liquidation + settlement hooks** — `applyFill` at fill; per-pool liquidation; pool-scoped bad-debt waterfall.
5. **Coexistence + consolidated account summary** (done — see "Phase 4" above): whole-wallet margin stays, gates stay, `getMyAccountSummary` aggregates net value + % to liquidation across everything. *No data migration.*
6. **Deploy** — gated on the canister memory ceiling (new stable maps add state; the reaper must keep `ordersRetained` falling, and watch `memorySizeBytes`), plus a real run of `tests/test_margin_pools.sh` in a free environment (it calls `resetExchange`).
7. **Frontend** positions UX (the HyperLiquid-style table now reads stored truth).

## Risks / honest caveats
- **Memory.** New stable maps (pools/positions) add to a canister already near its ceiling. Phase 5 deploy must follow the orders-map leak fix (chip `task_daef6a4d`) or a reset. Phases 2–4 are build-verified only.
- **Order/position views** must union a user's pools (the order book keys by the pool principal, not the user). Manageable via `poolsByOwner`.
- **Intra-pool contagion is the opt-in:** putting two positions in one `#cross` pool means one's loss can eat the other's margin — that's cross-margin, and `#isolated` (one position/pool) avoids it. The user chooses per pool.
- **Capital efficiency:** the free wallet is no longer auto-collateral — margin is explicitly funded into pools. That's the segregation that buys local verifiability; it's a deliberate, clarifying trade (and matches HyperLiquid/dYdX).
