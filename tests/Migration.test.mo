// Unit fixtures for the ACTIVE one-shot fossil sweep (src/backend/migration.mo,
// task 1788744109). Pins the transform's semantics exactly: every stored pool
// is carried onto the field-less AMM.Pool with EVERY other field verbatim
// (the fossil protectionWindowSec is the only thing that goes), the pool map
// keeps its size and keys, an empty pool map stays empty, and non-empty
// fossil maps / a non-initial counter are consumed without complaint
// (dropped — they are empty / initial on every live target, but the
// transform must not depend on that).
//
// DELETE this file together with migration.mo at the migration's retirement
// (once every live target has upgraded through it once).

import Migration "../src/backend/migration";
import AMM "../src/backend/lib/AMM";
import Types "../src/backend/lib/Types";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Debug "mo:core/Debug";

func oldPool(mkt : Text, tok : Text, window : Nat, i : Nat) : Migration.OldPool = {
  marketId = mkt; baseToken = tok;
  spreadBps = 20 + i; quoteDepthBase = 5_000_000 + i; numLevels = 3 + i; levelSpacingBps = 15 + i;
  protectionWindowSec = window;
  enabled = (i % 2 == 0);
  inventoryTargetBase = 1_000 + i; skewIntensityBps = 10 + i;
  refPrice = 7_816_020_000_000 + i; refPriceUpdatedNs = 1_793_000_000_000_000_000 + i;
  activeBidIds = [100 + i, 101 + i]; activeAskIds = [200 + i];
  lastRequoteNs = 1_793_000_000_000_000_001 + i;
  totalLPSupply = 199_544_376_806_217 + i;
  volRegime = 12.5 + 0.25 * (if (i == 0) { 0.0 } else { 1.0 });
  lastVolSamplePrice = 7_800_000_000_000 + i; lastVolSampleNs = 1_793_000_000_000_000_002 + i;
  lastRebalanceNs = 1_793_000_000_000_000_003 + i;
};

