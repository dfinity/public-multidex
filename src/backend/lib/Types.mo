import Principal "mo:core/Principal";

module {

  // ── Money representation ────────────────────────────────────────────
  // Every balance, amount, price, quantity, and ratio below is an INTEGER in a
  // uniform 10^8 base-unit fixed-point scale (e8s / ICRC standard — see
  // lib/Fixed.mo): 1.0 whole token = 100_000_000 units; a fraction like an LTV
  // of 0.85 = 85_000_000; a price of 100000 ICPUSD = 100000 * 10^8. `Nat` for
  // non-negative quantities, `Int` only for genuinely-signed ones (PnL/equity,
  // 24h change, headroom). Timestamps stay `Int` nanoseconds (not money).

  public type TokenId = Text;
  public type MarketId = Text;

  public type Side = { #buy; #sell };
  public type OrderType = { #market; #limit };
  public type OrderStatus = { #open; #partiallyFilled; #filled; #cancelled };

  // Compact record of a closed (#filled or #cancelled) order, appended once
  // to the owner's capped per-user history when the reaper removes the live
  // record from the order map (heap GC — see main.mo reapClosedOrders).
  public type ClosedOrderRecord = {
    id : Nat;
    marketId : MarketId;
    side : Side;
    orderType : OrderType;
    // #limit: the limit price the order rested at.
    // #market: SEMANTICS SWITCHED 2026-08-20 (task 1787182538). Rows sealed
    // AFTER that change carry the VOLUME-WEIGHTED average execution price
    // (VWAP) of the order's immediate fills, floored to e8 (stamped in
    // MatchingEngine.executeLimitOrderProtected's #market branch). Rows
    // sealed BEFORE it carry the mid-clamped slippage-CAP price the order
    // was released with — a one-directional understatement of execution
    // quality (per-fill truth was always in Trade History). The boundary
    // is that task's merge commit on main (archive note carries the sha).
    // Zero-fill edge (unchanged, pre-existing sentinel): a #market attempt
    // that fills NOTHING returns a synthetic id-0 #cancelled record still
    // priced at the cap, which never enters the order store — so NO
    // ClosedOrderRecord is ever sealed for it, before or after the switch.
    price : Nat;
    quantity : Nat;       // original requested quantity
    filled : Nat;         // cumulative fill at close
    status : OrderStatus; // #filled or #cancelled only
    placedAt : Int;
    closedAt : Int;       // reap-observed (≤ one sweep after the actual close)
  };

  public type Order = {
    id : Nat;
    marketId : MarketId;
    owner : Principal;
    side : Side;
    orderType : OrderType;
    price : Nat;
    quantity : Nat;
    filled : Nat;
    status : OrderStatus;
    timestamp : Int;
    originalQuantity : Nat;
  };

  public type Trade = {
    id : Nat;
    marketId : MarketId;
    buyOrderId : Nat;
    sellOrderId : Nat;
    buyer : Principal;
    seller : Principal;
    price : Nat;
    quantity : Nat;
    timestamp : Int;
    // The originating order type of the TAKER (the side that crossed the book).
    takerOrderType : ?OrderType;
  };

  // ── Settlement-window matching (Phase 1 of the AMM spec) ─────────
  public type PendingMatchStatus = { #pending; #finalized; #voided };

  public type PendingMatch = {
    id              : Nat;
    marketId        : MarketId;
    makerOrderId    : Nat;
    makerPrincipal  : Principal;
    takerPrincipal  : Principal;
    takerSide       : Side;       // the taker's side; maker is the opposite
    takerOrderType  : OrderType;
    price           : Nat;
    quantity        : Nat;
    // Tokens + amounts the taker/maker owe, already moved to the reserved ledger.
    takerDebitToken  : TokenId;
    takerDebitAmount : Nat;
    makerDebitToken  : TokenId;
    makerDebitAmount : Nat;
    createdAtNs : Int;
    expiryNs    : Int;
    status      : PendingMatchStatus;
  };

  public type MarketInfo = {
    id : MarketId;
    baseToken : TokenId;
    quoteToken : TokenId;
    lastPrice : Nat;
    // Rolling 24h volume in quote-token units.
    volume24h : Nat;
    // Rolling 24h absolute price change in quote-token units (SIGNED — can fall).
    priceChange24hAbs : Int;
    // Oracle/AMM reference price ("mark") in quote-per-base units. 0 if none yet.
    markPrice : Nat;
  };

  public type OrderBookLevel = {
    price : Nat;
    quantity : Nat;
    orderCount : Nat;
  };

  public type OrderBookSnapshot = {
    bids : [OrderBookLevel];
    asks : [OrderBookLevel];
    spread : Nat;   // bestAsk − bestBid, clamped to 0 (a book never rests crossed)
  };

  public type SwapMode = {
    #marketOrder : { maxSlippage : Nat };   // fraction at 10^8 (0.10 = 10_000_000)
    #limitOrder : { limitPrice : Nat };
  };

  public type SwapRequest = {
    fromToken : TokenId;
    toToken : TokenId;
    amount : Nat;
    mode : SwapMode;
    noPartialFill : Bool;
  };

  public type SwapResult = {
    fromAmount : Nat;
    toAmount : Nat;
    fullyFilled : Bool;
    swapOrderId : ?Nat;
  };

  // ── User profiles & history ───────────────────────────────────

  public type UserProfile = {
    userId   : Text;
    username : Text;
    regenCount : Nat;
    createdAt  : Int;
  };

  // WHY adjustUserOrders touched the order (#50 follow-up, task 1787199451) —
  // one tag per walk in LiquidityManager. The below-min escalation (a shrink
  // whose remainder would land under MIN_ORDER_ICPUSD becomes a whole cancel)
  // keeps its walk's reason: `cancelled` already records that the shrink
  // escalated; the reason records what TRIGGERED the walk.
  public type AdjustmentReason = {
    #balanceShrank;          // step-1 walk: the balance no longer covers the order
    #marketCapExceeded;      // step-2 walk: per-market MARKET_ASSET_FACTOR (2.5x) cap
    #crossMarketCapExceeded; // cross-market bid-cap walk (enforceCrossMarketBidCap)
  };

  public type OrderAdjustment = {
    orderId     : Nat;
    marketId    : MarketId;
    side        : Side;
    oldQuantity : Nat;
    newQuantity : Nat;  // 0 when cancelled
    cancelled   : Bool;
    timestamp   : Int;
    reason      : ?AdjustmentReason; // null: fossil row recorded before reasons existed
  };

  // FROZEN pre-reason shape — pins the fossil-parked stable map
  // `userAdjustments` (main.mo) at its deployed layout. That map lives inside
  // mutable containers (Map/List are invariant in their element type), so
  // adding `reason` in place is an EOP-incompatible change (IC0503 on
  // upgrade); and the actor's one-shot migration slot is occupied by the
  // ACTIVE W2-04 migration (see migration.mo's retirement note — its domain
  // refuses post-W2-04 state, so it cannot be extended to serve every live
  // target). New records go to `userAdjustmentsV2`; getMyAdjustments merges
  // fossil rows first with reason = null. A sweep can consolidate the fossil
  // into V2 in the one-shot slot AFTER W2-04 retires (task filed).
  public type OrderAdjustmentLegacy = {
    orderId     : Nat;
    marketId    : MarketId;
    side        : Side;
    oldQuantity : Nat;
    newQuantity : Nat;
    cancelled   : Bool;
    timestamp   : Int;
  };

  public type DepositRecord = {
    token     : TokenId;
    amount    : Nat;
    timestamp : Int;
    kind      : { #deposit; #withdrawal };
  };

  // ── Permanent user-history events (docs/archive-design.md) ──────
  public type UserEventKind = {
    #fill : { marketId : MarketId; side : Side; price : Nat; qty : Nat;
              orderId : Nat; tradeId : Nat };
    #deposit : DepositRecord;          // .kind distinguishes deposit/withdrawal
    #orderClosed : ClosedOrderRecord;
    #liquidation : LiquidationEvent;
    #borrow : { token : TokenId; amount : Nat };
    #repay  : { token : TokenId; amount : Nat };
    #lpDeposit  : { marketId : MarketId; baseAmount : Nat;
                    quoteAmount : Nat; lpMinted : Nat };
    #lpWithdraw : { lpBurned : Nat; basket : [(TokenId, Nat)] };
    #insuranceStake   : { amountUsd : Nat; shares : Nat };
    #insuranceUnstake : { shares : Nat; payoutUsd : Nat };
    // The ledger of record: one signed balance delta per Accounts mutation,
    // fed by the Accounts journal (see lib/Accounts.mo). `user` on these is
    // the RAW balance-bearing principal (pools/vault/treasury included — NO
    // owner remap): folding every #delta reproduces every account balance
    // exactly, which is what recovery-by-replay and Proof-of-Reserves
    // liabilities stand on. Machine records — the UI timeline skips them.
    #delta : { token : TokenId; amount : Int };
    // The three CLAIM ledgers, same discipline (shadow-diffed at each drain —
    // they're small maps, so an O(entries) diff per beat is free): pool debt
    // owed to the vault, vault LP shares, insurance-pool shares. Folding each
    // kind reproduces its ledger exactly, completing the recovery/PoR story
    // beyond token balances.
    #debtDelta     : { token : TokenId; amount : Int };
    #lpShareDelta  : { marketId : MarketId; amount : Int };
    #insShareDelta : { amount : Int };
    // W2-04: emitted INTO the fresh segment at the L2 shed point, so a
    // cross-archive re-anchor is justified by the chain itself (hash-
    // committed, certificate-covered) instead of by getLedgerGaps — an
    // uncertified self-report a hostile host can fabricate to suppress a
    // link check. Verifiers refuse re-anchors with no matching #gap event.
    // [fromSeq, toSeq) = the dropped, never-shipped range.
    #gap : { fromSeq : Nat; toSeq : Nat };
    // #47.4 (operator-ratified 2026-08-20): admin/config actions land on the
    // durable hash-chained tape, not only in the bounded transient ring log —
    // an NNS-run venue whose tape is the permanent principal-attributed
    // record should not keep "who rewired the oracle and when" only in a
    // ring. Emitted by exactly the six authority setters (setBridge,
    // setArbitrageur, setFuelRoute, setXrcCanister, setBlackholeAtSeal,
    // setAutoFuel) beside their §6n ring-log lines; `setter` = the method
    // name, `value` = the ring log's rendered value text (the two surfaces
    // stay trivially diffable). Narrow typed form by decision — a broad
    // #adminAction junk drawer was rejected on a permanent public schema.
    #config : { setter : Text; value : Text };
  };

  public type UserEvent = {
    seq  : Nat;            // global, dense, assigned at capture
    ts   : Int;            // capture time (canister clock)
    user : Principal;      // whose history this belongs to (indexed)
    counterparty : ?Principal;
    kind : UserEventKind;
    prevHash : ?Blob;      // tamper-evidence chain — null until Phase D
  };

  public type UserPreferences = {
    recentMarkets : [Text];
    lastMarket    : ?Text;
  };

  public type UserStatus = {
    version        : Nat;
    lastTradeTime  : Int;
    openOrderCount : Nat;
  };

  // Slim trade type for public market data.
  public type PublicTrade = {
    id        : Nat;
    price     : Nat;
    quantity  : Nat;
    timestamp : Int;
  };

  public type MarketStatus = {
    version     : Nat;  // bumped on any order book or trade mutation
    lastTradeId : Nat;  // newest trade id (0 if none)
  };

  public type LevelChange = {
    side       : Side;
    price      : Nat;
    quantity   : Nat;
    orderCount : Nat;
  };

  public type OrderBookDelta = {
    asks : [OrderBookLevel];
    bids : [OrderBookLevel];
  };

  public type MarketChangesRequest = {
    marketId          : ?MarketId;   // null = skip market data, poll user only
    lastMarketVersion : Nat;
    lastTradeId       : Nat;
    lastUserVersion   : Nat;
    lastUserTradeTime : Int;
  };

  public type MarketChangesResponse = {
    marketStatus   : ?MarketStatus;
    orderBook      : ?OrderBookSnapshot;
    orderBookDelta : ?OrderBookDelta;
    newTrades      : [PublicTrade];

    userStatus     : ?UserStatus;
    userOpenOrders : ?[Order];
    userBalances   : ?[(TokenId, Nat)];
    newUserTrades  : [Trade];
  };

  public type Candle = {
    time   : Int;     // bucket start in nanoseconds
    open   : Nat;
    high   : Nat;
    low    : Nat;
    close  : Nat;
    volume : Nat;
  };

  public type CandleResponse = {
    candles : [Candle];
    hasMore : Bool;
  };

  // Per-market open-order value cap = MARKET_ASSET_FACTOR × balance (2.5×).
  public let MARKET_ASSET_FACTOR : Nat = 250_000_000;   // 2.5
  // Minimum order notional. Below this an order is dust: its fee rounds to
  // ~nothing (free book/queue spam inside the per-owner staged cap) and it
  // clutters the ladder. EXEMPTION (enforced at the call sites): an order that
  // commits the caller's ENTIRE remaining funding balance is always allowed —
  // dust balances must never be stranded/unsellable.
  public let MIN_ORDER_ICPUSD : Nat = 1_000_000_000;    // 10.0 ICPUSD

  // Max open orders resting at ONE price on one market-side. A congestion
  // bound, not an economic one: every path that sweeps a level (a large
  // taker, the AMM sweep, liquidation sells, deferred-expiry releases) does
  // work proportional to the level's order count per message, so the count
  // must not be attacker-unbounded. 512 sits well under the ~3k same-price
  // orders measured to trap the 40B instruction limit pre-fix, and far above
  // organic congestion at magnet prices (the per-user open-order cap is 100).
  // REJECT-new, never evict: eviction would let a spammer displace honest
  // makers' queue positions, while rejection denies only this exact price —
  // one tick away is always free on the 10^-8 grid. Enforced at STAGING
  // (LiquidityManager.validateNewOrder), so a burst staged before any of it
  // rests can overshoot the cap by the in-flight staged cohort (bounded by
  // the global staged shed, ~2k); the engine's per-call iteration cap is what
  // makes any overshoot harmless.
  public let MAX_ORDERS_PER_PRICE_LEVEL : Nat = 512;

  // Combined cross-market bid exposure cap = CROSS_MARKET_BID_FACTOR × cash.
  public let CROSS_MARKET_BID_FACTOR : Nat = 300_000_000;   // 3.0

  // ── Margin: opt-in cross-margin accounts ───────────────────
  // Weighted collateral = Σ_t (balance_t × refPrice_t × LTV_t). Per-asset LTVs
  // (at 10^8): ICPUSD 1.0, BTC/ETH 0.90, SOL 0.85, ICP 0.80.
  // Raised 2026-07-08 (from 0.85/0.75/0.70): against the 1.25 opening-health
  // requirement the old weights pinned max short leverage at 2.5×/2.0×/1.8×
  // AT the mark — a SOL 2× short was knife-edge (any sub-mark limit or
  // slippage allowance blocked it) and an ICP 2× short was impossible. New
  // at-the-mark caps: shorts ~2.9×/2.5×/2.2×, longs ~3.6×/3.1×/2.8× — 2×
  // works comfortably everywhere, 3× is reachable on the majors.
  public func marginLTV(token : TokenId) : ?Nat {
    switch (token) {
      case ("ICPUSD") { ?100_000_000 }; // 1.00
      case ("BTC")    { ?90_000_000 };  // 0.90
      case ("ETH")    { ?90_000_000 };
      case ("SOL")    { ?85_000_000 };  // 0.85
      case ("ICP")    { ?80_000_000 };  // 0.80
      // DELIBERATE fail-closed (#49.6): an unknown/future token gets NO margin
      // LTV — it contributes ZERO collateral value — never a permissive
      // default. When expanding the token set, add an explicit arm above and
      // keep this wildcard null.
      case (_)        { null };
    };
  };

  public let MARGIN_COLLATERAL_TOKENS : [TokenId] = [
    "ICPUSD", "BTC", "ETH", "SOL", "ICP"
  ];

  public type MarginAccount = {
    openedAt : Int;
  };

  public type CollateralValuation = {
    token      : TokenId;
    balance    : Nat;          // user's current balance of this token
    refPrice   : Nat;          // 1.0 (10^8) for ICPUSD; oracle for others
    ltv        : Nat;          // per-asset haircut (at 10^8)
    contribUsd : Nat;          // = balance × refPrice × ltv
  };

  public type BidHeadroom = {
    cashBalance   : Nat;        // available cash (balance − reserved)
    totalBalance  : Nat;        // raw ICPUSD balance
    grossBidValue : Nat;
    maxAllowed    : Nat;        // bid cap = availableCash × CROSS_MARKET_BID_FACTOR
    headroom      : Int;        // maxAllowed − grossBidValue (SIGNED — can be over-cap)
    factor        : Nat;        // CROSS_MARKET_BID_FACTOR
    marginAccount : ?MarginAccount;
    collateralBreakdown : [CollateralValuation];
    collateralValueUsd  : Nat;  // total Σ contribUsd
  };

  // ── Margin Phase 2: borrowing against collateral ────────────
  // Interest is lazy + linear: principal × apr × elapsedNs / YEAR_NS.
  public let YEAR_NS : Nat = 31_536_000_000_000_000; // 365 days

  public func borrowApr(token : TokenId) : ?Nat {
    switch (token) {
      case ("ICPUSD") { ?5_000_000 };  // 0.05 (5%)
      case ("BTC")    { ?8_000_000 };  // 0.08 (8%)
      case ("ETH")    { ?8_000_000 };
      case ("SOL")    { ?10_000_000 }; // 0.10 (10%)
      case ("ICP")    { ?10_000_000 };
      case (_)        { null };
    };
  };

  public let VAULT_BORROW_FRACTION_CAP : Nat = 50_000_000;   // 0.50
  // Health ratio ladder (collateral_USD / debt_USD, at 10^8):
  public let MAINTENANCE_HEALTH_RATIO  : Nat = 115_000_000;  // 1.15 — liquidate below
  public let TARGET_HEALTH_RATIO       : Nat = 125_000_000;  // 1.25 — partial close restores to
  public let INITIAL_HEALTH_RATIO      : Nat = 125_000_000;  // 1.25 — required to open/increase risk
  public let LIQUIDATION_PENALTY       : Nat = 5_000_000;    // 0.05 — 5% of seized value → vault

  public type Loan = {
    token         : TokenId;
    principal     : Nat;         // current outstanding after last accrual
    lastAccrualNs : Int;         // timestamp of the last principal update
  };

  public type DebtEntry = {
    token         : TokenId;
    principal     : Nat;
    accruedToNs   : Int;
    apr           : Nat;         // at 10^8 — UI shows "borrowing at 8% APR"
    debtUsd       : Nat;         // principal × refPrice
  };

  public type MarginHealth = {
    collateralUsd          : Nat;  // Σ committed × refPrice × LTV
    debtUsd                : Nat;  // Σ loan.principal × refPrice
    equityUsd              : Int;  // collateralUsd − debtUsd (can go negative)
    healthRatio            : Nat;  // collateralUsd / debtUsd (at 10^8), HEALTHY_INF when debt==0
    maintenanceRatio       : Nat;  // surfaced constant for UI labelling
    isLiquidatable         : Bool; // healthRatio < maintenanceRatio
  };

  // Sentinel "infinite health" (debt == 0): a large 10^8-scaled ratio.
  public let HEALTHY_INF : Nat = 1_000_000_000_000_000_000;

  // ── Margin Phase 2B: liquidation events ──────────────────────
  public type LiquidationEvent = {
    user             : Principal;
    debtToken        : TokenId;       // token whose loan was repaid
    debtRepaid       : Nat;           // principal cleared (in debtToken units)
    debtRepaidUsd    : Nat;           // oracle valuation at the time of liquidation
    collateralToken  : TokenId;       // token seized
    collateralSeized : Nat;           // qty seized (in collateralToken units)
    proceedsUsd      : Nat;           // ICPUSD-value realised from the seize
    penaltyUsd       : Nat;           // 5% to vault
    healthBefore     : Nat;           // ratio before the pass (at 10^8)
    healthAfter      : Nat;           // ratio after the pass (at 10^8)
    timestamp        : Int;
  };

  public type LiquidationOutcome = {
    #liquidated  : LiquidationEvent;
    #healthy;
    #insolvent   : LiquidationEvent;
    #unsupported : Text;
    #err         : Text;
  };

  public let QUOTE_TOKEN : TokenId = "ICPUSD";
  public let MAX_USERNAME_REGENS : Nat = 5;
};
