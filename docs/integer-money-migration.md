# Integer-money migration (Float → fixed-point Nat/Int @ 10⁸)

Status on branch `integer-money-mainmo` (off `main`). **DONE + VERIFIED END-TO-END.**
Backend (12 libs + `main.mo` ~341 sites + mixins) builds green, 12/12 lib tests
green. Frontend converted (IDL aligned to the integer `.did`; new
`src/frontend/src/money.js` boundary normalizer; `toE8()` write boundary). All
seed/sim scripts → base units. Verified: reinstall backend → `seed.sh full` →
**on-chain reconciliation EXACT** (alice 5M − 1M AMM = 4M ICPUSD to the base unit;
vault valuePerLP = exactly 1.0) → deploy frontend → UI order book renders human
units, zero base-unit leaks. **The only step left is the one-way door: merge
`integer-money-mainmo` → `main`** (recommend a human review of hot-path
`Fixed.mul/div` rounding directions first — the one thing tests can't prove).

## Frontend approach (as built) — boundary normalizer

Candid `Nat`/`Int` money decodes to **`bigint` base units**. Rather than ÷1e8 at
~360 read sites, `money.js` normalizes at the actor boundary: `wrapActor()`
Proxies every real actor and `normMoney()` recursively scales only `bigint`
leaves whose field-name is in a money-set *derived mechanically from the IDL
diff*. The deliberate Float islands decode to `Number` (not `bigint`), so a
"scale bigints only" rule skips them for free — even where they share a name
with money (`price` is money on Order, a Float island on Aggregate). Bare-scalar
(`getBalance`), `(token,amount)`-tuple (`getBalances`), and `{ok:money}`
(`depositLp`/`stakeInsurance`/`unstakeInsurance`) returns are special-cased; the
`userBalances` poll tuple is handled at its call site. The mock/demo actor (human
`Number`s) is left unwrapped and stays representation-consistent. Writes go out
via `toE8(v) = BigInt(Math.round(v*1e8))` on every amount/price/qty/slippage/
limit arg. **Deploy with `icp deploy frontend --identity anonymous`** — `icp
canister install frontend` loads the asset wasm but does NOT upload `dist/`.

The historical implementation contract follows (kept for reference).

## Frontend plan (the remaining work — UI/display layer)

The backend ledger is now exact integer, so a frontend scale bug only *displays*
wrong numbers — it can't corrupt money. Candid `Nat`/`Int` decode to **`bigint`**
in JS.

1. **IDL factory** (`src/frontend/src/main.js`, ~215 `IDL.Float64`): change money
   fields to `IDL.Nat`, signed ones to `IDL.Int` (equityUsd, priceChange24hAbs,
   headroom, position size, unrealizedPnl, realizedPnl, valueUsd,
   netAccountValueUsd, gainLossPct, deltaColl). KEEP `IDL.Float64` for the
   deliberate Float islands surfaced over Candid: `PoolValueInfo.volRegime`,
   `PriceFeed.Aggregate`
   (price/stddevBps), and OQL numeric values (the backend exposes those via
   `Fixed.toFloat`). Use `.mops/.build/backend.did` as the authoritative
   per-field reference.
2. **Read boundary** (~360 sites): a money value off the backend is now a
   `bigint` base unit. Add `const e8 = (x) => Number(x) / 1e8;` and wrap reads,
   OR make the `format.js` helpers (formatQty/formatNum/formatPrice) accept
   `bigint` and `/1e8` internally — the latter centralizes most of it.
3. **Write boundary**: every amount/price/qty sent to the backend →
   `BigInt(Math.round(v * 1e8))`.
4. `seed.sh`: amounts → base-unit integers (`× 1e8`) — `setTestBalance`,
   `setAmmRefPrice`, `seedAmmPool`, `injectHistoricalTrades`, etc. now take Nat.
5. `icp build backend` (green) → `icp canister install --mode reinstall` → reseed
   → sim → reconcile (Σ balances == Σ deposits exact, no traps, UI renders);
   then merge branch → `main`.

## Why

`Float` as money is the one true one-way door before production: non-associative
rounding drift in cumulative ledger math, no exact "Σ balances = Σ deposits", and
ε-tolerance hacks (`< 0.0000001`) sprinkled through every settlement guard. We move
the **ledger** to exact integers at a uniform 10⁸ (e8s / ICRC-standard) scale.

## The rule (memorise this — it drives every `mulDiv` call)

Money is `Nat` (non-negative) or `Int` (genuinely signed: PnL/equity, 24h change,
headroom, position size). Everything at **10⁸**: `1.0` token = `100_000_000`; a
fraction like LTV `0.85` = `85_000_000`; a price `$100000` = `100000 * 10⁸`.

**Round against the user / toward protocol solvency**, always:
- Collateral value **down**; debt value **up**; interest **up**.
- LP mint/burn **down** (depositor/withdrawer gets no more than fair share).
- Caps (bid cap, 2.5× per-market, vault borrow cap) **down** (tighter).
- Order-cost gates **up** (reserve at least the cost); the settled trade cost is
  **down** and is the SINGLE value used for both buyer-debit and seller-credit
  (peer-to-peer conservation — no protocol leak).
- Liquidation penalty **down** so `refund = seize − repay − penalty ≥ 0` (then
  safe-subtract). Seize sizing **up** (reach target; over-seize is refunded).

Dust always falls to the protocol; value is never created. All ε tolerances are
**deleted** — comparisons are exact (`== 0`, `>= qty`). Nat subtraction that could
underflow is guarded: `if (a > b) { a - b } else { 0 }`.

## The primitive — `src/backend/lib/Fixed.mo`

`SCALE = 100_000_000`. `mulDiv(a,b,denom,roundUp)`; `mul(a,b,roundUp)=a·b/SCALE`;
`div(a,b,roundUp)=a·SCALE/b`; `fromFloat`/`toFloat` for the estimator boundary.
`Nat`/`Int` are arbitrary-precision bignums, so `price·qty` intermediates never
overflow — the decisive advantage over `Nat64`.

## Deliberate `Float` islands (NOT a bug — do not "fix")

Two estimators stay `Float`, behind a quantize-to-`Nat` boundary, exactly as real
DeFi medianizers do. Their outputs settle/store as `Nat`, so a sub-unit difference
can never move value:

1. **`PriceFeed.mo`** — oracle aggregation (median/stddev/sqrt over noisy external
   decimal feeds). Its aggregated price is quantized via `Fixed.fromFloat` at the
   `main.mo` boundary where it becomes a `Nat` refPrice/mark.
2. **AMM market-making heuristics** (`AMM.mo`) — `volRegime` (log-returns), inventory
   skew/floor/depth multipliers, rebalance sizing. They read `Nat` reserves via
   `Fixed.toFloat` and quantize every output (quote price, rebalance qty, bps lean)
   back to `Nat`. The AMM **LP ledger** (reserves, refPrice, totalLPSupply,
   value/mint/burn, quoted prices) is exact integer.

## Done (12 modules, all `mops test` green in base units)

`Fixed`, `Accounts`, `Types` (all money fields → Nat; `equityUsd`/`priceChange24hAbs`/
`headroom` → Int; constants → 10⁸; `marginLTV`/`borrowApr` → `?Nat`; added
`HEALTHY_INF` sentinel), `MarginEngine`, `BorrowEngine`, `VaultMath`, `MarginPools`
(signed `size`/PnL → Int; VWAP scale cancels), `OrderBook`, `MatchingEngine`,
`Liquidator` (signed seize denom; penalty/refund invariant), `LiquidityManager`,
`AMM`.

## Remaining

### 1. `main.mo` (~7,589 lines, ~341 `Float` sites) — COMPILER-DRIVEN

`main.mo` is one actor: it compiles all-or-nothing. Convert the state + closures +
Candid first, then let `icp build backend` enumerate every downstream type error and
fix them. Do NOT hand-hunt 341 sites blind.

- **Stable state → Nat/Int** (dev reseed absorbs the layout change): the per-market
  record (`volume`, `openPrice`), `marketStats : Map<Text,(Float,Float)>`,
  `reservedBalances : Map<Text,Float>`, `pendingQtyByMaker : Map<Nat,Float>`,
  `userLpBalances : Map<MarketId, Map<Text,Float>>`, and the vault scalars
  (`vaultLPSupply`, `vaultCostBasis`, …) → Nat/Int.
- **Balance closures → Nat**: `availableBalance`/`reservedBalance : (Principal,
  TokenId) -> Float` → `-> Nat`; `getAvailable`/`getReserved`/`reserve`/`release`
  helpers; the `Float.max(0, cur-qty)` release guards → safe-subtract.
- **Money constants → 10⁸**: `MARGIN_CASH_SETTLE_USD 50.0 → 5_000_000_000`;
  price-band clamps `OUT_OF_BAND_PCT 0.06`, `USERS_ONLY_CLAMP_PCT 0.02` → `6_000_000`
  / `2_000_000` if they multiply prices in fixed-point (else keep Float + quantize).
- **Stay Float** (heuristics, like the AMM islands): the staleness premium
  (`STALE_RATE_BPS/VOL_Z/MAX_BPS`, `√age`), requote-drift
  detection (`AMM_FORCE_REQUOTE_DRIFT_BPS`), `AMM_CASH_FLOOR_FRAC`,
  `AMM_QUOTE_DEPTH_FRACTION`. Read `Nat` via `toFloat`, quantize back where the
  result becomes an order/price.
- **PriceFeed boundary**: at the oracle-update site, `Fixed.fromFloat(aggregated)` →
  `Nat` before `AMM.withRefPrice` / mark storage.
- **Settlement/value sites** (`pm.price * pm.quantity`, `tradeValue`, sweep/netting
  math) → `Fixed.mul/div` per the rule above.
- **Candid API**: every public `func` with a `Float` arg/return → `Nat` (or `Int`
  for signed). This is the wire change the frontend IDL must mirror.
- **Display/log**: `Float.toText` in event/log strings → `Nat.toText` (or a `/1e8`
  formatter).

Then: `icp build backend` green → `icp canister install --mode reinstall` → reseed →
sim → reconcile (Σ balances == Σ deposits, no traps).

### 2. Frontend (`src/frontend`)

Candid `Nat`/`Int` decode to **`bigint`** in JS. Update the hand-maintained IDL
factory (`Float` → `Nat`/`Int` on every money field/arg), then every boundary:
display `Number(x) / 1e8` (or a bigint formatter) and input `BigInt(Math.round(v *
1e8))`. Audit all amount/price/qty handling — it shifts from `number` to `bigint`.

### 3. `seed.sh` + verify + merge

Seed amounts → base-unit integers (`× 1e8`). Reinstall + reseed + relaunch sim;
verify the UI renders + the reconciliation holds; then merge `integer-money` → `main`.
