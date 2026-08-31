import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Fixed "Fixed";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Option "mo:core/Option";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Types "Types";
import SafeMath "SafeMath";

module {

  public type OrderStore = {
    orders : Map.Map<Nat, Types.Order>;
    var nextOrderId : Nat;
    var nextTradeId : Nat;
    trades : List.List<Types.Trade>;
    // ── Secondary indexes ──────────────────────────────────────────
    openOrdersByMarketSide : Map.Map<Text, Map.Map<Nat, Bool>>;  // "MARKET:side" → {orderId}
    // Price-ordered level index per market-side: "MARKET:side" → (price →
    // {(timestamp, orderId)}). mo:core Map is a sorted tree, so the touch is
    // the min (asks) / max (bids) key — giving O(log N) best-price lookup
    // instead of an O(N) linear scan over every resting order (the bottleneck
    // that let a growing book peg the canister). Maintained alongside
    // openOrdersByMarketSide in add/removeFromOpenIndexes.
    //
    // The INNER set is keyed by (timestamp, id) — the book's time-priority
    // order — so the level's FIRST entry IS its priority head and
    // findBestMatchExcluding reads it in O(log K) instead of walking all K
    // same-price orders per call. That walk made a taker sweeping a level
    // O(K²), which is what let ~3k orders stacked at ONE price trap the
    // 40B-instruction limit (the measured processDeferredExpiry wedge).
    // Keying by id alone can't replace it: a staged order rests under a
    // FRESH id at release but keeps its SUBMISSION timestamp, so id order
    // and time-priority order genuinely diverge within a level.
    levelsByMarketSide     : Map.Map<Text, Map.Map<Nat, Map.Map<(Int, Nat), Bool>>>;
    tradesByMarket         : Map.Map<Text, List.List<Types.Trade>>;
    openOrdersByUser       : Map.Map<Text, Map.Map<Nat, Bool>>;  // principal text → {orderId}
    // Aggregated depth per market-side: "MARKET:side" → (price → (remaining
    // qty, order count)). Maintained incrementally at every order transition
    // (add/cancel/fill/adjust), so snapshots and level-change log entries read
    // it in O(log N) instead of re-walking every open order — the walk made
    // each mutation O(side) and pegged the canister once books grew past a
    // few thousand resting orders.
    levelAggByMarketSide   : Map.Map<Text, Map.Map<Nat, (Nat, Nat)>>;
    // Per-user running exposure totals, same discipline: order-placement
    // validation reads these in O(log N) instead of walking the caller's
    // whole open-order set. Values are exact — every delta is computed with
    // the same Fixed.mul(remaining, price, true) the old walk used, so the
    // running total always equals what a fresh walk would return.
    userGrossBuyValue      : Map.Map<Text, Nat>;   // userKey → Σ open-buy value (all markets)
    userMarketBuyValue     : Map.Map<Text, Nat>;   // userKey|marketId → Σ open-buy value
    userMarketSellQty      : Map.Map<Text, Nat>;   // userKey|marketId → Σ open-sell qty
    // ── Candle cache: "MARKET:intervalMs" → (bucketTimestampNs → Candle) ──
    candleCache            : Map.Map<Text, Map.Map<Int, Types.Candle>>;
    // ── Market version counters: marketId → monotonic counter ─────
    marketVersionCounters  : Map.Map<Text, Nat>;
    // ── Price level change log: marketId → (version → LevelChange) ─
    levelChangeLog         : Map.Map<Text, Map.Map<Nat, Types.LevelChange>>;
  };

  // Standard candle intervals in ms, with retention in nanoseconds.
  //
  // EVERY interval is bounded. Four of them (15m, 4h, 1D, 1W) used to carry
  // retention 0 — the "prune nothing" sentinel — so their maps grew forever:
  // one entry per bucket per market, for the life of the canister. The 15m
  // series alone adds ~35,000 candles per market per year, and the cost scales
  // with however many markets the venue ever lists. Nothing reclaimed them,
  // and the growth is in the upgrade-carried heap.
  //
  // The three bounded intervals already agreed on a figure: 120h/1m, 600h/5m
  // and 300d/1h are each EXACTLY 7,200 candles. So the four unbounded ones get
  // the same budget rather than a newly invented one — retention is
  // 7,200 × the interval, which caps every series at ~7,200 entries per market
  // by construction. A chart window is 200-500 candles, so that is still
  // 14-36 screens of history on any interval.
  //
  // 0 remains meaningful as "never prune" for anything that wants it; no
  // interval uses it now.
  public let CANDLE_INTERVALS : [(Nat, Int)] = [
    (60000,     432_000_000_000_000),            // 1m  → 120h   (7200 × 1m)
    (300000,    2_160_000_000_000_000),          // 5m  → 600h   (7200 × 5m)
    (900000,    6_480_000_000_000_000),          // 15m → 75d    (7200 × 15m)
    (3600000,   25_920_000_000_000_000),         // 1h  → 300d   (7200 × 1h)
    (14400000,  103_680_000_000_000_000),        // 4h  → 1200d  (7200 × 4h)
    (86400000,  622_080_000_000_000_000),        // 1D  → 7200d  (7200 × 1D, ~19.7y)
    (604800000, 4_354_560_000_000_000_000),      // 1W  → 7200w  (7200 × 1W, ~138y)
  ];

  public func emptyStore() : OrderStore {
    {
      orders = Map.empty<Nat, Types.Order>();
      var nextOrderId = 1;
      var nextTradeId = 1;
      trades = List.empty<Types.Trade>();
      openOrdersByMarketSide = Map.empty<Text, Map.Map<Nat, Bool>>();
      levelsByMarketSide     = Map.empty<Text, Map.Map<Nat, Map.Map<(Int, Nat), Bool>>>();
      tradesByMarket         = Map.empty<Text, List.List<Types.Trade>>();
      openOrdersByUser       = Map.empty<Text, Map.Map<Nat, Bool>>();
      levelAggByMarketSide   = Map.empty<Text, Map.Map<Nat, (Nat, Nat)>>();
      userGrossBuyValue      = Map.empty<Text, Nat>();
      userMarketBuyValue     = Map.empty<Text, Nat>();
      userMarketSellQty      = Map.empty<Text, Nat>();
      candleCache            = Map.empty<Text, Map.Map<Int, Types.Candle>>();
      marketVersionCounters  = Map.empty<Text, Nat>();
      levelChangeLog         = Map.empty<Text, Map.Map<Nat, Types.LevelChange>>();
    };
  };

  public let LEVEL_LOG_MAX_SIZE : Nat = 500;

  // ── Index key helpers ──────────────────────────────────────────

  public func marketSideKey(marketId : Types.MarketId, side : Types.Side) : Text {
    marketId # ":" # (switch (side) { case (#buy) { "buy" }; case (#sell) { "sell" } });
  };

  func userMarketKey(user : Principal, marketId : Types.MarketId) : Text {
    Principal.toText(user) # "|" # marketId;
  };

  // Time-priority order for a level's inner set: earliest submission
  // timestamp first, id as the tie-break (ids are unique, so keys are too).
  // This is EXACTLY the priority findBestMatchExcluding used to compute by
  // walking the whole level — encoded in the key so the head is O(log K).
  // Public: the upgrade migration rebuilds level maps with it.
  public func levelKeyCompare(a : (Int, Nat), b : (Int, Nat)) : Order.Order {
    switch (Int.compare(a.0, b.0)) {
      case (#equal) { Nat.compare(a.1, b.1) };
      case (other)  { other };
    };
  };

  // ── Incremental aggregate maintenance ──────────────────────────
  // All order state transitions flow through createOrder / cancelOrder /
  // fillOrder / adjustOrderQuantity, and open-set membership through
  // addToOpenIndexes / removeFromOpenIndexes — the aggregates below are
  // updated ONLY at those choke points. The clamp-at-zero is defensive
  // (an underflow would mean a hook was missed); adminVerifyBookAggregates
  // walks the raw orders and diffs, so drift is detectable, not silent.

  func bumpNatBy(m : Map.Map<Text, Nat>, key : Text, delta : Int) {
    let next : Int = Option.get(Map.get(m, Text.compare, key), 0) + delta;
    if (next > 0) { Map.add(m, Text.compare, key, Int.abs(next)) }
    else { ignore Map.delete(m, Text.compare, key) };
  };

  func bumpLevelAgg(store : OrderStore, msKey : Text, price : Nat, qtyDelta : Int, cntDelta : Int) {
    let lvls = switch (Map.get(store.levelAggByMarketSide, Text.compare, msKey)) {
      case null {
        let m = Map.empty<Nat, (Nat, Nat)>();
        Map.add(store.levelAggByMarketSide, Text.compare, msKey, m);
        m;
      };
      case (?m) { m };
    };
    let (q, c) = Option.get(Map.get(lvls, Nat.compare, price), (0, 0));
    let nq : Int = q + qtyDelta;
    let nc : Int = c + cntDelta;
    let newQty = if (nq > 0) { Int.abs(nq) } else { 0 };
    let newCnt = if (nc > 0) { Int.abs(nc) } else { 0 };
    // Keep the entry while orders rest at the price (a zombie level can be
    // qty-0 with count>0, matching what a fresh walk of open orders reports).
    if (newCnt == 0 and newQty == 0) { ignore Map.delete(lvls, Nat.compare, price) }
    else { Map.add(lvls, Nat.compare, price, (newQty, newCnt)) };
  };

  // Add/remove one open order's contribution to the per-user exposure
  // totals. `sign` is +1 (entering the book / post-mutation state) or −1
  // (leaving the book / pre-mutation state). A partial fill or quantity
  // adjustment applies −1 on the old record then +1 on the new one, so the
  // stored total is always Σ over open orders of the exact per-order value.
  func applyUserExposure(store : OrderStore, o : Types.Order, sign : Int) {
    let uk = Principal.toText(o.owner);
    switch (o.side) {
      case (#buy) {
        let v : Int = Fixed.mul(remaining(o), o.price, true);
        bumpNatBy(store.userGrossBuyValue, uk, v * sign);
        bumpNatBy(store.userMarketBuyValue, userMarketKey(o.owner, o.marketId), v * sign);
      };
      case (#sell) {
        bumpNatBy(store.userMarketSellQty, userMarketKey(o.owner, o.marketId), (remaining(o) : Int) * sign);
      };
    };
  };

  func addToOpenIndexes(store : OrderStore, order : Types.Order) {
    // Market-side index
    let msKey = marketSideKey(order.marketId, order.side);
    let msSet = switch (Map.get(store.openOrdersByMarketSide, Text.compare, msKey)) {
      case null { Map.empty<Nat, Bool>() };
      case (?s) { s };
    };
    Map.add(msSet, Nat.compare, order.id, true);
    Map.add(store.openOrdersByMarketSide, Text.compare, msKey, msSet);

    // Price-level index (ordered by price → O(log N) best-price lookup;
    // inner set ordered by (timestamp, id) → O(log K) time-priority head).
    let lvls = switch (Map.get(store.levelsByMarketSide, Text.compare, msKey)) {
      case null { Map.empty<Nat, Map.Map<(Int, Nat), Bool>>() };
      case (?m) { m };
    };
    let lvl = switch (Map.get(lvls, Nat.compare, order.price)) {
      case null { Map.empty<(Int, Nat), Bool>() };
      case (?s) { s };
    };
    Map.add(lvl, levelKeyCompare, (order.timestamp, order.id), true);
    Map.add(lvls, Nat.compare, order.price, lvl);
    Map.add(store.levelsByMarketSide, Text.compare, msKey, lvls);

    // User index
    let userKey = Principal.toText(order.owner);
    let uSet = switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null { Map.empty<Nat, Bool>() };
      case (?s) { s };
    };
    Map.add(uSet, Nat.compare, order.id, true);
    Map.add(store.openOrdersByUser, Text.compare, userKey, uSet);

    // Aggregates: the order's remaining quantity joins its price level and
    // the owner's exposure totals.
    bumpLevelAgg(store, msKey, order.price, remaining(order), 1);
    applyUserExposure(store, order, 1);
  };

  func removeFromOpenIndexes(store : OrderStore, order : Types.Order) {
    // Market-side index
    let msKey = marketSideKey(order.marketId, order.side);
    switch (Map.get(store.openOrdersByMarketSide, Text.compare, msKey)) {
      case null {};
      case (?s) {
        ignore Map.delete(s, Nat.compare, order.id);
        Map.add(store.openOrdersByMarketSide, Text.compare, msKey, s);
      };
    };

    // Price-level index — remove the entry and prune the level if now empty
    // (so minEntry/maxEntry never land on an empty price). The key is
    // reconstructible because timestamp and id are immutable for the life of
    // an order (fills/adjusts touch quantity and status only), and callers
    // pass the pre-mutation record.
    switch (Map.get(store.levelsByMarketSide, Text.compare, msKey)) {
      case null {};
      case (?lvls) {
        switch (Map.get(lvls, Nat.compare, order.price)) {
          case null {};
          case (?lvl) {
            ignore Map.delete(lvl, levelKeyCompare, (order.timestamp, order.id));
            if (Map.size(lvl) == 0) {
              ignore Map.delete(lvls, Nat.compare, order.price);
            } else {
              Map.add(lvls, Nat.compare, order.price, lvl);
            };
            Map.add(store.levelsByMarketSide, Text.compare, msKey, lvls);
          };
        };
      };
    };

    // User index — remove the id and prune the OUTER entry once the user's
    // last open order leaves, exactly as the price-level index does above.
    // Without the prune the map keeps an (empty) entry for every principal
    // that has EVER placed an order, for the life of the canister: unbounded
    // growth in the upgrade-carried heap, and an ever-longer full-map walk
    // for main.mo's sweepStaleUserOrders and tickTier, which both iterate it
    // whole. Nothing reads an empty entry — every accessor here reports the
    // same 0/[] for "absent" and "present but empty", and rebuildIndexes
    // already reconstructs the map without them.
    let userKey = Principal.toText(order.owner);
    switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null {};
      case (?s) {
        ignore Map.delete(s, Nat.compare, order.id);
        if (Map.size(s) == 0) {
          ignore Map.delete(store.openOrdersByUser, Text.compare, userKey);
        } else {
          Map.add(store.openOrdersByUser, Text.compare, userKey, s);
        };
      };
    };

    // Aggregates: callers pass the PRE-mutation record, so remaining(order)
    // is exactly the contribution this order still holds in the aggregates.
    bumpLevelAgg(store, msKey, order.price, -(remaining(order) : Int), -1);
    applyUserExposure(store, order, -1);
  };

  // Rebuild all secondary indexes from master data (run once after upgrade)
  public func rebuildIndexes(store : OrderStore) {
    // Clear indexes
    Map.clear(store.openOrdersByMarketSide);
    Map.clear(store.levelsByMarketSide);
    Map.clear(store.openOrdersByUser);
    Map.clear(store.tradesByMarket);
    Map.clear(store.levelAggByMarketSide);
    Map.clear(store.userGrossBuyValue);
    Map.clear(store.userMarketBuyValue);
    Map.clear(store.userMarketSellQty);

    // Rebuild open-order indexes
    for ((_, o) in Map.entries(store.orders)) {
      if (isOpen(o)) { addToOpenIndexes(store, o) };
    };

    // Rebuild per-market trade lists (candle cache is persistent, skip if populated)
    for (t in List.values(store.trades)) {
      let mList = switch (Map.get(store.tradesByMarket, Text.compare, t.marketId)) {
        case null { List.empty<Types.Trade>() };
        case (?l) { l };
      };
      List.add(mList, t);
      Map.add(store.tradesByMarket, Text.compare, t.marketId, mList);
    };
  };

  // Rebuild ONLY the price-level index from master data. O(open orders × log)
  // — bounded by the resting book, never by the trade tape, so unlike the full
  // rebuildIndexes it is safe inside an upgrade. Built as the worker for the
  // retired one-shot (timestamp, id) re-key migration (applied to every
  // target 2026-08-07); kept because the unit suite pins its reconstruction
  // and any future level-map migration will need exactly this.
  public func rebuildLevelIndex(store : OrderStore) {
    Map.clear(store.levelsByMarketSide);
    for ((_, o) in Map.entries(store.orders)) {
      if (isOpen(o)) {
        let msKey = marketSideKey(o.marketId, o.side);
        let lvls = switch (Map.get(store.levelsByMarketSide, Text.compare, msKey)) {
          case null {
            let m = Map.empty<Nat, Map.Map<(Int, Nat), Bool>>();
            Map.add(store.levelsByMarketSide, Text.compare, msKey, m);
            m;
          };
          case (?m) { m };
        };
        let lvl = switch (Map.get(lvls, Nat.compare, o.price)) {
          case null {
            let s = Map.empty<(Int, Nat), Bool>();
            Map.add(lvls, Nat.compare, o.price, s);
            s;
          };
          case (?s) { s };
        };
        Map.add(lvl, levelKeyCompare, (o.timestamp, o.id), true);
      };
    };
  };

  // ── Core operations ────────────────────────────────────────────

  // Allocate a fresh order id WITHOUT creating an order. Used by the sealed
  // model's off-book staging queue so staged-entry ids share the order-id space
  // (no collision with real orders → cancellation can disambiguate by id alone).
  public func allocateId(store : OrderStore) : Nat {
    let id = store.nextOrderId;
    store.nextOrderId += 1;
    id;
  };

  public func createOrder(
    store : OrderStore,
    marketId : Types.MarketId,
    owner : Principal,
    side : Types.Side,
    orderType : Types.OrderType,
    price : Nat,
    quantity : Nat,
    timestamp : Int,
  ) : Types.Order {
    createOrderWithId(store, allocateId(store), marketId, owner, side, orderType, price, quantity, timestamp);
  };

  // W4-22: same as createOrder but with a PRE-RESERVED id (allocateId). The
  // engine reserves the aggressor's id before its match loop when a sweep
  // re-homes a resting order, so the trade records it writes mid-loop can
  // carry the id maker-attribution keys off — the order record itself is
  // only created after the loop.
  public func createOrderWithId(
    store : OrderStore,
    id : Nat,
    marketId : Types.MarketId,
    owner : Principal,
    side : Types.Side,
    orderType : Types.OrderType,
    price : Nat,
    quantity : Nat,
    timestamp : Int,
  ) : Types.Order {
    let order : Types.Order = {
      id; marketId; owner; side; orderType; price; quantity;
      filled = 0; status = #open; timestamp;
      originalQuantity = quantity;
    };
    Map.add(store.orders, Nat.compare, id, order);
    addToOpenIndexes(store, order);
    bumpMarketVersionAndLog(store, marketId, side, price);
    order;
  };

  public func getOrder(store : OrderStore, id : Nat) : ?Types.Order {
    Map.get(store.orders, Nat.compare, id);
  };

  public func saveOrder(store : OrderStore, order : Types.Order) {
    Map.add(store.orders, Nat.compare, order.id, order);
  };

  public func cancelOrder(store : OrderStore, orderId : Nat) : ?Types.Order {
    do ? {
      let order = Map.get(store.orders, Nat.compare, orderId)!;
      let wasOpen = isOpen(order);
      if (wasOpen) { removeFromOpenIndexes(store, order) };
      let cancelled : Types.Order = {
        id = order.id; marketId = order.marketId; owner = order.owner;
        side = order.side; orderType = order.orderType; price = order.price;
        quantity = order.quantity; filled = order.filled;
        status = #cancelled; timestamp = order.timestamp;
        originalQuantity = order.originalQuantity;
      };
      Map.add(store.orders, Nat.compare, orderId, cancelled);
      if (wasOpen) {
        bumpMarketVersionAndLog(store, order.marketId, order.side, order.price);
      };
      cancelled;
    };
  };

  public func remaining(order : Types.Order) : Nat {
    order.quantity - order.filled;
  };

  public func isOpen(o : Types.Order) : Bool {
    switch (o.status) {
      case (#open or #partiallyFilled) { true };
      case _ { false };
    };
  };

  // Delete a TERMINAL (#filled/#cancelled) order's record from the store.
  // Terminal orders are never in the open indexes (removeFromOpenIndexes
  // runs when they close), so only the id→order map needs touching. Used by
  // main.mo's closed-order reaper — without it the map retains every order
  // ever placed, which is what bricked the canister at its wasm-memory
  // limit on 2026-06-10 (~6.2M retained orders, ~95% expired AMM quotes).
  public func removeClosedOrder(store : OrderStore, orderId : Nat) {
    ignore Map.delete(store.orders, Nat.compare, orderId);
  };

  // ── Zombie-order purge ──────────────────────────────────────────
  // Walk every order in the store, find any that are still in the
  // open-indexes but have zero remaining (#open/#partiallyFilled with
  // quantity - filled < ε). Mark them #filled and remove from indexes.
  // These can exist as residue from a historical matching-engine bug
  // where a taker whose entire quantity went to pending matches left
  // a 0-qty resting order behind; this function is idempotent so it's
  // safe to run repeatedly.
  public func purgeZombies(store : OrderStore) : Nat {
    var removed : Nat = 0;
    let ids = Iter.toArray(
      Iter.map<(Nat, Types.Order), Nat>(Map.entries(store.orders), func((k, _)) { k })
    );
    for (id in ids.vals()) {
      switch (Map.get(store.orders, Nat.compare, id)) {
        case null {};
        case (?o) {
          if (isOpen(o) and remaining(o) == 0) {
            let cleaned : Types.Order = {
              id = o.id; marketId = o.marketId; owner = o.owner;
              side = o.side; orderType = o.orderType; price = o.price;
              quantity = o.quantity; filled = o.filled;
              status = #filled; timestamp = o.timestamp;
              originalQuantity = o.originalQuantity;
            };
            Map.add(store.orders, Nat.compare, id, cleaned);
            removeFromOpenIndexes(store, o);
            bumpMarketVersionAndLog(store, o.marketId, o.side, o.price);
            removed += 1;
          };
        };
      };
    };
    removed;
  };

  public func sideEq(a : Types.Side, b : Types.Side) : Bool {
    switch (a, b) {
      case (#buy, #buy) { true };
      case (#sell, #sell) { true };
      case _ { false };
    };
  };

  // Find best opposing order: lowest ask for buy taker, highest bid for sell taker
  // Now uses the market-side index instead of scanning all orders
  public func findBestMatch(store : OrderStore, marketId : Types.MarketId, takerSide : Types.Side) : ?Types.Order {
    findBestMatchExcluding(store, marketId, takerSide, null);
  };

  // findBestMatch variant that skips a set of order ids. Used by the
  // matching engine to walk past makers that are fully locked by
  // in-flight pending matches: those orders are still #open (they
  // haven't been settled yet) so findBestMatch would keep returning
  // them, and the engine would spin or break. Passing them in
  // `excludeIds` lets the engine advance to the next-best maker.
  public func findBestMatchExcluding(
    store     : OrderStore,
    marketId  : Types.MarketId,
    takerSide : Types.Side,
    excludeIds : ?Map.Map<Nat, Bool>,
  ) : ?Types.Order {
    let makerSide = switch (takerSide) { case (#buy) { #sell }; case (#sell) { #buy } };
    let msKey = marketSideKey(marketId, makerSide);
    let lvls = switch (Map.get(store.levelsByMarketSide, Text.compare, msKey)) {
      case null { return null };
      case (?m) { m };
    };
    // Walk price levels best→worst: asks ascending (lowest first), bids
    // descending (highest first). The ordered map reaches the touch in
    // O(log N); we return at the first level holding a usable order, so
    // the common case is O(log N + level size) rather than O(all orders).
    let levelIter = switch (makerSide) {
      case (#sell) { Map.entries(lvls) };        // lowest ask first
      case (#buy)  { Map.reverseEntries(lvls) };  // highest bid first
    };
    label scan for ((_price, lvl) in levelIter) {
      // Within a level all orders share the price → pure time priority
      // (earliest timestamp, id as tie-break) — which is the inner set's KEY
      // ORDER, so the first non-excluded open entry IS the level's best.
      // Cost: O(log K + entries skipped), not the O(K) full-level walk that
      // made a taker sweeping K same-price makers quadratic. Skipped entries
      // are excluded ids (pending-locked / non-takeable / self makers the
      // engine already passed over) plus the defensive closed/missing check.
      for (((_ts, id), _) in Map.entries(lvl)) {
        let excluded = switch (excludeIds) {
          case null { false };
          case (?set) { Option.isSome(Map.get(set, Nat.compare, id)) };
        };
        if (not excluded) {
          switch (Map.get(store.orders, Nat.compare, id)) {
            case null {};
            case (?o) { if (isOpen(o)) { return ?o } };
          };
        };
      };
      // level exhausted (all excluded/closed) → next-best price
    };
    null;
  };

  // Get all open orders for a user — uses user index
  public func getUserOpenOrders(store : OrderStore, user : Principal) : [Types.Order] {
    let userKey = Principal.toText(user);
    let idSet = switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null { return [] };
      case (?s) { s };
    };
    let result = List.empty<Types.Order>();
    for ((id, _) in Map.entries(idSet)) {
      switch (Map.get(store.orders, Nat.compare, id)) {
        case null {};
        case (?o) { if (isOpen(o)) { List.add(result, o) } };
      };
    };
    Iter.toArray(List.values(result));
  };

  // User's total ICPUSD committed in open buy orders on one market —
  // O(log N) read of the running total (kept exact at every order
  // transition; see applyUserExposure).
  public func getUserMarketBuyTotal(store : OrderStore, user : Principal, marketId : Types.MarketId) : Nat {
    Option.get(Map.get(store.userMarketBuyValue, Text.compare, userMarketKey(user, marketId)), 0);
  };

  // User's total base asset committed in open sell orders on one market.
  public func getUserMarketSellTotal(store : OrderStore, user : Principal, marketId : Types.MarketId) : Nat {
    Option.get(Map.get(store.userMarketSellQty, Text.compare, userMarketKey(user, marketId)), 0);
  };

  // Cross-market sum of ICPUSD committed in open buy orders. Used by
  // the Phase-0 soft-cap check to bound total bid exposure at
  // CROSS_MARKET_BID_FACTOR × user's cash.
  public func getUserGrossBuyValue(store : OrderStore, user : Principal) : Nat {
    Option.get(Map.get(store.userGrossBuyValue, Text.compare, Principal.toText(user)), 0);
  };

  // Number of orders a user has resting on the book — the open-order user
  // index is pruned on every close, so its size IS the open count.
  public func getUserOpenOrderCount(store : OrderStore, user : Principal) : Nat {
    switch (Map.get(store.openOrdersByUser, Text.compare, Principal.toText(user))) {
      case null { 0 };
      case (?s) { Map.size(s) };
    };
  };

  // Number of open orders resting at ONE price on one market-side — O(log N)
  // read of the maintained level aggregate. Used by the per-level placement
  // cap (Types.MAX_ORDERS_PER_PRICE_LEVEL): bounding K at a price bounds the
  // work of every path that sweeps a level.
  public func getLevelOrderCount(store : OrderStore, marketId : Types.MarketId, side : Types.Side, price : Nat) : Nat {
    switch (Map.get(store.levelAggByMarketSide, Text.compare, marketSideKey(marketId, side))) {
      case null { 0 };
      case (?lvls) { Option.get(Map.get(lvls, Nat.compare, price), (0, 0)).1 };
    };
  };

  // Oldest resting order (order ids are monotonic, so the smallest open id
  // is the earliest-placed). Used by the per-user book cap's eviction.
  public func getOldestOpenOrderId(store : OrderStore, user : Principal) : ?Nat {
    switch (Map.get(store.openOrdersByUser, Text.compare, Principal.toText(user))) {
      case null { null };
      case (?s) {
        switch (Map.entries(s).next()) {
          case (?(id, _)) { ?id };
          case null { null };
        };
      };
    };
  };

  // ── Aggregate self-check ────────────────────────────────────────
  // Rebuild what the aggregates SHOULD hold by walking the raw open orders,
  // and diff against the maintained maps in both directions. Returns a list
  // of mismatch descriptions (empty = consistent). O(everything) — for the
  // admin endpoint and tests only, never on a hot path.
  public func verifyAggregates(store : OrderStore) : [Text] {
    let issues = List.empty<Text>();
    let expLevel = Map.empty<Text, Map.Map<Nat, (Nat, Nat)>>();
    let expGross = Map.empty<Text, Nat>();
    let expMktBuy = Map.empty<Text, Nat>();
    let expMktSell = Map.empty<Text, Nat>();

    for ((_, o) in Map.entries(store.orders)) {
      if (isOpen(o)) {
        let msKey = marketSideKey(o.marketId, o.side);
        let lvls = switch (Map.get(expLevel, Text.compare, msKey)) {
          case null { let m = Map.empty<Nat, (Nat, Nat)>(); Map.add(expLevel, Text.compare, msKey, m); m };
          case (?m) { m };
        };
        let (q, c) = Option.get(Map.get(lvls, Nat.compare, o.price), (0, 0));
        Map.add(lvls, Nat.compare, o.price, (q + remaining(o), c + 1));
        let uk = Principal.toText(o.owner);
        let umk = userMarketKey(o.owner, o.marketId);
        switch (o.side) {
          case (#buy) {
            let v = Fixed.mul(remaining(o), o.price, true);
            Map.add(expGross, Text.compare, uk, Option.get(Map.get(expGross, Text.compare, uk), 0) + v);
            Map.add(expMktBuy, Text.compare, umk, Option.get(Map.get(expMktBuy, Text.compare, umk), 0) + v);
          };
          case (#sell) {
            Map.add(expMktSell, Text.compare, umk, Option.get(Map.get(expMktSell, Text.compare, umk), 0) + remaining(o));
          };
        };
      };
    };

    func note(t : Text) { if (List.size(issues) < 20) { List.add(issues, t) } };

    // Levels: expected ⊆ actual …
    for ((msKey, lvls) in Map.entries(expLevel)) {
      for ((p, (q, c)) in Map.entries(lvls)) {
        let (aq, ac) = switch (Map.get(store.levelAggByMarketSide, Text.compare, msKey)) {
          case null { (0, 0) };
          case (?a) { Option.get(Map.get(a, Nat.compare, p), (0, 0)) };
        };
        if (aq != q or ac != c) {
          note("level " # msKey # "@" # Nat.toText(p) # " expected (" # Nat.toText(q) # "," # Nat.toText(c)
            # ") got (" # Nat.toText(aq) # "," # Nat.toText(ac) # ")");
        };
      };
    };
    // … and actual ⊆ expected (stale levels the walk no longer sees).
    for ((msKey, lvls) in Map.entries(store.levelAggByMarketSide)) {
      for ((p, (aq, ac)) in Map.entries(lvls)) {
        let known = switch (Map.get(expLevel, Text.compare, msKey)) {
          case null { false };
          case (?e) { Option.isSome(Map.get(e, Nat.compare, p)) };
        };
        if (not known) {
          note("stale level " # msKey # "@" # Nat.toText(p) # " holds (" # Nat.toText(aq) # "," # Nat.toText(ac) # ")");
        };
      };
    };

    func diffNatMap(label_ : Text, exp : Map.Map<Text, Nat>, act : Map.Map<Text, Nat>) {
      for ((k, v) in Map.entries(exp)) {
        let a = Option.get(Map.get(act, Text.compare, k), 0);
        if (a != v) { note(label_ # " " # k # " expected " # Nat.toText(v) # " got " # Nat.toText(a)) };
      };
      for ((k, a) in Map.entries(act)) {
        if (Option.isNull(Map.get(exp, Text.compare, k))) {
          note("stale " # label_ # " " # k # " holds " # Nat.toText(a));
        };
      };
    };
    diffNatMap("grossBuy", expGross, store.userGrossBuyValue);
    diffNatMap("marketBuy", expMktBuy, store.userMarketBuyValue);
    diffNatMap("marketSell", expMktSell, store.userMarketSellQty);

    Iter.toArray(List.values(issues));
  };

  // Get user's max single buy order ICPUSD value — uses user index
  public func getUserMaxBuyOrder(store : OrderStore, user : Principal) : Nat {
    let userKey = Principal.toText(user);
    let idSet = switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null { return 0 };
      case (?s) { s };
    };
    var maxVal : Nat = 0;
    for ((id, _) in Map.entries(idSet)) {
      switch (Map.get(store.orders, Nat.compare, id)) {
        case null {};
        case (?o) {
          if (sideEq(o.side, #buy) and isOpen(o)) {
            let val = Fixed.mul(remaining(o), o.price, true);
            if (val > maxVal) { maxVal := val };
          };
        };
      };
    };
    maxVal;
  };

  // Get user's max single sell order quantity for a specific market — uses user index
  public func getUserMaxSellOrder(store : OrderStore, user : Principal, marketId : Types.MarketId) : Nat {
    let userKey = Principal.toText(user);
    let idSet = switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null { return 0 };
      case (?s) { s };
    };
    var maxVal : Nat = 0;
    for ((id, _) in Map.entries(idSet)) {
      switch (Map.get(store.orders, Nat.compare, id)) {
        case null {};
        case (?o) {
          if (o.marketId == marketId and sideEq(o.side, #sell) and isOpen(o)) {
            let val = remaining(o);
            if (val > maxVal) { maxVal := val };
          };
        };
      };
    };
    maxVal;
  };

  // Get open order IDs for a user on a specific market and side — for LiquidityManager
  public func getOpenOrderIdsForUserMarketSide(store : OrderStore, user : Principal, marketId : Types.MarketId, side : Types.Side) : [Nat] {
    let userKey = Principal.toText(user);
    let idSet = switch (Map.get(store.openOrdersByUser, Text.compare, userKey)) {
      case null { return [] };
      case (?s) { s };
    };
    let result = List.empty<Nat>();
    for ((id, _) in Map.entries(idSet)) {
      switch (Map.get(store.orders, Nat.compare, id)) {
        case null {};
        case (?o) {
          if (o.marketId == marketId and sideEq(o.side, side) and isOpen(o)) {
            List.add(result, id);
          };
        };
      };
    };
    Iter.toArray(List.values(result));
  };

  // Mark order as partially/fully filled
  public func fillOrder(store : OrderStore, orderId : Nat, fillQty : Nat) : ?Types.Order {
    do ? {
      let order = Map.get(store.orders, Nat.compare, orderId)!;
      let newFilled = order.filled + fillQty;
      let newStatus : Types.OrderStatus = if (newFilled >= order.quantity) { #filled } else { #partiallyFilled };
      let updated : Types.Order = {
        id = order.id; marketId = order.marketId; owner = order.owner;
        side = order.side; orderType = order.orderType; price = order.price;
        quantity = order.quantity; filled = newFilled;
        status = newStatus; timestamp = order.timestamp;
        originalQuantity = order.originalQuantity;
      };
      Map.add(store.orders, Nat.compare, orderId, updated);
      if (not isOpen(updated)) {
        // Fully filled: leaving the open set subtracts the whole pre-fill
        // remaining from the aggregates (removeFromOpenIndexes gets the
        // PRE-fill record), so no separate fill delta is needed.
        removeFromOpenIndexes(store, order);
      } else {
        // Partial fill: still resting, so swap the old contribution for the
        // new one (level qty drops by fillQty; exposure re-derives from the
        // post-fill remaining — exact, no rounding drift).
        bumpLevelAgg(store, marketSideKey(order.marketId, order.side), order.price, -(fillQty : Int), 0);
        applyUserExposure(store, order, -1);
        applyUserExposure(store, updated, 1);
      };
      bumpMarketVersionAndLog(store, order.marketId, order.side, order.price);
      updated;
    };
  };

  // Adjust order quantity (for liquidity management)
  public func adjustOrderQuantity(store : OrderStore, orderId : Nat, newQty : Nat) : ?Types.Order {
    do ? {
      let order = Map.get(store.orders, Nat.compare, orderId)!;
      if (newQty <= order.filled) {
        return cancelOrder(store, orderId);
      };
      let updated : Types.Order = {
        id = order.id; marketId = order.marketId; owner = order.owner;
        side = order.side; orderType = order.orderType; price = order.price;
        quantity = newQty; filled = order.filled;
        status = order.status; timestamp = order.timestamp;
        originalQuantity = order.originalQuantity;
      };
      Map.add(store.orders, Nat.compare, orderId, updated);
      if (isOpen(order)) {
        // Same swap discipline as a partial fill: remaining moves by
        // newQty − oldQty (filled is unchanged), count stays.
        bumpLevelAgg(store, marketSideKey(order.marketId, order.side), order.price,
          (newQty : Int) - (order.quantity : Int), 0);
        applyUserExposure(store, order, -1);
        applyUserExposure(store, updated, 1);
      };
      bumpMarketVersionAndLog(store, order.marketId, order.side, order.price);
      updated;
    };
  };

  // ── Market version + level change log helpers ───────────────

  // Aggregated state of a single price level — O(log N) read of the
  // incrementally-maintained aggregate. (This used to re-WALK every open
  // order on the market side per call, and it runs on every order mutation
  // via bumpMarketVersionAndLog: with a few thousand resting orders each
  // placement/cancel/fill paid a full-side scan — roughly a billion cycles
  // per call — which is what dragged the whole exchange down as books grew.)
  func recomputeLevel(store : OrderStore, marketId : Types.MarketId, side : Types.Side, price : Nat) : (Nat, Nat) {
    switch (Map.get(store.levelAggByMarketSide, Text.compare, marketSideKey(marketId, side))) {
      case null { (0, 0) };
      case (?lvls) { Option.get(Map.get(lvls, Nat.compare, price), (0, 0)) };
    };
  };

  // Bump the market's version counter, recompute the level at the given price,
  // and record it in the change log. Prunes oldest entries if log exceeds LEVEL_LOG_MAX_SIZE.
  func bumpMarketVersionAndLog(store : OrderStore, marketId : Types.MarketId, side : Types.Side, price : Nat) {
    // Bump version
    let newVersion = Option.get(Map.get(store.marketVersionCounters, Text.compare, marketId), 0) + 1;
    Map.add(store.marketVersionCounters, Text.compare, marketId, newVersion);

    // Recompute level and create log entry
    let (qty, cnt) = recomputeLevel(store, marketId, side, price);
    let change : Types.LevelChange = { side; price; quantity = qty; orderCount = cnt };

    // Get or create per-market log map
    let logMap = switch (Map.get(store.levelChangeLog, Text.compare, marketId)) {
      case null {
        let m = Map.empty<Nat, Types.LevelChange>();
        Map.add(store.levelChangeLog, Text.compare, marketId, m);
        m;
      };
      case (?m) { m };
    };
    Map.add(logMap, Nat.compare, newVersion, change);

    // Prune oldest entries if over the limit
    let sz = Map.size(logMap);
    if (sz > LEVEL_LOG_MAX_SIZE) {
      let toRemove : Nat = sz - LEVEL_LOG_MAX_SIZE;
      let oldest = List.empty<Nat>();
      label collect for ((v, _) in Map.entries(logMap)) {
        if (List.size(oldest) >= toRemove) { break collect };
        List.add(oldest, v);
      };
      for (v in List.values(oldest)) {
        ignore Map.delete(logMap, Nat.compare, v);
      };
    };
  };

  // ── Candle cache helpers ──────────────────────────────────────

  func candleCacheKey(marketId : Types.MarketId, intervalMs : Nat) : Text {
    marketId # ":" # Nat.toText(intervalMs);
  };

  // Update the candle cache for a single trade across all intervals
  func updateCandleCache(store : OrderStore, marketId : Types.MarketId, trade : Types.Trade) {
    for ((intervalMs, retentionNs) in CANDLE_INTERVALS.vals()) {
      let key = candleCacheKey(marketId, intervalMs);
      let intervalNs : Int = intervalMs * 1_000_000;
      let bucket : Int = (trade.timestamp / intervalNs) * intervalNs;

      let cacheMap = switch (Map.get(store.candleCache, Text.compare, key)) {
        case null {
          let m = Map.empty<Int, Types.Candle>();
          Map.add(store.candleCache, Text.compare, key, m);
          m;
        };
        case (?m) { m };
      };

      switch (Map.get(cacheMap, Int.compare, bucket)) {
        case null {
          // New candle
          Map.add(cacheMap, Int.compare, bucket, {
            time = bucket;
            open = trade.price;
            high = trade.price;
            low = trade.price;
            close = trade.price;
            volume = trade.quantity;
          });
        };
        case (?existing) {
          // Update existing candle
          Map.add(cacheMap, Int.compare, bucket, {
            time = bucket;
            open = existing.open;
            high = if (trade.price > existing.high) { trade.price } else { existing.high };
            low = if (trade.price < existing.low) { trade.price } else { existing.low };
            close = trade.price;
            volume = existing.volume + trade.quantity;
          });
        };
      };

      // Prune old candles if retention is set
      if (retentionNs > 0) {
        let cutoff = trade.timestamp - retentionNs;
        let toRemove = List.empty<Int>();
        for ((ts, _) in Map.entries(cacheMap)) {
          if (ts < cutoff) { List.add(toRemove, ts) };
        };
        for (ts in List.values(toRemove)) {
          ignore Map.delete(cacheMap, Int.compare, ts);
        };
      };
    };
  };

  // ── Price continuity: zero-volume candles for tradeless buckets ──
  // Called on a clock (~once a minute per market) with the oracle reference
  // price. Any interval bucket that no trade has touched gets a flat candle
  // at that price with volume = 0 — the synthetic marker, since no real
  // trade has zero quantity. Upsert-if-absent only: a bucket with trades is
  // never modified, and a later trade in a synthetic bucket takes over via
  // updateCandleCache's existing-candle branch (open stays the reference
  // price the bucket genuinely opened at). Pruning runs only on insert —
  // when trades flow, updateCandleCache already prunes; when they don't,
  // this is the only writer.
  public func fillEmptyCandles(store : OrderStore, marketId : Types.MarketId, price : Nat, now : Int) {
    for ((intervalMs, retentionNs) in CANDLE_INTERVALS.vals()) {
      let key = candleCacheKey(marketId, intervalMs);
      let intervalNs : Int = intervalMs * 1_000_000;
      let bucket : Int = (now / intervalNs) * intervalNs;

      let cacheMap = switch (Map.get(store.candleCache, Text.compare, key)) {
        case null {
          let m = Map.empty<Int, Types.Candle>();
          Map.add(store.candleCache, Text.compare, key, m);
          m;
        };
        case (?m) { m };
      };

      switch (Map.get(cacheMap, Int.compare, bucket)) {
        case (?_) {};   // trades (or an earlier sweep) already own this bucket
        case null {
          Map.add(cacheMap, Int.compare, bucket, {
            time = bucket;
            open = price;
            high = price;
            low = price;
            close = price;
            volume = 0;
          });
          if (retentionNs > 0) {
            let cutoff = now - retentionNs;
            let toRemove = List.empty<Int>();
            for ((ts, _) in Map.entries(cacheMap)) {
              if (ts < cutoff) { List.add(toRemove, ts) };
            };
            for (ts in List.values(toRemove)) {
              ignore Map.delete(cacheMap, Int.compare, ts);
            };
          };
        };
      };
    };
  };

  public func recordTrade(
    store : OrderStore,
    marketId : Types.MarketId,
    buyOrderId : Nat,
    sellOrderId : Nat,
    buyer : Principal,
    seller : Principal,
    price : Nat,
    quantity : Nat,
    timestamp : Int,
    takerOrderType : ?Types.OrderType,
  ) : Types.Trade {
    let id = store.nextTradeId;
    store.nextTradeId += 1;
    let trade : Types.Trade = {
      id; marketId; buyOrderId; sellOrderId;
      buyer; seller; price; quantity; timestamp;
      takerOrderType;
    };
    List.add(store.trades, trade);
    // Also add to per-market trade list
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { List.empty<Types.Trade>() };
      case (?l) { l };
    };
    List.add(mList, trade);
    Map.add(store.tradesByMarket, Text.compare, marketId, mList);
    // Update candle cache incrementally
    updateCandleCache(store, marketId, trade);
    trade;
  };

  // Get all trades for a specific user (as buyer or seller), most-recent last
  public func getUserTrades(store : OrderStore, user : Principal, limit : Nat) : [Types.Trade] {
    let filtered = List.empty<Types.Trade>();
    for (t in List.values(store.trades)) {
      if (Principal.equal(t.buyer, user) or Principal.equal(t.seller, user)) {
        List.add(filtered, t);
      };
    };
    let all = Iter.toArray(List.values(filtered));
    let n = all.size();
    if (n <= limit) { return all };
    let result = List.empty<Types.Trade>();
    var i : Nat = n - limit;
    while (i < n) { List.add(result, all[i]); i += 1 };
    Iter.toArray(List.values(result))
  };

  // Get user trades since a given timestamp. Walks the global trades list
  // via a lazy reverse iterator and stops as soon as we reach the caller's
  // `sinceTimestamp` — O(recent-delta) instead of O(total trades).
  public func getUserTradesSince(store : OrderStore, user : Principal, sinceTimestamp : Int, limit : Nat) : [Types.Trade] {
    let rev = List.empty<Types.Trade>();
    var count : Nat = 0;
    label scan for (t in List.reverseValues(store.trades)) {
      if (count >= limit) { break scan };
      if (t.timestamp <= sinceTimestamp) { break scan };
      if (Principal.equal(t.buyer, user) or Principal.equal(t.seller, user)) {
        List.add(rev, t);
        count += 1;
      };
    };
    // rev is reverse-chrono; flip to chrono.
    let n = List.size(rev);
    let result = List.empty<Types.Trade>();
    var j : Int = n - 1;
    while (j >= 0) {
      switch (List.get(rev, Int.abs(j))) { case (?t) { List.add(result, t) }; case null {} };
      j -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Get user trades with id > sinceTradeId — the MM-program cursor (trade ids
  // are globally monotone, so an id cursor never re-delivers or skips across
  // polls the way a timestamp can straddle same-ns fills). Same lazy reverse
  // walk as getUserTradesSince: O(recent-delta), chrono-ascending result.
  public func getUserTradesSinceId(store : OrderStore, user : Principal, sinceTradeId : Nat, limit : Nat) : [Types.Trade] {
    let rev = List.empty<Types.Trade>();
    var count : Nat = 0;
    label scan for (t in List.reverseValues(store.trades)) {
      if (count >= limit) { break scan };
      if (t.id <= sinceTradeId) { break scan };
      if (Principal.equal(t.buyer, user) or Principal.equal(t.seller, user)) {
        List.add(rev, t);
        count += 1;
      };
    };
    let n = List.size(rev);
    let result = List.empty<Types.Trade>();
    var j : Int = n - 1;
    while (j >= 0) {
      switch (List.get(rev, Int.abs(j))) { case (?t) { List.add(result, t) }; case null {} };
      j -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Get the last `limit` trades for a market in chronological order.
  // O(limit): walks the list from the tail via a lazy reverse iterator
  // instead of materialising the whole list.
  public func getRecentTrades(store : OrderStore, marketId : Types.MarketId, limit : Nat) : [Types.Trade] {
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { return [] };
      case (?l) { l };
    };
    // Collect up to `limit` items from the tail (in reverse-chrono order).
    let rev = List.empty<Types.Trade>();
    var count : Nat = 0;
    label take for (t in List.reverseValues(mList)) {
      if (count >= limit) { break take };
      List.add(rev, t);
      count += 1;
    };
    // Flip to chronological order for the caller.
    let n = List.size(rev);
    let result = List.empty<Types.Trade>();
    var j : Int = n - 1;
    while (j >= 0) {
      switch (List.get(rev, Int.abs(j))) { case (?t) { List.add(result, t) }; case null {} };
      j -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Get all trades for a market — uses per-market trade list
  public func getAllTrades(store : OrderStore, marketId : Types.MarketId) : [Types.Trade] {
    switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { [] };
      case (?l) { Iter.toArray(List.values(l)) };
    };
  };

  // Convert a Trade to a slim PublicTrade. Originally a bandwidth saving; it is
  // now also the DE-IDENTIFICATION boundary — dropping buyer/seller is what keeps
  // the public tape from naming counterparties. Public so the timestamp-keyed
  // query in mixins/MarketData.mo can redact through it too.
  public func toPublicTrade(t : Types.Trade) : Types.PublicTrade {
    { id = t.id; price = t.price; quantity = t.quantity; timestamp = t.timestamp }
  };

  // Get recent public (slim) trades for a market, chronological order.
  // O(limit): lazy reverse iterator, same pattern as getRecentTrades.
  public func getRecentPublicTrades(store : OrderStore, marketId : Types.MarketId, limit : Nat) : [Types.PublicTrade] {
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { return [] };
      case (?l) { l };
    };
    let rev = List.empty<Types.PublicTrade>();
    var count : Nat = 0;
    label take for (t in List.reverseValues(mList)) {
      if (count >= limit) { break take };
      List.add(rev, toPublicTrade(t));
      count += 1;
    };
    let n = List.size(rev);
    let result = List.empty<Types.PublicTrade>();
    var j : Int = n - 1;
    while (j >= 0) {
      switch (List.get(rev, Int.abs(j))) { case (?t) { List.add(result, t) }; case null {} };
      j -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Get public trades since a given trade ID (for incremental market
  // updates). Walks the list from the tail via a lazy reverse iterator,
  // breaks as soon as we reach the caller's sinceTradeId — O(delta), not
  // O(total trades).
  public func getPublicTradesSince(store : OrderStore, marketId : Types.MarketId, sinceTradeId : Nat, limit : Nat) : [Types.PublicTrade] {
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { return [] };
      case (?l) { l };
    };
    let rev = List.empty<Types.PublicTrade>();
    var count : Nat = 0;
    label scan for (t in List.reverseValues(mList)) {
      if (count >= limit) { break scan };
      if (t.id <= sinceTradeId) { break scan };
      List.add(rev, toPublicTrade(t));
      count += 1;
    };
    // rev is reverse-chrono; flip to chrono for the caller.
    let n = List.size(rev);
    let result = List.empty<Types.PublicTrade>();
    var j : Int = n - 1;
    while (j >= 0) {
      switch (List.get(rev, Int.abs(j))) { case (?t) { List.add(result, t) }; case null {} };
      j -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Get the current market version counter
  public func getMarketVersion(store : OrderStore, marketId : Types.MarketId) : Nat {
    Option.get(Map.get(store.marketVersionCounters, Text.compare, marketId), 0);
  };

  // Get incremental order book delta since a given version.
  // Returns null if the client is too stale (oldest log entry > sinceVersion + 1),
  // in which case the caller should fall back to a full snapshot.
  // Returned asks/bids contain only changed levels (quantity=0 means removed).
  public func getOrderBookDelta(store : OrderStore, marketId : Types.MarketId, sinceVersion : Nat) : ?Types.OrderBookDelta {
    let logMap = switch (Map.get(store.levelChangeLog, Text.compare, marketId)) {
      case null { return ?{ asks = []; bids = [] } }; // no changes ever
      case (?m) { m };
    };
    if (Map.size(logMap) == 0) {
      return ?{ asks = []; bids = [] };
    };
    // Find oldest version in the log — if it's > sinceVersion + 1, client missed entries
    var oldestVersion : Nat = 0;
    label findOldest for ((v, _) in Map.entries(logMap)) {
      oldestVersion := v;
      break findOldest;
    };
    if (oldestVersion > sinceVersion + 1) {
      return null; // too stale, caller must return full snapshot
    };

    // Scan entries with version > sinceVersion, dedupe by (side, price) keeping latest
    // Since Map.entries iterates in ascending order, the last write wins naturally
    let askMap = Map.empty<Nat, Types.OrderBookLevel>();
    let bidMap = Map.empty<Nat, Types.OrderBookLevel>();
    for ((v, change) in Map.entries(logMap)) {
      if (v > sinceVersion) {
        let level : Types.OrderBookLevel = {
          price = change.price;
          quantity = change.quantity;
          orderCount = change.orderCount;
        };
        switch (change.side) {
          case (#buy) { Map.add(bidMap, Nat.compare, change.price, level) };
          case (#sell) { Map.add(askMap, Nat.compare, change.price, level) };
        };
      };
    };
    // Collect into arrays (order doesn't matter — client uses Maps by price)
    let asks = Iter.toArray(
      Iter.map<(Nat, Types.OrderBookLevel), Types.OrderBookLevel>(
        Map.entries(askMap),
        func((_, l)) { l },
      )
    );
    let bids = Iter.toArray(
      Iter.map<(Nat, Types.OrderBookLevel), Types.OrderBookLevel>(
        Map.entries(bidMap),
        func((_, l)) { l },
      )
    );
    ?{ asks; bids };
  };

  // Get the most recent trade id for a market (0 if none).
  // O(1): reads the tail element directly instead of materialising the whole
  // list (this is called by every frontend poll and every sim verification;
  // materialising 60k+ trades here was the main CPU hotspot).
  public func getLastTradeId(store : OrderStore, marketId : Types.MarketId) : Nat {
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { return 0 };
      case (?l) { l };
    };
    switch (List.last(mList)) {
      case null { 0 };
      case (?t) { t.id };
    };
  };

  // Build order book snapshot — uses market-side index + Float-keyed maps for sort-free aggregation
  // Snapshot straight from the maintained level aggregates: O(levels
  // returned), no walk over orders. `depth` caps the levels per side
  // (null = whole book — tests and admin folds rely on the full view;
  // the UI passes a cap since it only renders the top of the book).
  public func getSnapshot(store : OrderStore, marketId : Types.MarketId, depth : ?Nat) : Types.OrderBookSnapshot {
    let cap = Option.get(depth, 0);   // 0 = unlimited

    func side(msKey : Text, descending : Bool) : [Types.OrderBookLevel] {
      let out = List.empty<Types.OrderBookLevel>();
      switch (Map.get(store.levelAggByMarketSide, Text.compare, msKey)) {
        case null {};
        case (?lvls) {
          // B-tree entries are price-ascending; bids read in reverse so both
          // sides emit best-first.
          let iter = if (descending) { Map.reverseEntries(lvls) } else { Map.entries(lvls) };
          label take for ((p, (q, c)) in iter) {
            if (cap > 0 and List.size(out) >= cap) { break take };
            List.add(out, { price = p; quantity = q; orderCount = c });
          };
        };
      };
      Iter.toArray(List.values(out));
    };

    let bids = side(marketSideKey(marketId, #buy), true);
    let asks = side(marketSideKey(marketId, #sell), false);

    let spread : Nat = if (bids.size() > 0 and asks.size() > 0 and asks[0].price >= bids[0].price) {
      asks[0].price - bids[0].price;       // clamp: a book never rests crossed
    } else { 0 };

    { bids; asks; spread };
  };

  // Reset all orders (for testing) — also clears open-order indexes
  // Full wipe — used by the test-only main.resetExchange endpoint.
  // We previously only cancelled open orders, which left trade
  // history, candles, market-version counters and level-change logs
  // in place. That broke test isolation: a regression test asserting
  // "one trade should exist" would see leftover trades from earlier
  // tests. Now we clear everything; the next deploy or explicit
  // initMarkets call will repopulate.
  public func resetAll(store : OrderStore) {
    Map.clear(store.orders);
    Map.clear(store.openOrdersByMarketSide);
    Map.clear(store.levelsByMarketSide);
    Map.clear(store.openOrdersByUser);
    Map.clear(store.tradesByMarket);
    Map.clear(store.levelAggByMarketSide);
    Map.clear(store.userGrossBuyValue);
    Map.clear(store.userMarketBuyValue);
    Map.clear(store.userMarketSellQty);
    Map.clear(store.candleCache);
    Map.clear(store.marketVersionCounters);
    Map.clear(store.levelChangeLog);
    List.clear(store.trades);
    store.nextOrderId := 1;
    store.nextTradeId := 1;
  };

  // ── Candle query (reads from cache) ─────────────────────────────

  public func getCandles(
    store : OrderStore,
    marketId : Types.MarketId,
    intervalMs : Nat,
    page : Nat,
    pageSize : Nat,
  ) : Types.CandleResponse {
    let key = candleCacheKey(marketId, intervalMs);
    let cacheMap = switch (Map.get(store.candleCache, Text.compare, key)) {
      case null { return { candles = []; hasMore = false } };
      case (?m) { m };
    };

    // Map.entries iterates in ascending key order (timestamp ascending) — collect all
    let all = Iter.toArray(Map.entries(cacheMap));
    let total = all.size();
    if (total == 0) { return { candles = []; hasMore = false } };

    // Paginate from the end: page 0 = most recent pageSize candles
    let endIdx = SafeMath.subOrZero(total, page * pageSize);
    let startIdx = SafeMath.subOrZero(endIdx, pageSize);
    let hasMore = startIdx > 0;

    let result = List.empty<Types.Candle>();
    var i = startIdx;
    while (i < endIdx) {
      List.add(result, all[i].1);
      i += 1;
    };

    { candles = Iter.toArray(List.values(result)); hasMore };
  };

  // Get trades since a given timestamp (for incremental chart updates)
  public func getTradesSince(
    store : OrderStore,
    marketId : Types.MarketId,
    sinceTimestamp : Int,
    limit : Nat,
  ) : [Types.Trade] {
    let mList = switch (Map.get(store.tradesByMarket, Text.compare, marketId)) {
      case null { return [] };
      case (?l) { l };
    };
    let all = Iter.toArray(List.values(mList));
    let result = List.empty<Types.Trade>();
    var count : Nat = 0;
    // Trades are chronological; scan from end for efficiency
    var i : Int = all.size() - 1;
    while (i >= 0 and count < limit) {
      let idx = Int.abs(i);
      if (all[idx].timestamp > sinceTimestamp) {
        List.add(result, all[idx]);
        count += 1;
      } else {
        // Earlier trades won't match; stop scanning
        i := -1; // break
      };
      i -= 1;
    };
    // Result is reverse-chronological from scanning; reverse to chronological
    let arr = Iter.toArray(List.values(result));
    let n = arr.size();
    let reversed = List.empty<Types.Trade>();
    var j : Int = n - 1;
    while (j >= 0) {
      List.add(reversed, arr[Int.abs(j)]);
      j -= 1;
    };
    Iter.toArray(List.values(reversed));
  };
};
