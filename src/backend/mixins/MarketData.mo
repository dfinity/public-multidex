// MarketData.mo — read-only market queries that delegate straight
// into OrderBook. No state of its own; the actor passes the OrderStore
// in and the mixin exposes the queries to the Candid surface.
//
// Excluded from this mixin (kept in main.mo for now):
//   - getMarkets — depends on the Rolling24h type and rollingStats map
//     that still live in main.mo. Will migrate once we extract a
//     lib/MarketStats module.
//   - getMarketChanges — touches user-side state too; will move with
//     MarketChanges mixin in a later step.

import Array "mo:core/Array";
import Types "../lib/Types";
import OrderBook "../lib/OrderBook";

mixin (orderStore : OrderBook.OrderStore) {

  public query func getOrderBook(marketId : Types.MarketId) : async Types.OrderBookSnapshot {
    OrderBook.getSnapshot(orderStore, marketId, null);
  };

  // Depth-capped variant: at most `depth` levels per side (null = whole
  // book). A SEPARATE method rather than a trailing opt arg on getOrderBook
  // because the icp CLI serializes strictly against the declared arity —
  // same precedent as placeLimitOrder/placeLimitOrderExp.
  // W4-24 DECISION: this serves the RAW book, deliberately — the orders are
  // genuine information. But resting orders carry no reservation (documented
  // design), so raw depth is NOT what a taker can rely on: phantom depth is
  // free to create. Anyone SIZING flow against the book must use the
  // backend's getTakeableDepth, which nets out maker funding via the same
  // walk the FOK gate trusts.
  public query func getOrderBookDepth(marketId : Types.MarketId, depth : ?Nat) : async Types.OrderBookSnapshot {
    OrderBook.getSnapshot(orderStore, marketId, depth);
  };

  // BREAKING (API v-next): these three now return the de-identified
  // Types.PublicTrade instead of Types.Trade. Types.Trade carries `buyer` and
  // `seller` PRINCIPALS, and these are unauthenticated public queries, so the
  // venue was publishing a named, timestamped, priced fill ledger for every
  // trader — joinable by tradeId against the archive tape to bind an owner to
  // their margin-pool principal, which is precisely what the public `order`
  // entity withholds `owner` to prevent. PublicTrade (id/price/quantity/
  // timestamp) is what the charts and tape actually consume; the redacted
  // variants already existed and were used by the adjacent public methods.
  // Principal-attributed fills remain available to the party itself via the
  // owner-scoped archive path (getMyEvents / getMyArchivedEvents).
  public query func getRecentTrades(marketId : Types.MarketId) : async [Types.PublicTrade] {
    OrderBook.getRecentPublicTrades(orderStore, marketId, 100);
  };

  // Also newly BOUNDED: it delegated to an uncapped full-history scan, so a
  // ~20-byte anonymous query materialised a 200k+ element array.
  public query func getAllTrades(marketId : Types.MarketId) : async [Types.PublicTrade] {
    OrderBook.getRecentPublicTrades(orderStore, marketId, 1000);
  };

  public query func getCandles(marketId : Types.MarketId, intervalMs : Nat, page : Nat) : async Types.CandleResponse {
    OrderBook.getCandles(orderStore, marketId, intervalMs, page, 100);
  };

  // Same de-identification as the two above (BREAKING: now [PublicTrade]).
  // Keeps its timestamp keying — the existing getPublicTradesSince keys on
  // tradeId, so we redact through toPublicTrade rather than change the caller
  // contract.
  public query func getTradesSince(marketId : Types.MarketId, sinceTimestamp : Int) : async [Types.PublicTrade] {
    Array.map(
      OrderBook.getTradesSince(orderStore, marketId, sinceTimestamp, 200),
      OrderBook.toPublicTrade,
    );
  };

  // Cheap nonce-based change detection for clients that want to poll
  // less often than the full getMarketChanges flow.
  public query func getMarketStatus(marketId : Types.MarketId) : async Types.MarketStatus {
    let version     = OrderBook.getMarketVersion(orderStore, marketId);
    let lastTradeId = OrderBook.getLastTradeId(orderStore, marketId);
    { version; lastTradeId };
  };

  public query func getRecentPublicTrades(marketId : Types.MarketId) : async [Types.PublicTrade] {
    OrderBook.getRecentPublicTrades(orderStore, marketId, 100);
  };

  public query func getPublicTradesSince(marketId : Types.MarketId, sinceTradeId : Nat) : async [Types.PublicTrade] {
    OrderBook.getPublicTradesSince(orderStore, marketId, sinceTradeId, 100);
  };
};
