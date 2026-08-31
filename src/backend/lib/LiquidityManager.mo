import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Types "Types";
import Fixed "Fixed";
import OrderBook "OrderBook";
import Accounts "Accounts";
import MarginEngine "MarginEngine";
import SafeMath "SafeMath";

module {

  // Callback shape — defined per-call by main.mo so we don't depend on
  // its private margin / reserved bookkeeping. Returns the spendable
  // balance for (user, token) after subtracting hard-locked collateral
  // and any pending-match reservations.
  public type AvailableBalance = (Principal, Types.TokenId) -> Nat;

  // Human text for a 10^8-scaled multiplier, up to 2 dp with trailing zeros
  // trimmed (250_000_000 → "2.5") — the raw base-unit constant is meaningless
  // in a user-facing message (#50.3). Display only; enforcement stays fixed-point.
  func factorText(f : Nat) : Text {
    let whole = f / Fixed.SCALE;
    let hundredths = (f % Fixed.SCALE) * 100 / Fixed.SCALE;
    if (hundredths == 0) { Nat.toText(whole) }
    else if (hundredths % 10 == 0) { Nat.toText(whole) # "." # Nat.toText(hundredths / 10) }
    else { Nat.toText(whole) # "." # (if (hundredths < 10) "0" else "") # Nat.toText(hundredths) };
  };

  // Per-level congestion cap (see Types.MAX_ORDERS_PER_PRICE_LEVEL): a price
  // already holding the max resting orders takes no more — REJECT-new, never
  // evict. The counter is the AGGREGATE across ALL owners resting at this
  // (marketId, side, price) level — it is NOT owner-scoped (per-owner budgets
  // are the open-order cap, a different guard). It IS side-scoped: only the
  // order's own side of the level counts, so a stacked opposite side never
  // blocks an order that would cross it. `levelCap` is
  // Types.MAX_ORDERS_PER_PRICE_LEVEL everywhere except main.mo's margin-path
  // call sites, which may pass a dev-hook override (setTestLevelCap) so tests
  // can fill a level without 512 placements. Internal placements (AMM ladder,
  // deferred releases resting a remainder) do not route through this check
  // and are exempt by construction.
  public func levelCapCheck(
    store    : OrderBook.OrderStore,
    marketId : Types.MarketId,
    side     : Types.Side,
    price    : Nat,
    levelCap : Nat,
  ) : ?Text {
    if (OrderBook.getLevelOrderCount(store, marketId, side, price) >= levelCap) {
      ?("Price level full: " # Nat.toText(levelCap) #
        " orders already rest at this exact price on this side. Choose a different price.")
    } else { null };
  };

  public func validateNewOrder(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    margin : MarginEngine.MarginState,
    priceLookup : MarginEngine.PriceLookup,
    availableBalance : AvailableBalance,
    user : Principal,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    side : Types.Side,
    price : Nat,
    quantity : Nat,
  ) : { #ok; #err : Text } {
    // Per-level congestion cap — see levelCapCheck above for the semantics
    // (aggregate across owners, side-scoped). Checked FIRST: a full level
    // rejects regardless of balances.
    switch (levelCapCheck(store, marketId, side, price, Types.MAX_ORDERS_PER_PRICE_LEVEL)) {
      case (?e) { return #err(e) };
      case null {};
    };
    switch (side) {
      case (#buy) {
        let orderValue = Fixed.mul(quantity, price, true);
        // Individual fillability uses AVAILABLE cash — committed margin
        // collateral is hard-locked and can't back a new bid. The other
        // two caps (per-market 2.5×, cross-market bid factor) keep
        // using raw balance so committing to collateral doesn't shrink
        // your overall capacity; only the spendable slice tightens.
        let icpusdAvailable = availableBalance(user, Types.QUOTE_TOKEN);
        let icpusdBalance   = Accounts.getBalance(accounts, user, Types.QUOTE_TOKEN);

        if (orderValue > icpusdAvailable) {
          let locked : Nat = icpusdBalance - icpusdAvailable;
          let suffix = if (locked > 0) {
            " (locked as margin collateral: " # Nat.toText(locked) # ")"
          } else { "" };
          return #err(
            "Insufficient free ICPUSD. Need " # Nat.toText(orderValue) #
            " but only " # Nat.toText(icpusdAvailable) # " is spendable" # suffix
          );
        };
        // Minimum notional — EXEMPT when the order commits the caller's entire
        // spendable quote balance (spend-all): dust cash must never be stranded.
        // (orderValue ≤ icpusdAvailable is guaranteed by the check above, so
        // "not below available" here means EQUALS it.)
        if (orderValue < Types.MIN_ORDER_ICPUSD and orderValue < icpusdAvailable) {
          return #err("Order value below the " # Nat.toText(Types.MIN_ORDER_ICPUSD) # " base-unit minimum (10 ICPUSD); orders spending your entire remaining balance are exempt");
        };

        let currentTotal = OrderBook.getUserMarketBuyTotal(store, user, marketId);
        let maxAllowed = Fixed.mul(icpusdBalance, Types.MARKET_ASSET_FACTOR, false);
        if (currentTotal + orderValue > maxAllowed) {
          return #err("Total buy orders on this market would exceed " # factorText(Types.MARKET_ASSET_FACTOR) # "x your ICPUSD balance");
        };

        // ── Cross-market soft cap on bids (Phase 0 soft-leverage limit) ──
        // Sum of (price × remaining) across all open buy orders in every
        // market must stay within available cash × CROSS_MARKET_BID_FACTOR.
        // Same formula for everyone now — real leverage comes from
        // borrowing (which raises available cash via MarginEngine /
        // BorrowEngine), not from a margin-specific bid-cap bonus.
        let currentGross = OrderBook.getUserGrossBuyValue(store, user);
        let maxGrossAllowed = MarginEngine.bidCapFor(margin, accounts, availableBalance, user, priceLookup);
        if (currentGross + orderValue > maxGrossAllowed) {
          let hasMargin = switch (MarginEngine.get(margin, user)) {
            case (?_) { true }; case null { false };
          };
          let suffix = if (hasMargin) {
            " (post more margin collateral to lift the cap)"
          } else {
            " (open a margin account and post collateral to lift the cap)"
          };
          return #err(
            "Combined buy orders across all markets would exceed your cap " #
            "(current gross " # Nat.toText(currentGross) # ", cap " #
            Nat.toText(maxGrossAllowed) # ")" # suffix
          );
        };

        #ok;
      };
      case (#sell) {
        let assetAvailable = availableBalance(user, baseToken);
        let assetBalance   = Accounts.getBalance(accounts, user, baseToken);

        if (quantity > assetAvailable) {
          let locked : Nat = assetBalance - assetAvailable;
          let suffix = if (locked > 0) {
            " (locked as margin collateral: " # Nat.toText(locked) # ")"
          } else { "" };
          return #err(
            "Insufficient free " # baseToken # ". Need " # Nat.toText(quantity) #
            " but only " # Nat.toText(assetAvailable) # " is spendable" # suffix
          );
        };
        // Minimum notional — EXEMPT when the order sells the caller's entire
        // spendable holding of the base token (dusting out a small balance).
        if (Fixed.mul(quantity, price, true) < Types.MIN_ORDER_ICPUSD and quantity < assetAvailable) {
          return #err("Order value below the " # Nat.toText(Types.MIN_ORDER_ICPUSD) # " base-unit minimum (10 ICPUSD); selling your entire remaining balance is exempt");
        };

        let currentTotal = OrderBook.getUserMarketSellTotal(store, user, marketId);
        let maxAllowed = Fixed.mul(assetBalance, Types.MARKET_ASSET_FACTOR, false);
        if (currentTotal + quantity > maxAllowed) {
          return #err("Total sell orders on this market would exceed " # factorText(Types.MARKET_ASSET_FACTOR) # "x your " # baseToken # " balance");
        };

        #ok;
      };
    };
  };

  // Adjust all open orders for a user across all markets after their balance changes.
  // Returns a list of every adjustment/cancellation made (for history recording).
  public func adjustUserOrders(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    margin : MarginEngine.MarginState,
    priceLookup : MarginEngine.PriceLookup,
    availableBalance : AvailableBalance,
    user : Principal,
    markets : [(Types.MarketId, Types.TokenId)],
    timestamp : Int,
  ) : [Types.OrderAdjustment] {
    let adjList = List.empty<Types.OrderAdjustment>();
    let icpusdBalance = Accounts.getBalance(accounts, user, Types.QUOTE_TOKEN);
    for ((marketId, baseToken) in markets.vals()) {
      adjustBuyOrders(store, user, marketId, icpusdBalance, timestamp, adjList);
      adjustSellOrders(store, accounts, user, marketId, baseToken, timestamp, adjList);
    };
    // ── Cross-market bid cap enforcement (Phase 0 + Phase 1 margin) ──
    // After per-market shrinks, total gross-buy may still exceed the
    // effective cap (e.g. cash just halved → each market's per-market
    // check passed independently but the combined exposure is still
    // oversized). Walk cross-market newest-first, shrinking/cancelling
    // until gross ≤ cap. The cap consults MarginManager so margin users
    // get the headroom their collateral buys them.
    let maxGross = MarginEngine.bidCapFor(margin, accounts, availableBalance, user, priceLookup);
    enforceCrossMarketBidCap(store, user, maxGross, timestamp, adjList);
    Iter.toArray(List.values(adjList))
  };

  // ── Cross-market bid cap enforcement ───────────────────────────
  // Called after per-market adjustments. If the user's gross buy value
  // still exceeds `maxGross`, shrink or cancel their open buy orders
  // newest-first until it's back under. The cap is supplied by the
  // caller so this stays cheap (no map lookup in the tight loop).
  func enforceCrossMarketBidCap(
    store     : OrderBook.OrderStore,
    user      : Principal,
    maxGross  : Nat,
    timestamp : Int,
    adjList   : List.List<Types.OrderAdjustment>,
  ) {
    let gross = OrderBook.getUserGrossBuyValue(store, user);
    if (gross <= maxGross) { return };

    // Collect all open buy orders for this user, across all markets,
    // newest-first (highest id first).
    let openOrders = OrderBook.getUserOpenOrders(store, user);
    let buys = List.empty<Types.Order>();
    for (o in openOrders.vals()) {
      switch (o.side) {
        case (#buy)  { if (OrderBook.isOpen(o)) { List.add(buys, o) } };
        case (#sell) {};
      };
    };
    let buyArr = Iter.toArray(List.values(buys));
    // Sort newest-first (descending order id)
    let sorted = Array.sort<Types.Order>(buyArr, func(a, b) {
      if (a.id > b.id) { #less } else if (a.id < b.id) { #greater } else { #equal }
    });

    var excess : Nat = gross - maxGross;
    var i : Nat = 0;
    let n = sorted.size();
    while (i < n and excess > 0) {
      let o = sorted[i];
      // Re-read the live order — earlier per-market work may have
      // already shrunk/cancelled it.
      switch (OrderBook.getOrder(store, o.id)) {
        case null {};
        case (?live) {
          if (OrderBook.isOpen(live)) {
            let rem = OrderBook.remaining(live);
            let orderValue = Fixed.mul(rem, live.price, true);
            if (orderValue <= excess) {
              // Cancel this order entirely
              recordCancel(adjList, live, timestamp, #crossMarketCapExceeded);
              ignore OrderBook.cancelOrder(store, live.id);
              excess -= orderValue;
            } else {
              // Shrink by exactly `excess` worth
              let reduceQty = Fixed.div(excess, live.price, true);
              let newQty : Nat = live.quantity - reduceQty;
              let newRem : Nat = newQty - live.filled;
              if (Fixed.mul(newRem, live.price, true) < Types.MIN_ORDER_ICPUSD) {
                recordCancel(adjList, live, timestamp, #crossMarketCapExceeded);
                ignore OrderBook.cancelOrder(store, live.id);
                // orderValue > excess in this branch, so the cancel clears the
                // whole overage (`-=` here is a guaranteed underflow trap).
                excess := 0;
              } else {
                recordAdjust(adjList, live, newQty, timestamp, #crossMarketCapExceeded);
                ignore OrderBook.adjustOrderQuantity(store, live.id, newQty);
                excess := 0;
              };
            };
          };
        };
      };
      i += 1;
    };
  };

  // ── Helpers: fetch open order IDs via indexed lookup ────────────
  func getOpenBuyOrderIds(store : OrderBook.OrderStore, user : Principal, marketId : Types.MarketId) : [Nat] {
    OrderBook.getOpenOrderIdsForUserMarketSide(store, user, marketId, #buy);
  };

  func getOpenSellOrderIds(store : OrderBook.OrderStore, user : Principal, marketId : Types.MarketId) : [Nat] {
    OrderBook.getOpenOrderIdsForUserMarketSide(store, user, marketId, #sell);
  };

  // ── Record helpers ──────────────────────────────────────────────
  // `reason` names the WALK that touched the order (the trigger), threaded
  // from every call site: #balanceShrank for the step-1 balance walks,
  // #marketCapExceeded for the step-2 per-market cap walks,
  // #crossMarketCapExceeded for enforceCrossMarketBidCap. A below-min
  // escalation (shrink → whole cancel) keeps its walk's reason — `cancelled`
  // records the escalation itself.
  func recordCancel(adjList : List.List<Types.OrderAdjustment>, o : Types.Order, timestamp : Int, reason : Types.AdjustmentReason) {
    List.add(adjList, {
      orderId     = o.id;
      marketId    = o.marketId;
      side        = o.side;
      oldQuantity = OrderBook.remaining(o);
      newQuantity = 0;
      cancelled   = true;
      timestamp;
      reason      = ?reason;
    });
  };

  func recordAdjust(adjList : List.List<Types.OrderAdjustment>, o : Types.Order, newQty : Nat, timestamp : Int, reason : Types.AdjustmentReason) {
    let newRem = SafeMath.subOrZero(newQty, o.filled);
    List.add(adjList, {
      orderId     = o.id;
      marketId    = o.marketId;
      side        = o.side;
      oldQuantity = OrderBook.remaining(o);
      newQuantity = newRem;
      cancelled   = false;
      timestamp;
      reason      = ?reason;
    });
  };

  // ── Buy-side adjustment ─────────────────────────────────────────
  func adjustBuyOrders(
    store     : OrderBook.OrderStore,
    user      : Principal,
    marketId  : Types.MarketId,
    icpusdBalance : Nat,
    timestamp : Int,
    adjList   : List.List<Types.OrderAdjustment>,
  ) {
    // Step 1: Individual order check
    let ids = getOpenBuyOrderIds(store, user, marketId);
    for (id in ids.vals()) {
      switch (OrderBook.getOrder(store, id)) {
        case null {};
        case (?o) {
          if (OrderBook.isOpen(o)) {
            let rem = OrderBook.remaining(o);
            let orderValue = Fixed.mul(rem, o.price, true);
            if (orderValue > icpusdBalance) {
              if (icpusdBalance < Types.MIN_ORDER_ICPUSD) {
                recordCancel(adjList, o, timestamp, #balanceShrank);
                ignore OrderBook.cancelOrder(store, id);
              } else {
                let newQty = o.filled + Fixed.div(icpusdBalance, o.price, false);
                let newRem : Nat = newQty - o.filled;
                if (Fixed.mul(newRem, o.price, true) < Types.MIN_ORDER_ICPUSD) {
                  recordCancel(adjList, o, timestamp, #balanceShrank);
                  ignore OrderBook.cancelOrder(store, id);
                } else {
                  recordAdjust(adjList, o, newQty, timestamp, #balanceShrank);
                  ignore OrderBook.adjustOrderQuantity(store, id, newQty);
                };
              };
            };
          };
        };
      };
    };

    // Step 2: Per-market total constraint — re-fetch fresh state
    let totalBuy = OrderBook.getUserMarketBuyTotal(store, user, marketId);
    let maxAllowed = Fixed.mul(icpusdBalance, Types.MARKET_ASSET_FACTOR, false);

    if (totalBuy > maxAllowed) {
      let freshIds = getOpenBuyOrderIds(store, user, marketId);
      var excess : Nat = totalBuy - maxAllowed;
      var i : Int = freshIds.size() - 1;
      while (i >= 0 and excess > 0) {
        let id = freshIds[Int.abs(i)];
        switch (OrderBook.getOrder(store, id)) {
          case null {};
          case (?o) {
            if (OrderBook.isOpen(o)) {
              let rem = OrderBook.remaining(o);
              let orderValue = Fixed.mul(rem, o.price, true);
              if (orderValue <= excess) {
                recordCancel(adjList, o, timestamp, #marketCapExceeded);
                ignore OrderBook.cancelOrder(store, id);
                excess -= orderValue;
              } else {
                let reduceQty = Fixed.div(excess, o.price, true);
                let newQty : Nat = o.quantity - reduceQty;
                let newRem : Nat = newQty - o.filled;
                if (Fixed.mul(newRem, o.price, true) < Types.MIN_ORDER_ICPUSD) {
                  recordCancel(adjList, o, timestamp, #marketCapExceeded);
                  ignore OrderBook.cancelOrder(store, id);
                  // orderValue > excess in this branch — cancel clears the overage.
                  excess := 0;
                } else {
                  recordAdjust(adjList, o, newQty, timestamp, #marketCapExceeded);
                  ignore OrderBook.adjustOrderQuantity(store, id, newQty);
                  excess := 0;
                };
              };
            };
          };
        };
        i -= 1;
      };
    };
  };

  // ── Sell-side adjustment ────────────────────────────────────────
  func adjustSellOrders(
    store     : OrderBook.OrderStore,
    accounts  : Accounts.AccountState,
    user      : Principal,
    marketId  : Types.MarketId,
    baseToken : Types.TokenId,
    timestamp : Int,
    adjList   : List.List<Types.OrderAdjustment>,
  ) {
    let assetBalance = Accounts.getBalance(accounts, user, baseToken);

    // Step 1: Individual order check
    let ids = getOpenSellOrderIds(store, user, marketId);
    for (id in ids.vals()) {
      switch (OrderBook.getOrder(store, id)) {
        case null {};
        case (?o) {
          if (OrderBook.isOpen(o)) {
            let rem = OrderBook.remaining(o);
            if (rem > assetBalance) {
              let newRem = assetBalance;
              if (Fixed.mul(newRem, o.price, true) < Types.MIN_ORDER_ICPUSD) {
                recordCancel(adjList, o, timestamp, #balanceShrank);
                ignore OrderBook.cancelOrder(store, id);
              } else {
                let newQty = o.filled + newRem;
                recordAdjust(adjList, o, newQty, timestamp, #balanceShrank);
                ignore OrderBook.adjustOrderQuantity(store, id, newQty);
              };
            };
          };
        };
      };
    };

    // Step 2: Per-market total constraint
    let totalSell = OrderBook.getUserMarketSellTotal(store, user, marketId);
    let maxAllowed = Fixed.mul(assetBalance, Types.MARKET_ASSET_FACTOR, false);

    if (totalSell > maxAllowed) {
      let freshIds = getOpenSellOrderIds(store, user, marketId);
      var excess : Nat = totalSell - maxAllowed;
      var i : Int = freshIds.size() - 1;
      while (i >= 0 and excess > 0) {
        let id = freshIds[Int.abs(i)];
        switch (OrderBook.getOrder(store, id)) {
          case null {};
          case (?o) {
            if (OrderBook.isOpen(o)) {
              let rem = OrderBook.remaining(o);
              if (rem <= excess) {
                recordCancel(adjList, o, timestamp, #marketCapExceeded);
                ignore OrderBook.cancelOrder(store, id);
                excess -= rem;
              } else {
                let newQty : Nat = o.quantity - excess;
                let newRem : Nat = newQty - o.filled;
                if (Fixed.mul(newRem, o.price, true) < Types.MIN_ORDER_ICPUSD) {
                  recordCancel(adjList, o, timestamp, #marketCapExceeded);
                  ignore OrderBook.cancelOrder(store, id);
                  // rem > excess in this branch — cancel clears the overage.
                  excess := 0;
                } else {
                  recordAdjust(adjList, o, newQty, timestamp, #marketCapExceeded);
                  ignore OrderBook.adjustOrderQuantity(store, id, newQty);
                  excess := 0;
                };
              };
            };
          };
        };
        i -= 1;
      };
    };
  };
};