func assertCarried(o : Migration.OldPool, n : AMM.Pool) {
  if (n.marketId != o.marketId or n.baseToken != o.baseToken
      or n.spreadBps != o.spreadBps or n.quoteDepthBase != o.quoteDepthBase
      or n.numLevels != o.numLevels or n.levelSpacingBps != o.levelSpacingBps
      or n.enabled != o.enabled
      or n.inventoryTargetBase != o.inventoryTargetBase or n.skewIntensityBps != o.skewIntensityBps
      or n.refPrice != o.refPrice or n.refPriceUpdatedNs != o.refPriceUpdatedNs
      or n.activeBidIds != o.activeBidIds or n.activeAskIds != o.activeAskIds
      or n.lastRequoteNs != o.lastRequoteNs or n.totalLPSupply != o.totalLPSupply
      or n.volRegime != o.volRegime
      or n.lastVolSamplePrice != o.lastVolSamplePrice or n.lastVolSampleNs != o.lastVolSampleNs
      or n.lastRebalanceNs != o.lastRebalanceNs) {
    Runtime.trap("pool " # o.marketId # " not carried verbatim: " # debug_show n);
  };
};

// ── Fixture: two stored pools (one carrying a NON-zero window, so the drop is
//    visible), non-empty fossil maps, a non-initial counter ──
let pools = Map.empty<Types.MarketId, Migration.OldPool>();
let btc = oldPool("BTC-ICPUSD", "BTC", 0, 0);
let eth = oldPool("ETH-ICPUSD", "ETH", 7, 1);
Map.add(pools, Text.compare, "BTC-ICPUSD", btc);
Map.add(pools, Text.compare, "ETH-ICPUSD", eth);

let windows = Map.empty<Nat, Nat>();
Map.add(windows, Nat.compare, 73, 5_000_000_000);
let byMaker = Map.empty<Nat, Map.Map<Nat, Bool>>();
let inner = Map.empty<Nat, Bool>();
Map.add(inner, Nat.compare, 9, true);
Map.add(byMaker, Nat.compare, 73, inner);
let qty = Map.empty<Nat, Nat>();
Map.add(qty, Nat.compare, 73, 10_000_000);
let pms = Map.empty<Nat, {
  id : Nat; marketId : Types.MarketId; makerOrderId : Nat;
  makerPrincipal : Principal; takerPrincipal : Principal;
  takerSide : Types.Side; takerOrderType : Types.OrderType;
  price : Nat; quantity : Nat;
  takerDebitToken : Types.TokenId; takerDebitAmount : Nat;
  makerDebitToken : Types.TokenId; makerDebitAmount : Nat;
  createdAtNs : Int; expiryNs : Int;
  status : { #pending; #finalized; #voided };
}>();
Map.add(pms, Nat.compare, 9, {
  id = 9; marketId = "BTC-ICPUSD"; makerOrderId = 73;
  makerPrincipal = Principal.fromText("2vxsx-fae"); takerPrincipal = Principal.fromText("2vxsx-fae");
  takerSide = #buy; takerOrderType = #limit;
  price = 7_500_000_000_000; quantity = 100_000_000;
  takerDebitToken = "ICPUSD"; takerDebitAmount = 7_500_000_000_000;
  makerDebitToken = "BTC"; makerDebitAmount = 100_000_000;
  createdAtNs = 1; expiryNs = 2; status = #pending;
});

let out = Migration.run({
  orderSettlementWindows = windows;
  pendingByMaker = byMaker;
  var nextPendingMatchId = 10;
  pendingQtyByMaker = qty;
  pendingMatches = pms;
  pools;
});

// ── Both pools carried verbatim, keys kept, size kept ──
if (Map.size(out.pools) != 2) {
  Runtime.trap("expected 2 swept pools, got " # debug_show (Map.size(out.pools)));
};
switch (Map.get(out.pools, Text.compare, "BTC-ICPUSD")) {
  case null { Runtime.trap("BTC-ICPUSD missing after the sweep") };
  case (?p) { assertCarried(btc, p) };
};
switch (Map.get(out.pools, Text.compare, "ETH-ICPUSD")) {
  case null { Runtime.trap("ETH-ICPUSD missing after the sweep") };
  case (?p) { assertCarried(eth, p) };
};
// The swept record IS AMM.Pool: emptyPool's shape accepts it (a compile-time
// pin that no field but the fossil went missing — a stray extra field would
// not type as AMM.Pool either).
let shaped : AMM.Pool = Migration.sweepPool(eth);
if (shaped.marketId != "ETH-ICPUSD") { Runtime.trap("sweepPool lost the market id") };

// ── An empty pool map sweeps to an empty pool map ──
let none = Migration.run({
  orderSettlementWindows = Map.empty<Nat, Nat>();
  pendingByMaker = Map.empty<Nat, Map.Map<Nat, Bool>>();
  var nextPendingMatchId = 1;
  pendingQtyByMaker = Map.empty<Nat, Nat>();
  pendingMatches = Map.empty<Nat, {
    id : Nat; marketId : Types.MarketId; makerOrderId : Nat;
    makerPrincipal : Principal; takerPrincipal : Principal;
    takerSide : Types.Side; takerOrderType : Types.OrderType;
    price : Nat; quantity : Nat;
    takerDebitToken : Types.TokenId; takerDebitAmount : Nat;
    makerDebitToken : Types.TokenId; makerDebitAmount : Nat;
    createdAtNs : Int; expiryNs : Int;
    status : { #pending; #finalized; #voided };
  }>();
  pools = Map.empty<Types.MarketId, Migration.OldPool>();
});
if (Map.size(none.pools) != 0) { Runtime.trap("an empty pool map must sweep to an empty pool map") };

Debug.print("Migration.test.mo: PendingMatch-era fossil sweep semantics pinned ✓");
