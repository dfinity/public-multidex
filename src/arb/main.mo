// Arbitrage canister — the simulated cross-venue arbitrageur.
//
// WHY THIS EXISTS (docs/amm-vault-design.md §"The missing arbitrageur"):
// MULTI/DEX trades SYNTHETIC assets, so there is no real external venue and no
// real arbitrageur. On Uniswap, when the pool price diverges from the wider
// market, arbitrageurs move assets between venues until it converges — that
// external force is what lets a passive AMM hold quotes at fair value and wait.
// Here, nothing plays that role: bots can push the venue price away from the
// oracle mark and the vault's AMM (which by design never quotes across the
// mark) can only widen and wait. This canister simulates the missing force:
//
//   • venue price RICH  (best bid > mark + band): "import" base from the
//     external world at the mark (extMarketSwap #importBase — the DEX mints
//     the base and burns our ICPUSD at mark + haircut, exactly a bridge
//     deposit's Σ-semantics), then SELL it into the rich bids.
//   • venue price CHEAP (best ask < mark − band): BUY the cheap asks on the
//     venue, then "export" the base at the mark (#exportBase).
//
// Both venue legs go through the ORDINARY taker path — staged, anti-sniped,
// fee-bearing, no matching privileges — as short-TTL limit orders pinned just
// beyond the mark, so this canister can never trade WITH the vault's AMM
// (whose quotes never cross the mark) and never worsens a fair price. Its
// profit comes exclusively from whoever pushed the price off the mark, which
// makes manipulation a taxed activity rather than a free one.
//
// SAFETY: the DEX side enforces the real guarantees (wired-principal-only
// exchange, mark freshness + no pending circuit-breaker jump, per-call and
// hourly caps, external-flow accounting). This side is deliberately dumb —
// bounded sizes, stand down when the mark is stale, flatten inventory every
// tick, and every action is queryable (getStatus) for the ops surface.

import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Option "mo:core/Option";
import Runtime "mo:core/Runtime";
import Error "mo:core/Error";
import Cycles "mo:core/Cycles";
import Fixed "../backend/lib/Fixed";

