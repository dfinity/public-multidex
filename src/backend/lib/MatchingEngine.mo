import Map "mo:core/Map";
import Option "mo:core/Option";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Fixed "Fixed";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Types "Types";
import OrderBook "OrderBook";
import Accounts "Accounts";
import SafeMath "SafeMath";

module {

  // ── Settlement-window callbacks for protection-aware matching ──
  // Main.mo owns the pending-match ledger (out-of-band from the engine so
  // that this module stays storage-agnostic). These callbacks let the
  // engine ask "is this maker protected? how much of its remaining is
  // locked by pending matches?" and notify main.mo when a fill should be
  // deferred rather than settled immediately.
  public type ProtectionCtx = {
    // Returns the maker's settlement-window duration in nanoseconds.
    // 0 = not protected, fill immediately (legacy behaviour).
    getMakerWindow : Nat -> Nat;
    // Returns the quantity of this maker's order already locked in pending
    // matches. The engine subtracts this from `remaining` to find what's
    // actually available to match against.
    getMakerPending : Nat -> Nat;
    // Spendable balance — must subtract whatever's reserved for in-flight
    // pending matches AND any hard-locked margin collateral. Used by the
    // engine for both taker- and maker-affordability checks so a fill
    // can't dip into locked collateral. Settlement (subtractBalance) still
    // touches raw balance, which is correct because availability is
    // checked first.
    availableBalance : (Principal, Types.TokenId) -> Nat;
    // True when a maker order must NOT be taken by an incoming taker — the
    // AMM's quotes are indicative, not firm. The (limit) matcher SKIPS such
    // makers so the taker rests instead; the AMM fills resting orders itself
    // on its next requote, at its fresh price. Defaults false (legacy).
    isNonTakeable : (makerOrderId : Nat, makerOwner : Principal) -> Bool;
    // W4-22 (R2): the AMM sweep re-submits a USER's resting order as the
    // AGGRESSOR so it fills at the AMM's equal-or-better price — a price
    // mechanic, not a role change. With this true the aggressor is fee-rated
    // AND volume-attributed as MAKER (their order was resting; the venue
    // chose to re-home it): the fee role maps taker→maker on the aggressor
    // leg only, and the engine pre-reserves the aggressor's order id so its
    // trades carry it (attribution keys off a non-zero id). Resting sides
    // keep their own roles. Safe by construction: reservations are sized at
    // the taker worst case, so maker-rating never under-reserves. Only the
    // sweep sets this; every other caller passes false.
    aggressorIsMaker : Bool;
    // W4-24 (R5(c)): the graceful unfunded-maker cancel used to be SILENT —
    // inconsistent with cancelPoolRestingOrder and cancelSelfMaker, both
    // documented "NEVER silent". The engine reports each such cancel here;
    // main records a release-rejection notice for the owner.
    onUnfundedMaker : (marketId : Types.MarketId, owner : Principal, side : Types.Side, price : Nat, qty : Nat) -> ();
    // True when a maker order has passed its orderExpiresDate. Expired orders
    // are skipped by the matcher (never filled) and swept off the book by the
    // maintenance heartbeat. Used to tie AMM quotes to oracle freshness: when
    // the oracle can't price an asset, the AMM's quotes expire and the book
    // visibly empties (liquidity withdrawn). Defaults false (no expiry).
    isExpired : (makerOrderId : Nat) -> Bool;
    // Called by the engine when it decides to defer a fill. main.mo
    // reserves the taker's debit amount, records the PendingMatch, and
    // updates its pending-qty index. The engine does NOT transfer
    // balances, call fillOrder, or recordTrade for this fill.
    //
    // Returns the created PendingMatch so the engine can surface it on
    // MatchResult.pendingMatches (lets the frontend distinguish "didn't
    // fill" from "deferred until the protection window expires"). Returns
    // null when the callback declined to record (e.g. insufficient
    // balance after the engine's own checks — rare).
    onPendingFill : (makerOrderId : Nat, makerOwner : Principal,
                     takerOwner : Principal, takerSide : Types.Side,
                     takerOrderType : Types.OrderType,
                     fillQty : Nat, price : Nat) -> ?Types.PendingMatch;
    // Symmetric maker/taker trading fee. PURE: given the gross quote notional of
    // a fill leg and the party's ROLE on that leg, returns the FEE amount (0 if
    // the party is internal — AMM/insurance/treasury; margin pools are fee-bearing
    // — exempt on BOTH the debit and credit side). The ENGINE applies the sign: it ADDS the fee to the
    // buyer's quote debit and SUBTRACTS it from the seller's quote credit. The
    // rate is keyed off maker(resting) vs taker(incoming), not buy/sell. The
    // engine never names the treasury or the rate. REQUIRED (no default) so a
    // missed ctx literal is a build error, not a silent zero-fee leak.
    quoteFee : (party : Principal, gross : Nat,
                role : { #takerDebit; #takerCredit; #makerDebit; #makerCredit }) -> Nat;
    // Skim the combined fee (buyerFee + sellerFee) to the treasury, ONCE per
    // settled fill, called only AFTER both balance legs subtract successfully —
    // so a rolled-back fill never leaves a phantom treasury credit. REQUIRED.
    creditTreasury : (fee : Nat) -> ();
    // Self-trade prevention: the engine calls this when an incoming taker would
    // fill its OWN resting maker order (same BENEFICIAL owner — see
    // beneficialOwner below; a margin pool counts as its owner). main.mo cancels the
    // resting self-maker and runs the cleanup (release reservation, deleverage a
    // pool, notice the user); the engine then skips that maker. Keeps a user from
    // washing against itself (volume/candle pollution) and from cheaply forcing
    // self-matching work (a DOS path). REQUIRED.
    onSelfTrade : (makerOrderId : Nat, makerOwner : Principal) -> ();
    // Resolve a principal to the party that actually BENEFITS from its trades:
    // a margin pool's derived principal maps to the pool's owner, everything
    // else maps to itself. Self-trade prevention compares THESE, not the raw
    // principals — a pool is a sub-account, so a wallet crossing its own pool
    // is one party on both sides of the print however different the two
    // principals look. REQUIRED.
    beneficialOwner : (Principal) -> Principal;
    // Per-trade fee attribution (MM program P1): called once per settled fill,
    // right after recordTrade, with the trade id and both parties' quote-leg
    // fees — so a bot can reconcile PnL to the penny without the archive fold
    // (getMyTradesSinceId joins these). REQUIRED so a missed ctx is a build
    // error, not a silent hole in every maker's fee statement.
    onTradeFees : (tradeId : Nat, buyerFee : Nat, sellerFee : Nat) -> ();
  };

  // A no-op ProtectionCtx — legacy callers pass this to preserve the old
  // immediate-settlement semantics without having to know about pending
  // matches. availableBalance falls back to raw Accounts.getBalance —
  // safe in test code but should NOT be used in main.mo, where the real
  // ctx must subtract reserved + locked. (The actor wires both at the
  // call site; this default exists only so unrelated tests can build a
  // legacy ctx without bookkeeping plumbing.)
  public func unprotected(accounts : Accounts.AccountState) : ProtectionCtx = {
    getMakerWindow   = func(_) { 0 };
    getMakerPending  = func(_) { 0 };
    availableBalance = func(p, t) { Accounts.getBalance(accounts, p, t) };
    isNonTakeable    = func(_, _) { false };
    aggressorIsMaker = false;
    onUnfundedMaker  = func(_, _, _, _, _) {};
    isExpired        = func(_) { false };
    onPendingFill    = func(_, _, _, _, _, _, _) { null };
    quoteFee         = func(_, _, _) { 0 };   // legacy/test: no fee
    creditTreasury   = func(_) {};
    onSelfTrade      = func(_, _) {};          // test ctx: engine still skips the self-cross
    // Legacy/test: no pool registry to consult, so every principal is its own
    // beneficiary — which reduces STP to the raw comparison this ctx has
    // always done. main.mo passes the real resolver.
    beneficialOwner  = func(p) { p };
    onTradeFees      = func(_, _, _) {};       // legacy/test: nothing to attribute
  };

  // ── Per-call work bounds ───────────────────────────────────────
  // One matcher invocation consumes at most this many match-loop iterations,
  // counting EVERY iteration — fills and skips alike, since a skipped maker
  // (non-takeable AMM quote, expired, self-cross, pending-locked, unaffordable)
  // costs a book re-walk too. This is the hard per-message bound on matcher
  // work: with the level index keyed by (timestamp, id) each iteration is
  // O(log book + excluded-set), so a capped call is bounded by construction
  // no matter how many orders rest at one price. Uncapped, a single taker
  // sweeping a stacked level was the same O(K²) shape that trapped
  // processDeferredExpiry at ~3k same-price orders (40B instruction limit).
  // On cap-out: a #market taker returns its remainder to the caller (IOC —
  // re-defer or drop, the existing semantics); a #limit taker rests it.
  public let MAX_MATCH_ITERATIONS_PER_CALL : Nat = 256;
  // The noPartialFill (FOK) pre-check promises only what fits in HALF the
  // iteration budget of distinct makers. The live loop spends at most 2
  // iterations per maker the simulation examined (a partially pending-locked
  // maker is touched twice: fill, then exhaust on the re-find), so a promise
  // built from ≤128 makers always completes within the 256-iteration cap —
  // an FOK must never pass its pre-check and then stop short on iterations.
  // Practical meaning: an all-or-nothing order can sweep at most 128 distinct
  // resting makers; larger jobs are killed at the pre-check, not partially
  // filled.
  public let FOK_SIM_MAKER_BUDGET : Nat = 128;

  public type MatchResult = {
    trades : [Types.Trade];
    // Pending matches created during this call (only non-empty when one
    // or more crossings hit a protected maker — typically an AMM quote).
    // Each entry represents reserved-but-not-yet-settled value; the
    // frontend should treat these as "settling in ~5s" and poll
    // getMyPendingMatches for the eventual finalisation.
    pendingMatches : [Types.PendingMatch];
    remainingQty : Nat;
    totalFilled : Nat;
    avgPrice : Nat;
    affectedUsers : [Principal]; // users whose orders may need adjustment
    // QUOTE the #buy taker committed this call: tradeCost + its taker fee,
    // summed over immediate settlements AND deferred (pending) slices — i.e.
    // exactly what draws down a maxQuoteSpend budget. 0 for #sell takers
    // (their quote leg is a credit). Lets budget-passing callers judge
    // "budget spent" truthfully instead of reconstructing it from
    // totalFilled×avgPrice (floored) — remainingQty > 0 with the budget
    // exhausted is a COMPLETE conversion, not a partial fill.
    quoteSpent : Nat;
  };

  // Execute a market order against resting orders on the book
  // If noPartialFill is true, pre-checks that full quantity can be filled within slippage
  // Legacy signature (no protection). Delegates to the protection-aware
  // variant with a no-op ProtectionCtx.
  public func executeMarketOrder(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    taker : Principal,
    side : Types.Side,
    quantity : Nat,
    maxSlippage : Nat,
    noPartialFill : Bool,
    timestamp : Int,
  ) : MatchResult {
    executeMarketOrderProtected(
      store, accounts, marketId, baseToken, taker, side, quantity,
      maxSlippage, noPartialFill, timestamp, unprotected(accounts), null,
    );
  };

  // Protection-aware market-order execution. When the best maker has a
  // non-zero settlement window, the fill is deferred via onPendingFill
  // (the taker's slice is consumed but no trade settles; main.mo reserves
  // the debit). Price-time priority is preserved: if a protected maker is
  // fully locked by pending matches, matching stops rather than skipping
  // to a worse-priced maker.
  //
  // `settleTs` stamps every trade this call records — pass the SETTLEMENT
  // time (when this execution actually runs), NEVER the order's submission
  // time. A staged/deferred release that passed its park-time here was
  // minting trades born 15s old: the Trades feed read permanently stale on
  // users-only markets, and fills landed in already-closed candle buckets.
  //
  // `maxQuoteSpend` (#buy takers only; ignored for #sell): a QUOTE budget —
  // tradeCost PLUS the taker's fee, exactly the debit shape settlement
  // charges — that the fill walk must never exceed. The fill loop already
  // haircuts fillQty by the taker's whole available balance; the budget
  // applies the SAME shrink against min(balance, remainingBudget), so a
  // caller can size its quantity at the BEST price (full conversion on a
  // flat book) while the walk stops exactly at the budget on a walking
  // book — no residual, no overspend. null keeps the legacy semantics
  // (bounded only by the taker's whole available balance). Composes with
  // noPartialFill: the FOK pre-check simulates with the same budget clamp,
  // so a budget the full quantity cannot fit in kills rather than
  // partial-fills.
  public func executeMarketOrderProtected(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    taker : Principal,
    side : Types.Side,
    quantity : Nat,
    maxSlippage : Nat,
    noPartialFill : Bool,
    settleTs : Int,
    ctx : ProtectionCtx,
    maxQuoteSpend : ?Nat,
  ) : MatchResult {
    let refPrice = switch (OrderBook.findBestMatch(store, marketId, side)) {
      case null { return { trades = []; pendingMatches = []; remainingQty = quantity; totalFilled = 0; avgPrice = 0; affectedUsers = []; quoteSpent = 0 } };
      case (?best) { best.price };
    };

    // Slippage band at 10^8: maxSlippage 0.10 = 10_000_000. Cap rounds DOWN,
    // floor rounds UP → both tighten the band (more protective for the taker).
    let maxPrice = Fixed.mul(refPrice, Fixed.SCALE + maxSlippage, false);
    let minPrice = if (maxSlippage >= Fixed.SCALE) { 0 } else { Fixed.mul(refPrice, Fixed.SCALE - maxSlippage, true) };

    // noPartialFill pre-check: simulate to see if full fill is possible.
    // Pending locks are counted against availability — a locked slice can't
    // serve another taker even though the maker looks "open" in the book.
    if (noPartialFill) {
      let availableQty = simulateAvailableFill(store, accounts, marketId, baseToken, taker, side, quantity, maxPrice, minPrice, ctx, maxQuoteSpend);
      if (availableQty < quantity) {
        return { trades = []; pendingMatches = []; remainingQty = quantity; totalFilled = 0; avgPrice = 0; affectedUsers = []; quoteSpent = 0 };
      };
    };

    var remainingQty = quantity;
    var totalFilled : Nat = 0;
    var totalCost : Nat = 0;
    // #buy quote budget (see maxQuoteSpend above). Drawn down by
    // tradeCost + takerFee on every slice the taker commits — immediate
    // settlements and deferred (pending) reservations alike, since a
    // pending slice reserves exactly that inflated debit.
    var remainingBudget : ?Nat = switch (side) { case (#buy) { maxQuoteSpend }; case (#sell) { null } };
    var quoteSpent : Nat = 0;
    let tradeList = List.empty<Types.Trade>();
    let pendingList = List.empty<Types.PendingMatch>();
    let affectedSet = Map.empty<Text, Principal>();
    // Makers whose entire remaining is locked by in-flight pending matches.
    // We can't match against them again until those pendings finalise or
    // void, so we skip them on subsequent iterations and advance to the
    // next-best maker. Without this the loop would re-pick the same maker
    // forever — its order is still `#open` because the pending hasn't
    // settled — and break with `availableForFill < eps`.
    let exhausted = Map.empty<Nat, Bool>();

    // Per-call work bound — see MAX_MATCH_ITERATIONS_PER_CALL. Counted at the
    // top so every path through the body (fill, skip-continue, cancel-continue)
    // spends exactly one unit.
    var iterations : Nat = 0;

    label matchLoop while (remainingQty > 0 and iterations < MAX_MATCH_ITERATIONS_PER_CALL) {
      iterations += 1;
      let best = switch (OrderBook.findBestMatchExcluding(store, marketId, side, ?exhausted)) {
        case null { break matchLoop };
        case (?b) { b };
      };

      let withinSlippage = switch (side) {
        case (#buy) { best.price <= maxPrice };
        case (#sell) { best.price >= minPrice };
      };
      if (not withinSlippage) { break matchLoop };

      // Indicative (AMM) makers are not takeable by market orders either: skip
      // so the taker walks past them. A market taker is IOC — it never rests;
      // main.mo re-defers an unfilled spot remainder to the next requote (it
      // walks the reskewed AMM curve, MAX_REDEFER-capped, then drops). Only a
      // crossing LIMIT taker rests for the AMM to sweep at its fresh price.
      if (ctx.isNonTakeable(best.id, best.owner)) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };
      // Expired makers are never filled — skip past them (the maintenance
      // heartbeat sweeps them off the book).
      if (ctx.isExpired(best.id)) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      // Self-trade prevention: a taker must never fill its OWN resting order —
      // compared on the BENEFICIAL owner, so a wallet cannot cross its own
      // margin pool (different principals, one beneficiary).
      // main.mo cancels the resting self-maker (cleanup + user notice); we skip
      // it here. Runs BEFORE any settlement/fee, so a self-cross never washes
      // volume, never pays a fee, and never consumes free self-matching work (DOS).
      if (Principal.equal(ctx.beneficialOwner(taker), ctx.beneficialOwner(best.owner))) {
        ctx.onSelfTrade(best.id, best.owner);
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      // Reserve-aware availability: a protected maker may have part of its
      // remaining quantity locked by earlier pending matches. If the
      // entire remaining is locked, mark this maker as exhausted and
      // continue — findBestMatchExcluding will return the next-best on
      // the next iteration. The previous behaviour broke here on the
      // grounds of "price-time priority", which doesn't apply because
      // this maker has no inventory available to match against.
      let pendingLocked = ctx.getMakerPending(best.id);
      let makerRemaining = OrderBook.remaining(best);
      let availableForFill = SafeMath.subOrZero(makerRemaining, pendingLocked);
      if (availableForFill == 0) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      var fillQty = Nat.min(remainingQty, availableForFill);

      // Verify maker has enough AVAILABLE balance — committed margin
      // collateral and pending-match reservations are excluded.
      let makerBal = switch (side) {
        case (#buy) { ctx.availableBalance(best.owner, baseToken) };
        case (#sell) { ctx.availableBalance(best.owner, Types.QUOTE_TOKEN) };
      };
      // On a #sell fill the maker (best.owner) is the BUYER, so its QUOTE balance
      // must cover the trade cost PLUS its maker fee.
      let makerNeeds = switch (side) {
        case (#buy) { fillQty };
        case (#sell) { let b = Fixed.mul(fillQty, best.price, true); b + ctx.quoteFee(best.owner, b, #makerDebit) };
      };

      if (makerBal < makerNeeds) {
        ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
        ignore OrderBook.cancelOrder(store, best.id);
        continue matchLoop;
      };

      // Verify taker has enough AVAILABLE balance (same exclusion). On a #buy the
      // taker is the BUYER and owes the trade cost PLUS its taker fee.
      let takerBal = switch (side) {
        case (#buy) { ctx.availableBalance(taker, Types.QUOTE_TOKEN) };
        case (#sell) { ctx.availableBalance(taker, baseToken) };
      };
      let takerNeeds = switch (side) {
        case (#buy) { let b = Fixed.mul(fillQty, best.price, true); b + ctx.quoteFee(taker, b, #takerDebit) };
        case (#sell) { fillQty };
      };

      // The taker's effective spendable quote this slice: its whole available
      // balance, further clamped by the remaining maxQuoteSpend budget (#buy
      // with a budget only — spendCap == takerBal everywhere else).
      let spendCap = switch (side, remainingBudget) {
        case (#buy, ?b) { Nat.min(takerBal, b) };
        case _ { takerBal };
      };
      if (spendCap < takerNeeds) {
        let affordableQty = switch (side) {
          case (#buy) {
            if (best.price > 0) {
              // Shrink so qty·price + takerFee(qty·price) <= spendCap. Probe the
              // taker's effective bps (TAKER, or 0 if internal) and divide the
              // affordable quote by (1 + bps/10_000) before converting to qty —
              // provably keeps cost+fee within the cap, so the fill never strands
              // (and never dips past the budget on a walking book).
              let eff = ctx.quoteFee(taker, 10_000, #takerDebit);
              Fixed.div(Fixed.mulDiv(spendCap, 10_000, 10_000 + eff, false), best.price, false)
            } else { 0 }
          };
          case (#sell) { spendCap };
        };
        if (affordableQty == 0) { break matchLoop };
        fillQty := Nat.min(fillQty, affordableQty);
      };

      // Execute the trade
      let (buyer, seller) = switch (side) {
        case (#buy) { (taker, best.owner) };
        case (#sell) { (best.owner, taker) };
      };

      let tradePrice = best.price;
      let tradeCost = Fixed.mul(fillQty, tradePrice, false);

      // Symmetric maker/taker fee, both legs in QUOTE. The incoming taker is
      // `taker`, the resting maker is best.owner; the buyer is the taker iff this
      // is a #buy. Each fee is 0 for internal principals (ctx.quoteFee exempts).
      let buyerIsTaker = (side == #buy);
      let buyerFee  = ctx.quoteFee(buyer,  tradeCost, if (buyerIsTaker) #takerDebit  else #makerDebit);
      let sellerFee = ctx.quoteFee(seller, tradeCost, if (buyerIsTaker) #makerCredit else #takerCredit);

      let window = ctx.getMakerWindow(best.id);

      if (window == 0) {
        // ── Immediate-settlement path (legacy behaviour) ─────────────
        // Symmetric fee, conservation-exact: buyer pays tradeCost+buyerFee; seller
        // receives tradeCost-sellerFee; treasury gets buyerFee+sellerFee, skimmed
        // ONCE and only after BOTH balance legs subtract — so a rolled-back fill
        // leaves no phantom treasury credit. Internal principals were fee'd 0.
        let buyerOk = Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
        if (not buyerOk) { break matchLoop };
        Accounts.addBalance(accounts, buyer, baseToken, fillQty);

        let sellerOk = Accounts.subtractBalance(accounts, seller, baseToken, fillQty);
        if (not sellerOk) {
          // Rollback buyer's inflated ICPUSD deduction (no treasury skim yet)
          Accounts.addBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
          ignore Accounts.subtractBalance(accounts, buyer, baseToken, fillQty);
          break matchLoop;
        };
        ctx.creditTreasury(buyerFee + sellerFee);
        Accounts.addBalance(accounts, seller, Types.QUOTE_TOKEN, tradeCost - sellerFee);

        ignore OrderBook.fillOrder(store, best.id, fillQty);

        let (buyOrderId, sellOrderId) = switch (side) {
          case (#buy) { (0 : Nat, best.id) };
          case (#sell) { (best.id, 0 : Nat) };
        };

        let trade = OrderBook.recordTrade(store, marketId, buyOrderId, sellOrderId, buyer, seller, tradePrice, fillQty, settleTs, ?#market);
        List.add(tradeList, trade);
        ctx.onTradeFees(trade.id, buyerFee, sellerFee);

        // Track affected users for post-trade order adjustment
        Map.add(affectedSet, Text.compare, Principal.toText(buyer), buyer);
        Map.add(affectedSet, Text.compare, Principal.toText(seller), seller);

        totalFilled += fillQty;
        totalCost += tradeCost;
      } else {
        // ── Deferred-settlement path ─────────────────────────────────
        // Maker is protected; hand off to main.mo to record a PendingMatch.
        // Engine does NOT settle balances, fillOrder, or recordTrade for
        // this slice — main.mo reserves the taker's debit and tracks the
        // locked quantity via ctx.getMakerPending. The taker's quantity
        // IS consumed (decrement remainingQty) but totalFilled is not
        // bumped because nothing has immediately settled.
        // Available-balance gate so a deferred fill can't dip into the
        // taker's or maker's locked margin collateral. Buyer gate inflated by
        // buyerFee (DORMANT path; createPendingMatch reserves the same inflation).
        if (ctx.availableBalance(buyer, Types.QUOTE_TOKEN) < tradeCost + buyerFee) {
          break matchLoop;
        };
        if (ctx.availableBalance(seller, baseToken) < fillQty) {
          break matchLoop;
        };
        switch (ctx.onPendingFill(best.id, best.owner, taker, side, #market, fillQty, tradePrice)) {
          case (?pm) { List.add(pendingList, pm) };
          case null { };
        };
      };

      // This slice is committed (settled, or reserved as a pending debit):
      // on a #buy the taker's quote outlay is tradeCost + its taker fee
      // (buyer == taker here) — record it and draw down the budget. Every
      // rollback/refusal path above breaks or continues before this point.
      if (side == #buy) {
        quoteSpent += tradeCost + buyerFee;
        switch (remainingBudget) {
          case (?b) { remainingBudget := ?SafeMath.subOrZero(b, tradeCost + buyerFee) };
          case null {};
        };
      };
      remainingQty -= fillQty;
    };

    let avgPrice = if (totalFilled > 0) { Fixed.div(totalCost, totalFilled, false) } else { 0 };

    let affected = Iter.toArray(
      Iter.map<(Text, Principal), Principal>(Map.entries(affectedSet), func((_, p)) { p })
    );

    {
      trades = Iter.toArray(List.values(tradeList));
      pendingMatches = Iter.toArray(List.values(pendingList));
      remainingQty;
      totalFilled;
      avgPrice;
      affectedUsers = affected;
      quoteSpent;
    };
  };

  // Simulate how much can be filled without actually executing.
  // Uses the market-side index instead of scanning all orders.
  // Pending-match locks (ctx.getMakerPending) are subtracted from each
  // maker's remaining so the simulation doesn't count slices that are
  // already reserved for in-flight pending matches.
  func simulateAvailableFill(
    store : OrderBook.OrderStore,
    _accounts : Accounts.AccountState,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    taker : Principal,
    side : Types.Side,
    quantity : Nat,
    maxPrice : Nat,
    minPrice : Nat,
    ctx : ProtectionCtx,
    maxQuoteSpend : ?Nat,
  ) : Nat {
    var available : Nat = 0;
    var takerBal = switch (side) {
      case (#buy) { ctx.availableBalance(taker, Types.QUOTE_TOKEN) };
      case (#sell) { ctx.availableBalance(taker, baseToken) };
    };
    // The sim already models the taker's balance draw (cost + taker fee per
    // slice), so a maxQuoteSpend budget is just a tighter starting balance:
    // clamp it here and the FOK pre-check becomes budget-aware for free — a
    // full quantity the budget cannot cover kills instead of partial-filling.
    switch (side, maxQuoteSpend) {
      case (#buy, ?b) { takerBal := Nat.min(takerBal, b) };
      case _ {};
    };
    // Per-OWNER maker drawdown, so a maker's affordability accounts for depth
    // this same walk already committed against its shared balance (one owner
    // can rest several makers at a level).
    let makerDrawn = Map.empty<Text, Nat>();

    let makerSide = switch (side) { case (#buy) { #sell }; case (#sell) { #buy } };
    let msKey = OrderBook.marketSideKey(marketId, makerSide);
    let lvls = switch (Map.get(store.levelsByMarketSide, Text.compare, msKey)) {
      case null { return 0 };
      case (?m) { m };
    };

    // Walk price levels best→worst (asks ascending, bids descending) — the SAME
    // order the live match loop (findBestMatchExcluding) executes in — and sum
    // fillable depth in ONE pass: O(book) instead of the old O(book²) repeated
    // linear-argmin over the flat set. Per-order semantics are preserved: skip
    // non-takeable (AMM) / expired / pending-locked makers, count up to the
    // taker's balance, and stop at the first maker it can't afford (orders are
    // walked best-price-first, so a worse-priced maker is never cheaper).
    // Intra-level order is the (timestamp, id) key order — identical to the
    // live loop's touch order, which the maker budget below depends on: the
    // promise must be built from exactly the makers the live loop will reach
    // first.
    let levelIter = switch (makerSide) {
      case (#sell) { Map.entries(lvls) };        // lowest ask first
      case (#buy)  { Map.reverseEntries(lvls) };  // highest bid first
    };
    // FOK maker budget — see FOK_SIM_MAKER_BUDGET. Counts every OPEN maker
    // the walk reaches (skipped ones included: the live loop spends an
    // iteration excluding those too).
    var examined : Nat = 0;
    label simLoop for ((price, lvl) in levelIter) {
      // Levels are monotonic in price, so once one falls outside the slippage
      // band every worse level does too — stop scanning.
      let withinSlip = switch (side) {
        case (#buy)  { price <= maxPrice };
        case (#sell) { price >= minPrice };
      };
      if (not withinSlip) { break simLoop };

      label lvlWalk for (((_ts, id), _) in Map.entries(lvl)) {
        switch (Map.get(store.orders, Nat.compare, id)) {
          case null {};
          case (?o) {
            if (not OrderBook.isOpen(o)) { continue lvlWalk };
            // Budget check BEFORE any skip predicate: every open maker the
            // walk reaches here is one the live loop would spend an iteration
            // on (fill, or skip-and-exclude), so all of them draw the budget.
            examined += 1;
            if (examined > FOK_SIM_MAKER_BUDGET) { break simLoop };
            // Skip own resting orders (the engine's self-trade prevention does
            // too) so a noPartialFill buy isn't told it can fill against itself.
            // Same BENEFICIAL-owner comparison as the live loop — if the sim
            // counted a pool's depth that the live loop then refuses, FOK would
            // pass a pre-check and partially fill.
            if (not ctx.isNonTakeable(o.id, o.owner) and not ctx.isExpired(o.id)
                and not Principal.equal(ctx.beneficialOwner(o.owner), ctx.beneficialOwner(taker))) {
              let pendingLocked = ctx.getMakerPending(o.id);
              let obRem = OrderBook.remaining(o);
              let rem = SafeMath.subOrZero(obRem, pendingLocked);
              if (rem > 0) {
                let fillQty = Nat.min(quantity - available, rem);
                // Maker affordability. The live loop CANCELS a maker that can't
                // deliver its side of this fill (base for a maker-sell; quote +
                // maker fee for a maker-buy) and moves on — so such a maker
                // contributes ZERO depth. Modelling it keeps the noPartialFill
                // (FOK) pre-check honest: without it the sim counts an
                // unaffordable maker's depth, FOK passes, then the live cancel
                // leaves a partial fill on an all-or-nothing order.
                let mk = Principal.toText(o.owner);
                let makerRaw = switch (side) {
                  case (#buy)  { ctx.availableBalance(o.owner, baseToken) };
                  case (#sell) { ctx.availableBalance(o.owner, Types.QUOTE_TOKEN) };
                };
                let makerBal = SafeMath.subOrZero(makerRaw, Option.get(Map.get(makerDrawn, Text.compare, mk), 0));
                let makerNeeds = switch (side) {
                  case (#buy)  { fillQty };
                  case (#sell) { let b = Fixed.mul(fillQty, o.price, true); b + ctx.quoteFee(o.owner, b, #makerDebit) };
                };
                // Include the buyer fee so the FOK pre-check matches the
                // fee-inflated settlement debit (buyer pays base + taker fee).
                let cost = switch (side) {
                  case (#buy) { let b = Fixed.mul(fillQty, o.price, true); b + ctx.quoteFee(taker, b, #takerDebit) };
                  case (#sell) { fillQty };
                };
                if (makerBal < makerNeeds) {
                  // unaffordable maker → cancelled live, contributes nothing; skip
                  // it WITHOUT drawing the taker's balance (matches `continue`).
                } else if (cost <= takerBal) {
                  available += fillQty;
                  takerBal -= cost;
                  Map.add(makerDrawn, Text.compare, mk, Option.get(Map.get(makerDrawn, Text.compare, mk), 0) + makerNeeds);
                  if (available >= quantity) { break simLoop };
                } else {
                  break simLoop;
                };
              };
            };
          };
        };
      };
    };
    available;
  };

  // Try to match a new limit order against the book, then place remainder on book
  // Legacy signature (no protection). Delegates to the protection-aware
  // variant with a no-op ProtectionCtx.
  public func executeLimitOrder(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    owner : Principal,
    side : Types.Side,
    price : Nat,
    quantity : Nat,
    timestamp : Int,
  ) : (Types.Order, [Types.Trade], [Types.PendingMatch], [Principal]) {
    let (o, t, p, a, _) = executeLimitOrderProtected(
      store, accounts, marketId, baseToken, owner, side, #limit, price, quantity, timestamp, timestamp,
      unprotected(accounts), null,
    );
    (o, t, p, a);
  };

  // Protection-aware limit-order execution. For each candidate fill, asks
  // the ProtectionCtx whether the maker is protected and how much of its
  // inventory is already locked by pending matches. If the maker is
  // unprotected, behaviour is identical to the legacy engine. If the
  // maker is protected, the fill is deferred via onPendingFill; the engine
  // does NOT settle balances, update maker.filled, or recordTrade for
  // that fill — main.mo handles the reserved-ledger entry and the
  // PendingMatch record instead.
  //
  // `orderType` is the ORIGIN of the incoming taker, threaded through to the
  // created order record and each trade's takerOrderType so user history
  // reports what the user actually placed (a #market release walking the AMM
  // curve is still a MARKET order, not a limit). It also selects the
  // remainder semantics: #limit rests its leftover on the book; #market is
  // IOC — it NEVER rests, the caller re-defers or drops the remainder.
  //
  // TWO clocks, deliberately: `timestamp` is the order's SUBMISSION time and
  // stamps the created order record ("placed at" in user history); `settleTs`
  // is the SETTLEMENT time — when this execution actually runs — and stamps
  // every trade recorded here. Staged orders release seconds (users-only
  // fallback: up to ~15s) after submission; stamping their fills with the
  // submission time made the Trades feed read permanently stale and wrote
  // fills into already-closed candle buckets. Synchronous callers pass the
  // same value for both.
  //
  // `maxQuoteSpend` (#buy takers only; ignored for #sell): the market
  // variant's cost+takerFee quote budget, threaded here for the STAGED
  // direct-swap path (releaseDeferred, orderType = #market/IOC). With a
  // budget, each slice is shrunk to fit min(available balance, remaining
  // budget) — the market variant's spendCap shape — so a caller can size its
  // quantity at the BEST price while the walk stops exactly at the budget on
  // a walking book. With null the legacy semantics are UNCHANGED, including
  // the break/cancel handling of an unaffordable buyer (no shrink) — the
  // resting-#limit flow must not silently down-size fills. Pass a budget only
  // from #market releases.
  //
  // The 5th result element is quoteSpent — the #buy taker's committed quote
  // (tradeCost + its fee, immediate AND deferred slices), 0 for #sell — so a
  // budget-passing caller can re-defer its remainder with the REMAINING
  // budget and judge "budget exhausted = complete conversion" truthfully.
  public func executeLimitOrderProtected(
    store : OrderBook.OrderStore,
    accounts : Accounts.AccountState,
    marketId : Types.MarketId,
    baseToken : Types.TokenId,
    owner : Principal,
    side : Types.Side,
    orderType : Types.OrderType,
    price : Nat,
    quantity : Nat,
    timestamp : Int,
    settleTs : Int,
    ctx : ProtectionCtx,
    maxQuoteSpend : ?Nat,
  ) : (Types.Order, [Types.Trade], [Types.PendingMatch], [Principal], Nat) {
    var remainingQty = quantity;
    var totalFilled : Nat = 0;  // only IMMEDIATE fills count here
    // Quote notional of the immediate fills (Σ tradeCost, fee-exclusive) —
    // feeds the #market record's VWAP price stamp after the loop.
    var totalCost : Nat = 0;
    // #buy quote budget (see maxQuoteSpend above). Drawn down by
    // tradeCost + buyerFee on every slice the taker commits.
    var remainingBudget : ?Nat = switch (side) { case (#buy) { maxQuoteSpend }; case (#sell) { null } };
    var quoteSpent : Nat = 0;
    // W4-22: pre-reserve the aggressor's order id when the sweep re-homes a
    // resting order, so trades recorded mid-loop carry it (0 = the classic
    // "aggressor has no id yet" sentinel, unchanged for every other caller).
    // The order record is created with this id after the loop; a reserved id
    // burned by a no-fill cancel is a harmless gap (ids are already sparse
    // via the staging queue's allocateId).
    let aggressorId : Nat = if (ctx.aggressorIsMaker) { OrderBook.allocateId(store) } else { 0 };
    let tradeList = List.empty<Types.Trade>();
    let pendingList = List.empty<Types.PendingMatch>();
    let affectedSet = Map.empty<Text, Principal>();
    // Makers fully locked by in-flight pending matches — skip on subsequent
    // iterations so a deep crossing limit can still walk to the next-best
    // maker instead of returning a stub-fill. See market-side comment.
    let exhausted = Map.empty<Nat, Bool>();

    // Per-call work bound — see MAX_MATCH_ITERATIONS_PER_CALL. A capped-out
    // crossing limit rests its remainder exactly like any partial fill; the
    // rested order is immediately the side's best and later flow finishes it.
    var iterations : Nat = 0;

    label matchLoop while (remainingQty > 0 and iterations < MAX_MATCH_ITERATIONS_PER_CALL) {
      iterations += 1;
      let best = switch (OrderBook.findBestMatchExcluding(store, marketId, side, ?exhausted)) {
        case null { break matchLoop };
        case (?b) { b };
      };

      let pricesCross = switch (side) {
        case (#buy) { best.price <= price };
        case (#sell) { best.price >= price };
      };
      if (not pricesCross) { break matchLoop };

      // Indicative (AMM) makers are not takeable: skip so this taker walks
      // past them and rests the remainder at its limit. The AMM fills resting
      // orders itself on its next requote (at its fresh price). User makers
      // are unaffected — they match immediately below.
      if (ctx.isNonTakeable(best.id, best.owner)) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };
      // Expired makers are never filled — skip past them (the maintenance
      // heartbeat sweeps them off the book).
      if (ctx.isExpired(best.id)) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      // Self-trade prevention: a taker must never fill its OWN resting order —
      // on the BENEFICIAL owner, so a wallet cannot cross its own margin pool.
      // NB the incoming taker is `owner` here (the limit fn's param), not `taker`.
      // main.mo cancels the resting self-maker; we skip it. Runs BEFORE settlement
      // and BEFORE the deferred onPendingFill, so a self-cross never washes volume,
      // pays a fee, double-reserves the same principal, or does free work (DOS).
      if (Principal.equal(ctx.beneficialOwner(owner), ctx.beneficialOwner(best.owner))) {
        ctx.onSelfTrade(best.id, best.owner);
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      // How much of this maker is actually available after subtracting any
      // pending matches already locked against it.
      let pendingLocked = ctx.getMakerPending(best.id);
      let actualRemaining = OrderBook.remaining(best);
      let availableForFill = SafeMath.subOrZero(actualRemaining, pendingLocked);
      if (availableForFill == 0) {
        // Maker is fully locked — advance to next-best instead of
        // breaking. See market-side comment for the reasoning.
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      var fillQty = Nat.min(remainingQty, availableForFill);

      // maxQuoteSpend shrink — ONLY when a budget is present (#buy taker), so
      // the null path stays byte-identical (the legacy break/cancel semantics
      // below are load-bearing for resting #limit flow). Mirrors the market
      // variant's spendCap: clamp this slice so qty·price + buyerFee stays
      // within min(available balance, remaining budget); the fee role matches
      // the buyerFee computed below (aggDebit — #takerDebit for every budget
      // caller today, since only #market releases pass a budget).
      switch (remainingBudget) {
        case (?bud) {
          let takerBal = ctx.availableBalance(owner, Types.QUOTE_TOKEN);
          let spendCap = Nat.min(takerBal, bud);
          let feeRole = if (ctx.aggressorIsMaker) { #makerDebit } else { #takerDebit };
          let needs = do { let c = Fixed.mul(fillQty, best.price, true); c + ctx.quoteFee(owner, c, feeRole) };
          if (spendCap < needs) {
            let affordableQty = if (best.price > 0) {
              // Shrink so qty·price + fee(qty·price) <= spendCap: probe the
              // taker's effective bps and carve it out of the affordable quote
              // before converting to qty (floor) — provably keeps cost+fee
              // within the cap (same derivation as the market variant).
              let eff = ctx.quoteFee(owner, 10_000, feeRole);
              Fixed.div(Fixed.mulDiv(spendCap, 10_000, 10_000 + eff, false), best.price, false)
            } else { 0 };
            if (affordableQty == 0) { break matchLoop };
            fillQty := Nat.min(fillQty, affordableQty);
          };
        };
        case null {};
      };

      let (buyer, seller) = switch (side) {
        case (#buy) { (owner, best.owner) };
        case (#sell) { (best.owner, owner) };
      };
      let tradePrice = best.price;
      let tradeCost = Fixed.mul(fillQty, tradePrice, false);

      // Symmetric maker/taker fee, both legs in QUOTE. Incoming taker is `owner`,
      // resting maker is best.owner; buyer is the taker iff this is a #buy. Each
      // fee is 0 for internal principals (ctx.quoteFee exempts both sides).
      // W4-22: under aggressorIsMaker the AGGRESSOR leg is fee-rated maker —
      // the sweep's price mechanic must not decide the fee role. The resting
      // leg keeps its own role either way.
      let buyerIsTaker = (side == #buy);
      let aggDebit  = if (ctx.aggressorIsMaker) { #makerDebit }  else { #takerDebit };
      let aggCredit = if (ctx.aggressorIsMaker) { #makerCredit } else { #takerCredit };
      let buyerFee  = ctx.quoteFee(buyer,  tradeCost, if (buyerIsTaker) aggDebit  else #makerDebit);
      let sellerFee = ctx.quoteFee(seller, tradeCost, if (buyerIsTaker) #makerCredit else aggCredit);

      let window = ctx.getMakerWindow(best.id);

      if (window == 0) {
        // ── Immediate-settlement path (legacy behaviour) ─────────────
        // Buyer must cover tradeCost+buyerFee (symmetric fee). On a #sell the
        // buyer IS the resting maker (best.owner) paying the maker fee; if it can
        // no longer afford cost+fee, cancel that resting bid gracefully (the
        // self-cancel branch). On a #buy the incoming taker's staged reservation
        // was inflated to cover the fee, so this gate holds.
        if (ctx.availableBalance(buyer, Types.QUOTE_TOKEN) < tradeCost + buyerFee) {
          if (Principal.equal(buyer, best.owner)) {
            ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
            ignore OrderBook.cancelOrder(store, best.id);
            continue matchLoop;
          } else {
            break matchLoop;
          };
        };
        if (ctx.availableBalance(seller, baseToken) < fillQty) {
          if (Principal.equal(seller, best.owner)) {
            ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
            ignore OrderBook.cancelOrder(store, best.id);
            continue matchLoop;
          } else {
            break matchLoop;
          };
        };
        let buyerOk = Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
        if (not buyerOk) { break matchLoop };
        Accounts.addBalance(accounts, buyer, baseToken, fillQty);
        let sellerOk = Accounts.subtractBalance(accounts, seller, baseToken, fillQty);
        if (not sellerOk) {
          Accounts.addBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
          ignore Accounts.subtractBalance(accounts, buyer, baseToken, fillQty);
          break matchLoop;
        };
        // Skim both fees to the treasury ONCE, after both legs subtract; net the
        // seller credit. buyer_out(C+bF) == seller_net(C-sF) + treasury(bF+sF).
        ctx.creditTreasury(buyerFee + sellerFee);
        Accounts.addBalance(accounts, seller, Types.QUOTE_TOKEN, tradeCost - sellerFee);
        ignore OrderBook.fillOrder(store, best.id, fillQty);
        // W4-22: the aggressor side carries its pre-reserved id under the
        // sweep (0 for every other caller — the historical sentinel).
        let (buyOrderId, sellOrderId) = switch (side) {
          case (#buy) { (aggressorId, best.id) };
          case (#sell) { (best.id, aggressorId) };
        };
        let trade = OrderBook.recordTrade(
          store, marketId, buyOrderId, sellOrderId, buyer, seller, tradePrice, fillQty, settleTs, ?orderType
        );
        List.add(tradeList, trade);
        ctx.onTradeFees(trade.id, buyerFee, sellerFee);
        Map.add(affectedSet, Text.compare, Principal.toText(buyer), buyer);
        Map.add(affectedSet, Text.compare, Principal.toText(seller), seller);
        totalFilled += fillQty;
        totalCost += tradeCost;
      } else {
        // ── Deferred-settlement path ─────────────────────────────────
        // Validate that the taker (and maker) have enough AVAILABLE
        // balance to back this pending match. main.mo wires
        // ctx.availableBalance to subtract reserved (in-flight pendings)
        // and hard-locked margin collateral, so neither side can dip
        // into committed funds.
        // Buyer gate inflated by buyerFee (DORMANT path; createPendingMatch
        // reserves the same inflation so the later skim is fully backed).
        if (ctx.availableBalance(buyer, Types.QUOTE_TOKEN) < tradeCost + buyerFee) {
          break matchLoop;
        };
        if (ctx.availableBalance(seller, baseToken) < fillQty) {
          break matchLoop;
        };
        // Hand off to main.mo to record the pending match; it reserves
        // the taker's debit from balance → reserved and updates its
        // pending-qty index. From the engine's POV, this fillQty is
        // "consumed" for this taker order (decrement remaining) but the
        // maker's order remains open at full remaining (with the locked
        // slice tracked externally).
        switch (ctx.onPendingFill(best.id, best.owner, owner, side, orderType, fillQty, tradePrice)) {
          case (?pm) { List.add(pendingList, pm) };
          case null { };
        };
      };

      // This slice is committed (settled, or reserved as a pending debit): on
      // a #buy the taker's quote outlay is tradeCost + its buyer fee — record
      // it and draw down the budget (the market variant's shape). Every
      // rollback/refusal path above breaks or continues before this point.
      if (side == #buy) {
        quoteSpent += tradeCost + buyerFee;
        switch (remainingBudget) {
          case (?b) { remainingBudget := ?SafeMath.subOrZero(b, tradeCost + buyerFee) };
          case null {};
        };
      };
      remainingQty -= fillQty;
    };

    // Decide whether there's anything to create in the order book. Three
    // cases:
    //   (a) remainingQty > 0 (normal resting order, possibly after some
    //       immediate fills)
    //   (b) remainingQty == 0 and totalFilled > 0 (fully filled immediately —
    //       we still create a record so trade history has a concrete order
    //       id for buyOrderId/sellOrderId lookups, and the fillOrder call
    //       removes it from the open-book indexes by marking it #filled)
    //   (c) remainingQty == 0 and totalFilled == 0 (every fill went into
    //       the pending-match queue — the taker has no real book presence
    //       and pending matches reference only the maker's orderId, so a
    //       book entry would be a zombie: 0 qty, status #open, stuck in
    //       openOrdersByMarketSide. findBestMatch would return it as the
    //       "best" at its price and the matcher would break on
    //       availableForFill == 0, blocking subsequent trades at that
    //       price level. So we skip the book entirely and return a
    //       synthetic #filled record.)
    let finalOrder : Types.Order = if (orderType == #market) {
      // IOC (immediate-or-cancel): a MARKET taker never rests on the book. If
      // anything filled, record ONLY the filled portion (closed #filled at
      // creation — trade history needs a concrete order id, and Recently
      // Closed shows an honest "market — filled X"); the unfilled remainder
      // is the CALLER's to re-defer or drop. No resting → no rest→cancel
      // churn → no phantom "cancelled limit order" records per walk cycle
      // (the Calm-Bear-91 bug). The caller reads the remainder as
      // quantity_requested − finalOrder.filled.
      if (totalFilled > 0) {
        // Task 1787182538 (2026-08-20): stamp the record — and thus the
        // ClosedOrderRecord the reaper later seals from it — with the
        // VOLUME-WEIGHTED execution price of the immediate fills (floored,
        // the MatchResult.avgPrice rounding), NOT the caller's mid-clamped
        // slippage cap. The cap (`price`) still bounds the walk above; it
        // just no longer masquerades as a traded price on the tape. Rows
        // sealed before this change carry the cap — see Types.mo's
        // ClosedOrderRecord.price doc comment for the dated boundary.
        let vwap = Fixed.div(totalCost, totalFilled, false);
        let order = OrderBook.createOrder(store, marketId, owner, side, #market, vwap, totalFilled, timestamp);
        ignore OrderBook.fillOrder(store, order.id, totalFilled);
        switch (OrderBook.getOrder(store, order.id)) {
          case (?o) { o };
          case null { order };
        };
      } else {
        // Dry cycle: nothing filled, nothing recorded (id 0 never enters the
        // store, so it can't surface anywhere). Status #cancelled = "this
        // attempt is over"; the walk decides what happens to the quantity.
        {
          id = 0; marketId; owner; side; orderType = #market; price;
          quantity; filled = 0; status = #cancelled; timestamp;
          originalQuantity = quantity;
        };
      };
    } else if (remainingQty > 0 or totalFilled > 0) {
      // Create at the FULL requested size (resting remainder + immediate
      // fills), not the remainder: createOrder pins originalQuantity at
      // creation, and the closed-order reaper reports that field as the
      // "original requested quantity" (Types.ClosedOrderRecord.quantity).
      // Creating at remainingQty and up-adjusting afterwards preserved
      // originalQuantity = R, so a partially-filled-at-release limit order
      // closed with quantity = R < filled (issue #42). The level-aggregate
      // math is unchanged: create adds R+F, the partial fill below subtracts
      // F — net R resting, exactly as before.
      let requestedQty = remainingQty + totalFilled;
      let order = if (aggressorId != 0) {
        // W4-22: materialize the pre-reserved aggressor id the trades above
        // already reference.
        OrderBook.createOrderWithId(store, aggressorId, marketId, owner, side, orderType, price, requestedQty, timestamp);
      } else {
        OrderBook.createOrder(store, marketId, owner, side, orderType, price, requestedQty, timestamp);
      };
      if (totalFilled > 0) {
        ignore OrderBook.fillOrder(store, order.id, totalFilled);
      };
      switch (OrderBook.getOrder(store, order.id)) {
        case (?o) { o };
        case null { order };
      };
    } else {
      // Fully consumed by pending matches. Status = #filled signals that
      // this order will never rest or see further matching at the order
      // level; any outstanding settlement lives in the pending-match
      // ledger (queryable via getMyPendingMatches). id = 0 is the same
      // sentinel we use in Trade records for "taker side has no order id".
      {
        id               = 0;
        marketId;
        owner;
        side;
        orderType;
        price;
        quantity;
        filled           = 0;
        status           = #filled;
        timestamp;
        originalQuantity = quantity;
      };
    };

    let affected = Iter.toArray(
      Iter.map<(Text, Principal), Principal>(Map.entries(affectedSet), func((_, p)) { p })
    );

    (
      finalOrder,
      Iter.toArray(List.values(tradeList)),
      Iter.toArray(List.values(pendingList)),
      affected,
      quoteSpent,
    );
  };
};
