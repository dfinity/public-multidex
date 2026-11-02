// ── ACTIVE one-shot EOP migration: sweep the SIX PendingMatch-era fossils
//    (task 1788744109) ──
//
// The actor's inline `(with migration = ...)` slot is single-occupancy, so
// all six ride ONE transform:
//
// 1. The five stable fields the retired PendingMatch / protection-window
//    machinery wrote (task 1788516198 deleted the machinery; apiVersion
//    6.0.0, task 1788731608, removed its Candid surfaces): the
//    `orderSettlementWindows` map (orderId → window ns), the `pendingMatches`
//    map (pendingMatchId → PendingMatch — the record whose frozen shape is
//    inlined below; Types.PendingMatch / PendingMatchStatus are deleted
//    with this sweep), the `pendingByMaker` void-on-cancel index, the
//    `nextPendingMatchId` counter and the `pendingQtyByMaker` maker-quantity
//    lock. Nothing wrote them after the retirement (resetExchange cleared
//    them), so every live target holds them empty / at the initial value —
//    they are consumed by the domain and simply not carried forward. EOP
//    refuses a stable-field drop on a plain upgrade (IC0503), which is why
//    they had to stay declared until this sweep.
//
// 2. `pools` — the stable map of AMM.Pool — is mapped from the STORED record,
//    which still carried the fossil `protectionWindowSec` (stored, never
//    consulted, 0 on every pool since the retirement; the frozen pre-sweep
//    shape is inlined below), onto the field-less AMM.Pool. apiVersion 6.0.0
//    had projected the field out of the public record through AMM.PoolView
//    + AMM.toView because EOP refused the in-record drop live (IC0503,
//    2026-09-07); with the stored record field-less, that projection
//    collapsed back into Pool (AMM.PoolView stays as an alias — the
//    published Candid's record name — so the contract is byte-identical).
//    Every other field is carried verbatim.
//
// RETIREMENT (same discipline as the five retired migrations noted above
// the actor in main.mo): once every live target (cloud engine, subnet) has
// upgraded through this exactly once, REMOVE the `(with migration = ...)`
// clause, the import, this file and tests/Migration.test.mo, and fold the
// ACTIVE paragraph of main.mo's NOTE into the retired list (SIX). Leaving
// the clause in place refuses the NEXT upgrade — the migrated actor no
// longer declares the fossil fields and its stored pools are the field-less
// record, so this function's domain can never match again: "RTS error:
// Memory-incompatible program upgrade" (IC0503 — the `pools` leg is a
// mutable Map of the OLD record, invariant in its element type, so the
// compatibility check fires before the body runs; rehearsed 2026-11-02 on
// the seat replica, the second upgrade refused exactly so and the read set
// stayed byte-identical). Until then, venues cold-started from post-sweep
// code hit that refusal on their FIRST plain upgrade (born without the
// fossils): swap builds with `icp build backend` + `icp canister install
// backend --mode reinstall -y --identity anonymous`, then reseed with
// `cold_start.sh --mode full --no-simulate --no-deploy`. A rollback of a
// migrated venue to pre-sweep code is refused with the same text — a
// rollback is a reinstall.
import Map "mo:core/Map";
import Text "mo:core/Text";
import Types "lib/Types";
import AMM "lib/AMM";

module {
  // FROZEN shape of the retired pending-match record (formerly
  // Types.PendingMatch / Types.PendingMatchStatus, deleted with this sweep).
  // Consumed, never emitted. Unchanged scalar/alias types come from Types.
  type OldPendingMatchStatus = { #pending; #finalized; #voided };
  type OldPendingMatch = {
    id              : Nat;
    marketId        : Types.MarketId;
    makerOrderId    : Nat;
    makerPrincipal  : Principal;
    takerPrincipal  : Principal;
    takerSide       : Types.Side;
    takerOrderType  : Types.OrderType;
    price           : Nat;
    quantity        : Nat;
    takerDebitToken  : Types.TokenId;
    takerDebitAmount : Nat;
    makerDebitToken  : Types.TokenId;
    makerDebitAmount : Nat;
    createdAtNs : Int;
    expiryNs    : Int;
    status      : OldPendingMatchStatus;
  };

  // FROZEN pre-sweep AMM.Pool: the stored record WITH the fossil field. A
  // mutable Map is invariant in its element type, so this must match the
  // deployed record exactly — field names and types as AMM.Pool declared
  // them through apiVersion 6.0.0 (the order is immaterial).
  public type OldPool = {
    marketId  : Types.MarketId;
    baseToken : Types.TokenId;
    spreadBps           : Nat;
    quoteDepthBase      : Nat;
    numLevels           : Nat;
    levelSpacingBps     : Nat;
    protectionWindowSec : Nat;   // the fossil: 0 on every pool, never consulted
    enabled             : Bool;
    inventoryTargetBase : Nat;
    skewIntensityBps    : Nat;
    refPrice            : Nat;
    refPriceUpdatedNs   : Int;
    activeBidIds        : [Nat];
    activeAskIds        : [Nat];
    lastRequoteNs       : Int;
    totalLPSupply       : Nat;
    volRegime           : Float;
    lastVolSamplePrice  : Nat;
    lastVolSampleNs     : Int;
    lastRebalanceNs     : Int;
  };

  // The projection — every stored field but the fossil, carried verbatim.
  public func sweepPool(p : OldPool) : AMM.Pool = {
    marketId = p.marketId; baseToken = p.baseToken;
    spreadBps = p.spreadBps; quoteDepthBase = p.quoteDepthBase; numLevels = p.numLevels;
    levelSpacingBps = p.levelSpacingBps; enabled = p.enabled;
    inventoryTargetBase = p.inventoryTargetBase; skewIntensityBps = p.skewIntensityBps;
    refPrice = p.refPrice; refPriceUpdatedNs = p.refPriceUpdatedNs;
    activeBidIds = p.activeBidIds; activeAskIds = p.activeAskIds; lastRequoteNs = p.lastRequoteNs;
    totalLPSupply = p.totalLPSupply;
    volRegime = p.volRegime; lastVolSamplePrice = p.lastVolSamplePrice; lastVolSampleNs = p.lastVolSampleNs;
    lastRebalanceNs = p.lastRebalanceNs;
  };

  public func run(old : {
    orderSettlementWindows : Map.Map<Nat, Nat>;
    pendingByMaker         : Map.Map<Nat, Map.Map<Nat, Bool>>;
    var nextPendingMatchId : Nat;
    pendingQtyByMaker      : Map.Map<Nat, Nat>;
    pendingMatches         : Map.Map<Nat, OldPendingMatch>;
    pools                  : Map.Map<Types.MarketId, OldPool>;
  }) : {
    pools : Map.Map<Types.MarketId, AMM.Pool>;
  } {
    // The five fossils: consumed by the domain, absent from the codomain —
    // explicit EOP drops (empty / initial on every live target, see header;
    // the transform must not depend on that, so nothing here reads them).
    let swept = Map.empty<Types.MarketId, AMM.Pool>();
    for ((id, p) in Map.entries(old.pools)) {
      Map.add(swept, Text.compare, id, sweepPool(p));
    };
    { pools = swept };
  };
};