persistent actor Arb {

  // ── Tunables (transient: re-read from source on every upgrade) ──────
  transient let TICK_NS       : Int = 5_000_000_000;   // decision cadence
  transient let FRESH_MAX_NS  : Int = 45_000_000_000;  // stand down past this mark age
  transient let BAND_BPS      : Nat = 50;   // act only when |venue − mark| exceeds this
  transient let EDGE_BPS      : Nat = 20;   // rest our limit this far beyond the mark
  // Scaled with the vault: a $5.125M AMM is 5.125x the old $1M, so a 50bps
  // deviation is 5.125x the value to absorb. Holding the clip at $2k would
  // leave the arb permanently behind the mark on a production-scale venue.
  // W4-08: MUST NOT exceed the DEX's ARB_MAX_SWAP_USD ($5k, main.mo) — the
  // flatten step goes through extMarketSwap, which refuses anything above
  // that cap, while the cheap-side buy goes through the ordinary limit path
  // with no such cap. At the old $10.25k one fully-filled buy left the arb
  // holding inventory its only exit refused, retrying every 5s until the
  // mark happened to decline. test_deploy_hygiene §6h pins arb ≤ DEX.
  transient let TRADE_CAP_USD : Nat = 500_000_000_000; // $5k per market per tick (= DEX per-call cap)
  transient let DUST_USD      : Nat = 500_000_000;     // ignore base positions under $5
  // W4-25: STRICTLY under TICK_NS (5s). At the old 8s a still-live hedge
  // straddled the next tick's flatten: resting spot orders hold no
  // reservation on the DEX, so the flatten exported the very base backing
  // the live sell — the unfilled-hedge case became the NORMAL case, and a
  // late fill hit an unfunded maker. At 4s the remnant is provably dead
  // before the next flatten reads availBase. test_deploy_hygiene §6h′ pins
  // TTL < tick.
  transient let ORDER_TTL_SEC : Nat = 4;    // venue remnants self-expire before the next tick

  // ── Wiring & state ──────────────────────────────────────────────────
  var dexPrincipal : ?Principal = null;

  // Default wiring: read the DEX's id from our own canister settings —
  // `icp deploy` injects PUBLIC_CANISTER_ID:backend into every project
  // canister, correct per environment (icp-cli pitfall 22). setDex stays as
  // a break-glass override and wins when set (tests wire mock DEXes); the
  // env fallback means a fresh install or reinstall comes up wired with no
  // deploy-script leg.
  func envDex<system>() : ?Principal {
    switch (Runtime.envVar<system>("PUBLIC_CANISTER_ID:backend")) {
      case (?t) { if (t.size() > 0 and t.size() < 64) { ?Principal.fromText(t) } else { null } };
      case null { null };
    };
  };
  // Queries lack the `system` capability envVar needs — they read this cache.
  // The initializer runs in the actor INIT context (which has the capability)
  // and re-runs on every install and upgrade, so it is warm from the first
  // block; update-path effectiveDex() calls also refresh it live.
  transient var _envDexCache : ?Principal = envDex<system>();

  func effectiveDex<system>() : ?Principal {
    switch (dexPrincipal) {
      case (?p) { ?p };
      case null { _envDexCache := envDex<system>(); _envDexCache };
    };
  };
  var enabled : Bool = false;
  var lastTickNs : Int = 0;
  transient var _inFlight : Bool = false;
  // Rolling action journal for ops (getStatus) — newest first, capped.
  var actions : [Text] = [];
  transient let ACTIONS_CAP : Nat = 40;

  func note(t : Text) {
    let stamped = Int.toText(Time.now() / 1_000_000_000) # "s " # t;
    let n = actions.size();
    let keep = if (n + 1 > ACTIONS_CAP) { ACTIONS_CAP - 1 : Nat } else { n };
    actions := Iter.toArray(Iter.concat<Text>(
      [stamped].vals(),
      Iter.take(actions.vals(), keep)));
  };

  // ── W4-25: per-market rich-side backoff ─────────────────────────────
  // Every unwound import is a bounded round-trip loss (the DEX refunds the
  // BUDGET on a zero-fill round-trip, but the ~20bps haircut is gone), and a
  // spoofer can force one per tick at near-zero cost. Backing the RICH side
  // of the affected market off geometrically bounds the sustained bleed to
  // a few cycles per hold-cap (≈$100/hour across 4 markets at the 21-min
  // cap) without touching spoof-free markets, the cheap side, or the
  // flatten leg. The streak clears when a cycle's hedge mostly fills (the
  // spoofer paid the tax — resets are PAID, not free) and escalates while
  // round-trips repeat. Transient: an upgrade forgives the hold — the
  // conservative direction for availability, and the streak rebuilds in one
  // spoofed cycle anyway.
  transient let BACKOFF_BASE_NS : Int = 10_000_000_000;   // 10s; ×2 per streak
  transient let BACKOFF_MAX_EXP : Nat = 7;                // cap 10s·2⁷ = 1280s ≈ 21 min
  transient let IMPORT_MEMO_NS  : Int = 25_000_000_000;   // covers the flatten a few ticks late
  transient var _richStreak    : Map.Map<Text, Nat> = Map.empty();
  transient var _richHoldUntil : Map.Map<Text, Int> = Map.empty();
  transient var _lastImport    : Map.Map<Text, (Nat, Int)> = Map.empty();  // token → (qty, ns)

  func richHeld(marketId : Text, now : Int) : Bool {
    switch (Map.get(_richHoldUntil, Text.compare, marketId)) {
      case (?h) { now < h };
      case null { false };
    };
  };
  func richBackoff(marketId : Text, now : Int) {
    let s = Option.get(Map.get(_richStreak, Text.compare, marketId), 0) + 1;
    Map.add(_richStreak, Text.compare, marketId, s);
    let mult : Int = 2 ** Nat.min(s - 1 : Nat, BACKOFF_MAX_EXP);
    let holdNs = BACKOFF_BASE_NS * mult;
    Map.add(_richHoldUntil, Text.compare, marketId, now + holdNs);
    note("rich backoff (" # marketId # "): streak " # Nat.toText(s)
      # ", holding " # Int.toText(holdNs / 1_000_000_000) # "s");
  };
  func richClear(marketId : Text) {
    ignore Map.delete(_richStreak, Text.compare, marketId);
    ignore Map.delete(_richHoldUntil, Text.compare, marketId);
  };
  // Flatten-side verdict on the last import: did its hedge trade?
  //   #roundTrip — >50% of the imported base is being exported back: the
  //                cycle was spoof-dominated (bump the backoff).
  //   #filled    — ≤50% remains: the hedge mostly filled; whoever pushed the
  //                price paid the tax (clear the streak).
  //   #none      — no recent import to judge.
  func importVerdict(token : Text, availBase : Nat, now : Int) : { #roundTrip; #filled; #none } {
    switch (Map.get(_lastImport, Text.compare, token)) {
      case (?(qty, ns)) {
        if (now - ns > IMPORT_MEMO_NS) { ignore Map.delete(_lastImport, Text.compare, token); return #none };
        ignore Map.delete(_lastImport, Text.compare, token);   // single verdict per import
        if (availBase * 2 > qty) { #roundTrip } else { #filled };
      };
      case null { #none };
    };
  };

  // Break-glass: un-stick a market a false-positive backoff parked (ops),
  // and the deterministic reset the integration suite runs between cases.
  public shared (msg) func resetBackoff() : async () {
    requireController(msg.caller);
    Map.clear(_richStreak);
    Map.clear(_richHoldUntil);
    Map.clear(_lastImport);
    note("backoff state reset");
  };

  // Narrow views of the DEX's types: Candid decodes a wider record into these
  // (record subtyping), so the backend can evolve without breaking us.
  type PoolView = {
    marketId : Text;
    baseToken : Text;
    refPrice : Nat;
    refPriceUpdatedNs : Int;
    enabled : Bool;
  };
  type Level = { price : Nat; quantity : Nat };
  type Depth = { asks : [Level]; bids : [Level] };
  type Dex = actor {
    getAmmPools : query () -> async [PoolView];
    getOrderBookDepth : query (Text, ?Nat) -> async Depth;
    // W4-24: funded takeable depth — raw book depth is free to fake (resting
    // orders hold no reservation), and sizing the import off it was the
    // enabler for the R5(b) spoof. Sizes come from THIS now; the raw top-of-
    // book price remains the deviation SIGNAL (genuine information).
    getTakeableDepth : query (Text, { #buy; #sell }, Nat) -> async Nat;
    getBalance : query (Text) -> async Nat;
    getMyAvailableBalance : query (Text) -> async Nat;
    placeLimitOrderExp : (Text, { #buy; #sell }, Nat, Nat, ?Nat) -> async { #ok : {}; #err : Text };
    extMarketSwap : (Text, { #importBase; #exportBase }, Nat, ?Nat) -> async { #ok : Nat; #err : Text };
  };

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  // ── Admin wiring ────────────────────────────────────────────────────
  func cachedDex() : ?Principal {
    switch (dexPrincipal) { case (?p) { ?p }; case null { _envDexCache } };
  };
  public shared (msg) func setDex(p : Principal) : async () {
    requireController(msg.caller);
    dexPrincipal := ?p;
  };
  public query func getDex() : async ?Principal { cachedDex() };

  public shared (msg) func setEnabled(on : Bool) : async () {
    requireController(msg.caller);
    enabled := on;
    note(if on "enabled" else "disabled");
  };

  public query func getStatus() : async {
    enabled : Bool;
    dex : ?Principal;
    lastTickNs : Int;
    bandBps : Nat;
    edgeBps : Nat;
    tradeCapUsd : Nat;
    recentActions : [Text];
  } {
    {
      enabled; dex = cachedDex(); lastTickNs;
      bandBps = BAND_BPS; edgeBps = EDGE_BPS; tradeCapUsd = TRADE_CAP_USD;
      recentActions = actions;
    };
  };

  // DEX-side fuel watermark support (same opt-in as the Bridge).
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // ── The tick ────────────────────────────────────────────────────────
  system func heartbeat() : async () {
    if (not enabled or _inFlight) { return };
    let now = Time.now();
    if (now - lastTickNs < TICK_NS) { return };
    lastTickNs := now;
    _inFlight := true;
    try { ignore await runTick() } catch (_) {};
    _inFlight := false;
  };

  // Manual, controller-driven tick — the deterministic path integration tests
  // use (they pause nothing here; they simply call this instead of waiting).
  public shared (msg) func tickOnce() : async Text {
    requireController(msg.caller);
    if (_inFlight) { return "busy" };
    _inFlight := true;
    let r = try { await runTick() } catch (e) { "tick failed: " # Error.message(e) };
    _inFlight := false;
    r;
  };

  func bpsUp(x : Nat, bps : Nat) : Nat { Fixed.mulDiv(x, 10_000 + bps, 10_000, true) };
  func bpsDn(x : Nat, bps : Nat) : Nat { Fixed.mulDiv(x, 10_000 - bps, 10_000, false) };

  func runTick() : async Text {
    let dexP = switch (effectiveDex<system>()) { case (?p) { p }; case null { return "unwired" } };
    let dex : Dex = actor (Principal.toText(dexP));
    var summary = "";
    let pools = await dex.getAmmPools();
    for (pool in pools.vals()) {
      if (pool.enabled and pool.refPrice > 0) {
        let mark = pool.refPrice;
        // W4-17: clock read PER MARKET — one capture before the loop made the
        // staleness guard loosest exactly where the data was oldest (each
        // earlier market's awaits age the later markets' test).
        let now = Time.now();
        let ageNs = now - pool.refPriceUpdatedNs;
        if (pool.refPriceUpdatedNs > 0 and ageNs <= FRESH_MAX_NS) {
          let token = pool.baseToken;

          // 1. FLATTEN — export any base sitting in our account (last tick's
          // cheap-side buys, or a rich-side import whose sell didn't fill).
          // Realizing through the external market is where cheap-side profit
          // lands; leftovers cost the haircut, bounded by the per-tick cap.
          let availBase = await dex.getMyAvailableBalance(token);
          // W4-25: judge the previous rich cycle by what the flatten sees —
          // base mostly gone means the hedge filled (clear the backoff
          // streak); base mostly back means a zero-fill round-trip (the
          // cancel-after-rest spoof — bump it, after the export below).
          let verdict = importVerdict(token, availBase, now);
          if (verdict == #filled) { richClear(pool.marketId) };
          if (Fixed.mul(availBase, mark, false) > DUST_USD) {
            let capBase = Fixed.mulDiv(TRADE_CAP_USD, Fixed.SCALE, mark, false);
            let q = Nat.min(availBase, capBase);
            // Bound: refuse if the DEX's mark fell >50bps below the one this
            // sizing used (W4-17 — the mark is stale across the await).
            switch (await dex.extMarketSwap(token, #exportBase, q, ?bpsDn(mark, 50))) {
              case (#ok(proceeds)) {
                note("export " # Nat.toText(q) # " " # token # " → " # Nat.toText(proceeds) # " USD"); summary #= token # ":export ";
                if (verdict == #roundTrip) { richBackoff(pool.marketId, now) };
              };
              case (#err(e)) { note("export " # token # " refused: " # e) };
            };
          };

          // 2. Read the top of book and act on a deviation beyond the band.
          let depth = await dex.getOrderBookDepth(pool.marketId, ?1);
          let richFloor  = bpsUp(mark, BAND_BPS);   // bids above this are rich
          let cheapCeil  = bpsDn(mark, BAND_BPS);   // asks below this are cheap
          let capBase = Fixed.mulDiv(TRADE_CAP_USD, Fixed.SCALE, mark, false);

          if (depth.bids.size() > 0 and depth.bids[0].price >= richFloor) {
            // RICH: import at the mark, sell into the rich bids. The sell is
            // pinned at mark + EDGE — beyond the mark (so it can never touch
            // the AMM's bid at mark − spread) but under the rich bids (so it
            // sweeps everything above it). Remnant self-expires.
            // W4-25: sit the backoff window out instead of feeding a spoofer
            // another funded cycle (see the backoff block above). The flatten
            // and cheap legs stay live; only this market's rich entry waits.
            if (not richHeld(pool.marketId, now)) {
              let sellPx = bpsUp(mark, EDGE_BPS);
              let takeable = await dex.getTakeableDepth(pool.marketId, #sell, sellPx);
              let q = Nat.min(takeable, capBase);
              if (q > 0) {
                // Bound: the import must not price above the mark this decision
                // read (+50bps tolerance) — the DEX enforces it against its
                // CURRENT mark (W4-17 items 3/4).
                switch (await dex.extMarketSwap(token, #importBase, q, ?bpsUp(mark, 50))) {
                  case (#ok(_)) {
                    Map.add(_lastImport, Text.compare, token, (q, now));
                    // W4-25 item 4: the import was justified by depth read
                    // BEFORE it committed; a spoofer cancels in that gap.
                    // Re-read — if the justifying depth is gone, export
                    // straight back (the DEX refunds a zero-fill round-trip's
                    // budget charge) instead of resting a hedge that cannot
                    // fill and carrying the exposure for a tick.
                    let takeable2 = await dex.getTakeableDepth(pool.marketId, #sell, sellPx);
                    if (takeable2 == 0) {
                      note("rich: takeable depth vanished after the import (" # token # ") — unwinding the import in-tick");
                      switch (await dex.extMarketSwap(token, #exportBase, q, ?bpsDn(mark, 50))) {
                        case (#ok(p2)) { note("unwound " # Nat.toText(q) # " " # token # " → " # Nat.toText(p2) # " USD") };
                        case (#err(e2)) { note("UNWIND REFUSED (" # token # "): " # e2 # " — flatten leg picks it up next tick") };
                      };
                      ignore Map.delete(_lastImport, Text.compare, token);   // verdict rendered here
                      richBackoff(pool.marketId, now);
                      summary #= token # ":spoofed ";
                    } else {
                      switch (await dex.placeLimitOrderExp(pool.marketId, #sell, sellPx, q, ?ORDER_TTL_SEC)) {
                        case (#ok(_)) { note("rich: imported+selling " # Nat.toText(q) # " " # token # " (bid " # Nat.toText(depth.bids[0].price) # " > mark " # Nat.toText(mark) # ")"); summary #= token # ":rich "; };
                        case (#err(e)) {
                          // W4-17 item 2: the import committed value; a refused
                          // hedge used to fall through with NO compensating
                          // action, leaving the position unhedged until (at
                          // best) next tick's flatten. UNWIND: export straight
                          // back. Costs the round-trip haircut — bounded, logged
                          // — instead of open exposure on a moving mark.
                          note("rich sell refused (" # token # "): " # e # " — unwinding the import");
                          switch (await dex.extMarketSwap(token, #exportBase, q, ?bpsDn(mark, 50))) {
                            case (#ok(p2)) { note("unwound " # Nat.toText(q) # " " # token # " → " # Nat.toText(p2) # " USD") };
                            case (#err(e2)) { note("UNWIND REFUSED (" # token # "): " # e2 # " — flatten leg picks it up next tick") };
                          };
                          ignore Map.delete(_lastImport, Text.compare, token);   // verdict rendered here
                          richBackoff(pool.marketId, now);
                        };
                      };
                    };
                  };
                  case (#err(e)) { note("import refused (" # token # "): " # e) };
                };
              };
            };
          } else if (depth.asks.size() > 0 and depth.asks[0].price <= cheapCeil) {
            // CHEAP: buy the cheap asks (pinned at mark − EDGE, so we never
            // lift the AMM's ask at mark + spread); the flatten step of the
            // NEXT tick exports the fill at the mark.
            let affordable = await dex.getMyAvailableBalance("ICPUSD");
            let limitPx = bpsDn(mark, EDGE_BPS);
            // Reserve headroom: cost rounds up + taker fee ≤ 10 bp.
            let maxByCash = Fixed.mulDiv(bpsDn(affordable, 20), Fixed.SCALE, limitPx, false);
            let takeable = await dex.getTakeableDepth(pool.marketId, #buy, limitPx);
            let q = Nat.min(Nat.min(takeable, capBase), maxByCash);
            if (q > 0) {
              switch (await dex.placeLimitOrderExp(pool.marketId, #buy, limitPx, q, ?ORDER_TTL_SEC)) {
                case (#ok(_)) { note("cheap: buying " # Nat.toText(q) # " " # token # " (ask " # Nat.toText(depth.asks[0].price) # " < mark " # Nat.toText(mark) # ")"); summary #= token # ":cheap "; };
                case (#err(e)) { note("cheap buy refused (" # token # "): " # e) };
              };
            };
          };
        };
      };
    };
    if (summary == "") { "idle" } else { summary };
  };

  // Caller-only spam gate (same posture as the Bridge): controllers and any
  // non-anonymous principal may reach the queries; updates self-enforce.
  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
