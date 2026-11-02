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

  // ── Callbacks for protection-aware matching ──
  // main.mo owns the ledgers (out-of-band from the engine so that this
  // module stays storage-agnostic). These callbacks let the engine ask
  // "may this maker be taken? can this party fund the slice?" and report
  // what it settled. (The settlement-window trio — getMakerWindow,
  // getMakerPending, onPendingFill — and the deferred-fill arm they fed
  // were RETIRED by task 1788516198: every fill settles immediately; the
  // sealed release is the anti-snipe.)
  public type ProtectionCtx = {
    // Spendable balance — must subtract whatever's reserved (staged
    // soft-locks) AND any hard-locked margin collateral. Used by the
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
    // W4-22 (R2), amended by H-24 (F25, D1): the aggressor's ROLE.
    //   #taker — every plain caller (the historical `aggressorIsMaker = false`).
    //   #swept — the AMM sweep re-submitting a USER's resting order as the
    //            AGGRESSOR so it fills at the AMM's equal-or-better price: a
    //            price mechanic, not a role change. The engine pre-reserves
    //            the aggressor's order id (trades that credit it as maker
    //            carry it — attribution keys off a non-zero id) and applies
    //            the unfunded-maker doctrine to it (H-10). Its fee role and
    //            volume attribution are decided PER SLICE by
    //            `makerVs(counterparty)`: MAKER against the AMM (the venue
    //            chose to re-home the order at its own fresh price), TAKER
    //            against another user's resting order — a user-vs-user fill
    //            always has a taker leg, never two makers (the wash
    //            guardrail; pre-H-24 the flat Bool rated BOTH sides maker on
    //            that leg). Taker-rated slices carry the classic id-0
    //            sentinel on the trade so bumpPartyVolume bins them taker.
    //            Resting sides keep their own roles either way. Safe by
    //            construction: reservations are sized at the taker worst
    //            case, so maker-rating never under-reserves. Only the sweep
    //            passes #swept.
    aggressorRole : { #taker; #swept : { makerVs : Principal -> Bool } };
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
    // H-34 / D5 option (d) — BORROW AT FILL. Called once per slice for EACH
    // party (buyer: `token` = quote, `needed` = tradeCost + its fee; seller:
    // `token` = base, `needed` = fillQty) BEFORE that party's funding gate.
    // main.mo answers for a MARGIN POOL by borrowing its shortfall from the
    // vault right here — synchronously, exactly the slice's need, gated by
    // BorrowEngine.borrowCheck on fresh marks — so a leveraged pool order
    // carries no vault debt until the moment it fills. A wallet is a no-op
    // (returns true; the engine's own available-balance gates decide).
    // `false` means the party could NOT be funded: the engine treats it as
    // an unfunded party — a resting maker is cancelled with the ONE
    // unfunded-maker notice (W4-24), an aggressor stops and its remainder
    // is cancelled, never rested or re-parked (H-10's shape). REQUIRED so a
    // missed ctx is a build error, not a silent "pool never fills".
    fundForFill : (party : Principal, baseToken : Types.TokenId,
                   token : Types.TokenId, needed : Nat, fillQty : Nat) -> Bool;
    // 1788641149 / 1788652744: the PROBE-side twin of fundForFill — a
    // per-WALK scorer of what each `party` could BRING to a fill in `token`
    // (the maker's leg: base for a maker-sell, quote for a maker-buy)
    // WITHOUT borrowing: a wallet's available balance; a margin pool's
    // available balance PLUS what the vault would lend it for an exposure-
    // increasing slice (BorrowEngine's initial-health room ∧ vault cap, on
    // the hook's own freshness gates). The factory is called ONCE per walk
    // and the scorer carries the walk's running ledger: `commit` records a
    // slice the walk credited (the party spends `spent` of `token`, receives
    // `received` of the other leg) so later slices of the SAME party are
    // scored on the state that slice leaves — a pool's room re-derived from
    // its settled collateral/debt (quote spent at LTV 1.0, base received at
    // its own LTV, the shortfall as debt), exactly what the fill-time
    // borrowCheck will see. Pre-1788652744 the room was one number at
    // current marks drawn down like cash — exact for a single slice,
    // optimistic across several slices of one pool (a FOK spanning two
    // entries passed the gate, filled the first, had the second refused and
    // ended partially filled). Read-only by contract — fundForFill remains
    // the only borrower. REQUIRED (no default) so a missed ctx is a build
    // error, not a silent "pool depth is zero".
    fundableScorer : () -> FundableScorer;
  };
  public type FundableScorer = {
    balance : (party : Principal, baseToken : Types.TokenId, token : Types.TokenId, fillQty : Nat) -> Nat;
    commit  : (party : Principal, baseToken : Types.TokenId, token : Types.TokenId, spent : Nat, received : Nat) -> ();
  };
  // The cash-only scorer (no pools): a per-(party, token) running available
  // balance, memoised at first sight and drawn down by what the walk commits.
  public func cashScorer(available : (Principal, Types.TokenId) -> Nat) : FundableScorer {
    let run = Map.empty<Text, Nat>();
    func key(p : Principal, t : Types.TokenId) : Text { Principal.toText(p) # "#" # t };
    func bal(p : Principal, t : Types.TokenId) : Nat {
      let k = key(p, t);
      switch (Map.get(run, Text.compare, k)) {
        case (?b) { b };
        case null { let b = available(p, t); Map.add(run, Text.compare, k, b); b };
      };
    };
    { balance = func(p, _, t, _) { bal(p, t) };
      commit  = func(p, _, t, spent, _) { Map.add(run, Text.compare, key(p, t), SafeMath.subOrZero(bal(p, t), spent)) } };
  };

  // A no-op ProtectionCtx — legacy callers pass this to get plain
  // immediate settlement with no bookkeeping. availableBalance falls back to raw Accounts.getBalance —
  // safe in test code but should NOT be used in main.mo, where the real
  // ctx must subtract reserved + locked. (The actor wires both at the
  // call site; this default exists only so unrelated tests can build a
  // legacy ctx without bookkeeping plumbing.)
  public func unprotected(accounts : Accounts.AccountState) : ProtectionCtx = {
    availableBalance = func(p, t) { Accounts.getBalance(accounts, p, t) };
    isNonTakeable    = func(_, _) { false };
    aggressorRole    = #taker;
    onUnfundedMaker  = func(_, _, _, _, _) {};
    isExpired        = func(_) { false };
    quoteFee         = func(_, _, _) { 0 };   // legacy/test: no fee
    creditTreasury   = func(_) {};
    onSelfTrade      = func(_, _) {};          // test ctx: engine still skips the self-cross
    // Legacy/test: no pool registry to consult, so every principal is its own
    // beneficiary — which reduces STP to the raw comparison this ctx has
    // always done. main.mo passes the real resolver.
    beneficialOwner  = func(p) { p };
    onTradeFees      = func(_, _, _) {};       // legacy/test: nothing to attribute
    fundForFill      = func(_, _, _, _, _) { true };   // legacy/test: no pools — balances decide
    fundableScorer   = func() { cashScorer(func(p, t) { Accounts.getBalance(accounts, p, t) }) };   // legacy/test: no pools — cash is what a party can bring
  };

  // ── Per-call work bounds ───────────────────────────────────────
  // One matcher invocation consumes at most this many match-loop iterations,
  // counting EVERY iteration — fills and skips alike, since a skipped maker
  // (non-takeable AMM quote, expired, self-cross, unaffordable)
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
  // iterations per maker the simulation examined (an exhausted maker is
  // touched twice: the skip, then the re-find that excludes it), so a promise
  // built from ≤128 makers always completes within the 256-iteration cap —
  // an FOK must never pass its pre-check and then stop short on iterations.
  // Practical meaning: an all-or-nothing order can sweep at most 128 distinct
  // resting makers; larger jobs are killed at the pre-check, not partially
  // filled.
  public let FOK_SIM_MAKER_BUDGET : Nat = 128;

  // Why a walk STOPPED (task 1788465056, #55 silent "complete"). The
  // budget/quantity tuple alone cannot tell "the budget bought all it could"
  // from "the book ran out one unit short of the budget" — the release used
  // to guess with a 1 bps crumb and stay silent inside it. The engine knows,
  // so it says:
  //   #filled          — remainingQty reached 0 (the stated quantity filled)
  //   #budgetExhausted — the maxQuoteSpend budget cannot afford one more
  //                      base unit at the next price (a COMPLETE conversion
  //                      of the budget, however much quantity is left) — or,
  //                      below 1.0 quote, only a slice worth less than one
  //                      quote unit (the #54 zero-cost fence)
  //   #bookExhausted   — no further takeable maker on the side
  //   #slippage        — the next maker sits past the cap / limit price
  //   #unfunded        — a balance gate refused (the taker's available
  //                      balance, not the budget, bound the walk — including
  //                      to a zero-cost slice; or a settlement rollback)
  //   #workBound       — MAX_MATCH_ITERATIONS_PER_CALL hit with quantity left
  public type StopReason = {
    #filled; #budgetExhausted; #bookExhausted; #slippage; #unfunded; #workBound;
  };

  public type MatchResult = {
    trades : [Types.Trade];
    // (pendingMatches — the retired deferred-fill list, an inert [] stub
    // since task 1788516198 — was REMOVED at apiVersion 6.0.0; MatchResult is
    // the public placeMarketOrder result.)
    remainingQty : Nat;
    totalFilled : Nat;
    avgPrice : Nat;
    affectedUsers : [Principal]; // users whose orders may need adjustment
    // QUOTE the #buy taker committed this call: tradeCost + its taker fee,
    // summed over the settled slices — i.e.
    // exactly what draws down a maxQuoteSpend budget. 0 for #sell takers
    // (their quote leg is a credit). Lets budget-passing callers judge
    // "budget spent" truthfully instead of reconstructing it from
    // totalFilled×avgPrice (floored) — remainingQty > 0 with the budget
    // exhausted is a COMPLETE conversion, not a partial fill.
    quoteSpent : Nat;
    // Why the walk stopped — see StopReason. #filled when remainingQty == 0.
    stopReason : StopReason;
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
      maxSlippage, noPartialFill, timestamp, unprotected(accounts), null, null,
    );
  };

  // Protection-aware market-order execution. Every fill settles
  // immediately (the deferred-fill arm was retired — task 1788516198). A
  // maker the walk must not take (expired, non-takeable, a self-cross) is
  // marked exhausted and the walk advances to the next-best maker
  // (findBestMatchExcluding) — matching does not stop there. Price-time
  // priority is unaffected: skipping a maker with nothing to match against
  // fills nobody out of turn (the limit-order variant below does the same).
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
  //
  // `priceCap` (H-20, F14): an ABSOLUTE price bound — a ceiling for a #buy
  // taker, a floor for a #sell taker — intersected with the slippage band
  // (the band can only get tighter, never wider). The band's reference is
  // the book's best crossable maker, which is exactly the number a player
  // controls the moment real liquidity is absent: a funded lowball bid
  // resting far below the mid becomes `refPrice` when the AMM bids are gone,
  // and a band anchored to it admits the lowball itself. A caller that knows
  // a fair reference (the market's AMM/oracle mid) passes `mid × (1 ± slip)`
  // here and the walk never prints past it, whatever the book's best says.
  // null keeps the band alone (legacy semantics). Applies to the FOK
  // pre-check and to the live walk alike.
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
    priceCap : ?Nat,
  ) : MatchResult {
    let refPrice = switch (OrderBook.findBestMatch(store, marketId, side)) {
      case null { return { trades = []; remainingQty = quantity; totalFilled = 0; avgPrice = 0; affectedUsers = []; quoteSpent = 0; stopReason = #bookExhausted } };
      case (?best) { best.price };
    };

    // Slippage band at 10^8: maxSlippage 0.10 = 10_000_000. Cap rounds DOWN,
    // floor rounds UP → both tighten the band (more protective for the taker).
    // H-20: an absolute priceCap intersects the band — min for the #buy
    // ceiling, max for the #sell floor — so it can only tighten it.
    let bandMax = Fixed.mul(refPrice, Fixed.SCALE + maxSlippage, false);
    let bandMin = if (maxSlippage >= Fixed.SCALE) { 0 } else { Fixed.mul(refPrice, Fixed.SCALE - maxSlippage, true) };
    let (maxPrice, minPrice) = switch (side, priceCap) {
      case (#buy,  ?cap) { (Nat.min(bandMax, cap), bandMin) };
      case (#sell, ?cap) { (bandMax, Nat.max(bandMin, cap)) };
      case (_, null)     { (bandMax, bandMin) };
    };

    // noPartialFill pre-check: simulate to see if full fill is possible.
    // Pending locks are counted against availability — a locked slice can't
    // serve another taker even though the maker looks "open" in the book.
    if (noPartialFill) {
      let availableQty = simulateAvailableFill(store, accounts, marketId, baseToken, taker, side, quantity, maxPrice, minPrice, ctx, maxQuoteSpend);
      if (availableQty < quantity) {
        // FOK pre-check refused: the depth within the band is short — the
        // book (within slippage) is what bound it.
        return { trades = []; remainingQty = quantity; totalFilled = 0; avgPrice = 0; affectedUsers = []; quoteSpent = 0; stopReason = #bookExhausted };
      };
    };

    var remainingQty = quantity;
    var totalFilled : Nat = 0;
    var totalCost : Nat = 0;
    // #buy quote budget (see maxQuoteSpend above). Drawn down by
    // tradeCost + takerFee on every slice the taker settles.
    var remainingBudget : ?Nat = switch (side) { case (#buy) { maxQuoteSpend }; case (#sell) { null } };
    var quoteSpent : Nat = 0;
    // Why the walk stopped (StopReason). Every `break matchLoop` below sets
    // it first; a loop that runs out of quantity reports #filled, one that
    // runs out of iterations #workBound.
    var stop : StopReason = #filled;
    let tradeList = List.empty<Types.Trade>();
    let affectedSet = Map.empty<Text, Principal>();
    // Makers the walk must skip without removing them from the book
    // (expired, non-takeable, self-cross, zero remaining). Excluded on
    // subsequent iterations so the loop advances to the next-best maker
    // instead of re-picking the same one forever.
    let exhausted = Map.empty<Nat, Bool>();

    // Per-call work bound — see MAX_MATCH_ITERATIONS_PER_CALL. Counted at the
    // top so every path through the body (fill, skip-continue, cancel-continue)
    // spends exactly one unit.
    var iterations : Nat = 0;

    label matchLoop while (remainingQty > 0 and iterations < MAX_MATCH_ITERATIONS_PER_CALL) {
      iterations += 1;
      let best = switch (OrderBook.findBestMatchExcluding(store, marketId, side, ?exhausted)) {
        case null { stop := #bookExhausted; break matchLoop };
        case (?b) { b };
      };

      let withinSlippage = switch (side) {
        case (#buy) { best.price <= maxPrice };
        case (#sell) { best.price >= minPrice };
      };
      if (not withinSlippage) { stop := #slippage; break matchLoop };

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

      // Defensive: a maker with nothing left to match against is skipped
      // (exhausted) rather than breaking the walk — findBestMatchExcluding
      // returns the next-best on the next iteration.
      let availableForFill = OrderBook.remaining(best);
      if (availableForFill == 0) {
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      var fillQty = Nat.min(remainingQty, availableForFill);

      // ORDER OF THE TWO GATES (task 1788662146): the TAKER's cap shrinks the
      // slice FIRST, then the MAKER is gated on the slice that will actually
      // settle. This is executeLimitOrderProtected's ordering (its budget
      // shrink runs before its only maker gate) and walkFillable's (the FOK
      // cross-swap gate trims the take to the budget BEFORE the funding
      // check), so a maker funded for the budget-shrunk slice but not for
      // min(taker remaining, order remaining) FILLS its slice — which is what
      // the gate credited it for. Gating on the unshrunk fillQty first
      // cancelled such a maker "unfunded" (the mid-match notice) one line
      // before the shrink would have made it fundable: fokCrossGate passed a
      // buy leg the live leg then came up one maker short on, after the sell
      // leg had settled (W2-03's settle-then-short shape;
      // test_cross_swap_budget.sh §3). The `affordableQty == 0` stop keeps
      // its semantics and now also runs before any maker is cancelled for a
      // slice the taker could never have paid for.

      // Verify taker has enough AVAILABLE balance (committed margin collateral
      // and staged soft-locks excluded). On a #buy the taker is the
      // BUYER and owes the trade cost PLUS its taker fee.
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
        if (affordableQty == 0) {
          // Not one more base unit fits: the BUDGET bound it when the budget
          // is the tighter cap (its conversion is complete); otherwise the
          // taker's available balance did.
          stop := switch (side, remainingBudget) {
            case (#buy, ?b) { if (b <= takerBal) { #budgetExhausted } else { #unfunded } };
            case _ { #unfunded };
          };
          break matchLoop;
        };
        fillQty := Nat.min(fillQty, affordableQty);
      };

      // On a #sell fill the maker (best.owner) is the BUYER, so its QUOTE balance
      // must cover the trade cost PLUS its maker fee — for the (possibly
      // shrunk) slice above, the one that settles below — the cost FLOORED
      // (1788661917), exactly the tradeCost the settlement debits (buyer pays
      // ⌊qty × price⌋ + fee(⌊…⌋); the limit variant's only maker gate, the
      // FOK pre-check and the FOK gate's walker floor the same way). A ceil
      // here cancelled a maker funded to the unit for a debit that would
      // have left it at 0. The TAKER's needs (above) stay ceil: that is a
      // spend cap the shrink keeps provably inside, not a settlement mirror.
      let makerNeeds = switch (side) {
        case (#buy) { fillQty };
        case (#sell) { let b = Fixed.mul(fillQty, best.price, false); b + ctx.quoteFee(best.owner, b, #makerDebit) };
      };
      // H-34 (D5 (d)): a margin-pool maker borrows its shortfall for THIS
      // slice here — the resting entry carried no debt until now. A refusal
      // (vault dry, health, stale mark) is an unfunded maker: notice + cancel.
      // (The taker of this variant is never a pool — pools only take through
      // releaseDeferred's executeLimitOrderProtected — so no taker hook here.)
      let makerTok = switch (side) { case (#buy) { baseToken }; case (#sell) { Types.QUOTE_TOKEN } };
      if (not ctx.fundForFill(best.owner, baseToken, makerTok, makerNeeds, fillQty)) {
        ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
        ignore OrderBook.cancelOrder(store, best.id);
        continue matchLoop;
      };
      // Verify maker has enough AVAILABLE balance — committed margin
      // collateral and staged soft-locks are excluded.
      let makerBal = ctx.availableBalance(best.owner, makerTok);

      if (makerBal < makerNeeds) {
        ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
        ignore OrderBook.cancelOrder(store, best.id);
        continue matchLoop;
      };

      // Execute the trade
      let (buyer, seller) = switch (side) {
        case (#buy) { (taker, best.owner) };
        case (#sell) { (best.owner, taker) };
      };

      let tradePrice = best.price;
      let tradeCost = Fixed.mul(fillQty, tradePrice, false);

      // Zero-cost slice (issue #54; latent — needs a price below 1.0 quote):
      // the affordability floor above can leave fillQty·price rounding to 0
      // quote, a slice worth less than one quote unit. Settling it would move
      // base for nothing and, since a zero debit never draws the budget down,
      // repeat every iteration to MAX_MATCH_ITERATIONS_PER_CALL. BREAK, not
      // continue — the next maker floors the same way. Stop reason: the same
      // discriminator as the affordableQty == 0 branch when a budget bounds
      // this #buy (the tighter cap ended the walk), else #unfunded — no
      // positive quote debit can pay for a sub-unit slice. No new variant:
      // StopReason is candid-visible and the path is unreachable today.
      if (tradeCost == 0) {
        // Maker-bound sub-case (task 1788497411): the taker's cap did NOT
        // shrink this slice below the maker's available remaining, so the
        // MAKER's own remainder is the dust — a budget-shrunk partial fill
        // left it (placement is MIN_ORDER-gated). Breaking here would park
        // it at the top of the level and jam every taker on the side until
        // its owner cancelled; pre-#54 it settled for zero and cleared
        // itself. Clear it like an unfunded maker — notice, cancel, walk
        // on. Every path here either removes a maker from the walk or
        // breaks, so the loop still terminates within the iteration cap.
        if (fillQty == availableForFill) {
          ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
          ignore OrderBook.cancelOrder(store, best.id);
          continue matchLoop;
        };
        stop := switch (side, remainingBudget) {
          case (#buy, ?b) { if (b <= takerBal) { #budgetExhausted } else { #unfunded } };
          case _ { #unfunded };
        };
        break matchLoop;
      };

      // Symmetric maker/taker fee, both legs in QUOTE. The incoming taker is
      // `taker`, the resting maker is best.owner; the buyer is the taker iff this
      // is a #buy. Each fee is 0 for internal principals (ctx.quoteFee exempts).
      let buyerIsTaker = (side == #buy);
      let buyerFee  = ctx.quoteFee(buyer,  tradeCost, if (buyerIsTaker) #takerDebit  else #makerDebit);
      let sellerFee = ctx.quoteFee(seller, tradeCost, if (buyerIsTaker) #makerCredit else #takerCredit);

      // ── Settlement (the engine's one path since task 1788516198) ──
      // Symmetric fee, conservation-exact: buyer pays tradeCost+buyerFee; seller
      // receives tradeCost-sellerFee; treasury gets buyerFee+sellerFee, skimmed
      // ONCE and only after BOTH balance legs subtract — so a rolled-back fill
      // leaves no phantom treasury credit. Internal principals were fee'd 0.
      let buyerOk = Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
      if (not buyerOk) { stop := #unfunded; break matchLoop };
      Accounts.addBalance(accounts, buyer, baseToken, fillQty);

      let sellerOk = Accounts.subtractBalance(accounts, seller, baseToken, fillQty);
      if (not sellerOk) {
        // Rollback buyer's inflated ICPUSD deduction (no treasury skim yet)
        Accounts.addBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
        ignore Accounts.subtractBalance(accounts, buyer, baseToken, fillQty);
        stop := #unfunded;
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

      // This slice is settled:
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

    // Fell out of the loop without a break: quantity done (#filled) or the
    // per-call work bound (#workBound).
    if (remainingQty > 0 and stop == #filled) { stop := #workBound };
    let avgPrice = if (totalFilled > 0) { Fixed.div(totalCost, totalFilled, false) } else { 0 };

    let affected = Iter.toArray(
      Iter.map<(Text, Principal), Principal>(Map.entries(affectedSet), func((_, p)) { p })
    );

    {
      trades = Iter.toArray(List.values(tradeList));
      remainingQty;
      totalFilled;
      avgPrice;
      affectedUsers = affected;
      quoteSpent;
      stopReason = stop;
    };
  };

  // Simulate how much can be filled without actually executing.
  // Uses the market-side index instead of scanning all orders.
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
    // Per-OWNER FUNDABLE balance (1788641149 / 1788652744): one scorer per
    // walk (ctx.fundableScorer), asked before each slice and told of each
    // slice the walk credits, so a maker's affordability accounts for depth
    // this same walk already committed against its shared funding (one
    // owner can rest several makers at a level) — and, for a margin pool,
    // for the health each committed slice leaves (quote spent at LTV 1.0,
    // base received at its own LTV, the shortfall as debt): the room is
    // re-derived per slice from that settled state, the way the live loop's
    // fundForFill will find it. Fundable = available for a wallet; for a
    // pool, available PLUS what the vault would lend it for an exposure-
    // increasing fill — the probe-side twin of fundForFill, which NEVER
    // borrows. Pre-1788641149 a leveraged pool bid with no cash behind it
    // scored ZERO here and this pre-check killed a fill-or-kill order the
    // live loop (borrow at the fill, H-34) would have filled; pre-1788652744
    // the room was one number drawn down like cash, and a FOK spanning two
    // entries of one pool passed here, filled the first and had the second
    // refused at the fill — a partial fill on an all-or-nothing order.
    let scorer = ctx.fundableScorer();

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
    // non-takeable (AMM) / expired makers, count up to the
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
              let rem = OrderBook.remaining(o);
              if (rem > 0) {
                let fillQty = Nat.min(quantity - available, rem);
                // Maker affordability. The live loop CANCELS a maker that can't
                // deliver its side of this fill (base for a maker-sell; quote +
                // maker fee for a maker-buy) and moves on — so such a maker
                // contributes ZERO depth. Modelling it keeps the noPartialFill
                // (FOK) pre-check honest: without it the sim counts an
                // unaffordable maker's depth, FOK passes, then the live cancel
                // leaves a partial fill on an all-or-nothing order.
                let makerTok = switch (side) { case (#buy) { baseToken }; case (#sell) { Types.QUOTE_TOKEN } };
                let makerBal = scorer.balance(o.owner, baseToken, makerTok, fillQty);
                // What the maker spends on this slice, and what it receives
                // (the other leg, net of its maker fee) — the settled shape
                // the scorer carries forward for the maker's later slices.
                // Both legs on the FLOORED cost (1788661917): the live loop's
                // makerNeeds and its debit floor, so a maker funded to the
                // unit counts here exactly as it settles there.
                let (makerNeeds, makerGets) = switch (side) {
                  case (#buy)  { let b = Fixed.mul(fillQty, o.price, false); (fillQty, SafeMath.subOrZero(b, ctx.quoteFee(o.owner, b, #makerCredit))) };
                  case (#sell) { let b = Fixed.mul(fillQty, o.price, false); (b + ctx.quoteFee(o.owner, b, #makerDebit), fillQty) };
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
                  scorer.commit(o.owner, baseToken, makerTok, makerNeeds, makerGets);
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
  ) : (Types.Order, [Types.Trade], [Principal]) {
    let (o, t, a, _, _) = executeLimitOrderProtected(
      store, accounts, marketId, baseToken, owner, side, #limit, price, quantity, timestamp, timestamp,
      unprotected(accounts), null,
    );
    (o, t, a);
  };

  // Protection-aware limit-order execution. For each candidate fill, asks
  // the ProtectionCtx whether the maker may be taken and whether each party
  // can fund the slice; every fill settles immediately (the deferred-fill
  // arm was retired — task 1788516198).
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
  // The 4th result element is quoteSpent — the #buy taker's committed quote
  // (tradeCost + its fee over the settled slices), 0 for #sell — so a
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
  ) : (Types.Order, [Types.Trade], [Principal], Nat, StopReason) {
    var remainingQty = quantity;
    var totalFilled : Nat = 0;
    // Quote notional of the immediate fills (Σ tradeCost, fee-exclusive) —
    // feeds the #market record's VWAP price stamp after the loop.
    var totalCost : Nat = 0;
    // #buy quote budget (see maxQuoteSpend above). Drawn down by
    // tradeCost + buyerFee on every slice the taker commits.
    var remainingBudget : ?Nat = switch (side) { case (#buy) { maxQuoteSpend }; case (#sell) { null } };
    var quoteSpent : Nat = 0;
    // Why the walk stopped — the 5th result element (StopReason). Every
    // `break matchLoop` sets it first; #filled / #workBound after the loop.
    var stop : StopReason = #filled;
    // H-10 (F13): under #swept (aggressorRole) the AGGRESSOR is a resting order the
    // sweep re-homes — W4-24's doctrine ("an unfunded maker is removed at its
    // first match attempt, with a notice") applies to it exactly as to the
    // resting side. Set whenever the walk stops because the aggressor's OWN
    // funding (available balance, the balance-derived budget, or a remainder
    // worth less than one quote unit) refused a slice; read after the loop:
    // the remainder is then CANCELLED, never re-rested. Pre-fix the walk
    // broke silently and re-created the full quantity under a fresh id with
    // the original timestamp, so every requote (~2 s) re-swept it — 100
    // cancel/create cycles per account per requote, a stagedReleasedAs link
    // per cycle, and a permanent #orderClosed row per reaper pass.
    var aggressorUnfunded = false;
    // H-24: `swept` = the aggressor is a resting order the sweep re-homes
    // (id pre-reservation + the unfunded-maker doctrine, whatever it hits);
    // `aggMakerVs(counterparty)` = whether THIS slice rates it maker (only
    // against the AMM — see ProtectionCtx.aggressorRole).
    let swept = switch (ctx.aggressorRole) { case (#taker) { false }; case (#swept(_)) { true } };
    func aggMakerVs(counterparty : Principal) : Bool {
      switch (ctx.aggressorRole) { case (#taker) { false }; case (#swept(s)) { s.makerVs(counterparty) } };
    };
    // W4-22: pre-reserve the aggressor's order id when the sweep re-homes a
    // resting order, so trades recorded mid-loop carry it (0 = the classic
    // "aggressor has no id yet" sentinel, unchanged for every other caller).
    // The order record is created with this id after the loop; a reserved id
    // burned by a no-fill cancel is a harmless gap (ids are already sparse
    // via the staging queue's allocateId).
    let aggressorId : Nat = if (swept) { OrderBook.allocateId(store) } else { 0 };
    let tradeList = List.empty<Types.Trade>();
    let affectedSet = Map.empty<Text, Principal>();
    // Makers the walk must skip without removing them from the book — see
    // the market-side comment.
    let exhausted = Map.empty<Nat, Bool>();

    // Per-call work bound — see MAX_MATCH_ITERATIONS_PER_CALL. A capped-out
    // crossing limit rests its remainder exactly like any partial fill; the
    // rested order is immediately the side's best and later flow finishes it.
    var iterations : Nat = 0;

    label matchLoop while (remainingQty > 0 and iterations < MAX_MATCH_ITERATIONS_PER_CALL) {
      iterations += 1;
      let best = switch (OrderBook.findBestMatchExcluding(store, marketId, side, ?exhausted)) {
        case null { stop := #bookExhausted; break matchLoop };
        case (?b) { b };
      };

      let pricesCross = switch (side) {
        case (#buy) { best.price <= price };
        case (#sell) { best.price >= price };
      };
      if (not pricesCross) { stop := #slippage; break matchLoop };

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
      // so a self-cross never washes volume,
      // pays a fee, double-reserves the same principal, or does free work (DOS).
      if (Principal.equal(ctx.beneficialOwner(owner), ctx.beneficialOwner(best.owner))) {
        ctx.onSelfTrade(best.id, best.owner);
        Map.add(exhausted, Nat.compare, best.id, true);
        continue matchLoop;
      };

      // Defensive: a maker with nothing left to match against is skipped
      // (exhausted) rather than breaking the walk — see the market-side
      // comment.
      let availableForFill = OrderBook.remaining(best);
      if (availableForFill == 0) {
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
      // What a zero-cost slice (the tradeCost == 0 fence below) reports: the
      // budget's discriminator when a budget bounds this #buy, else #unfunded.
      var zeroCostStop : StopReason = #unfunded;
      switch (remainingBudget) {
        case (?bud) {
          let takerBal = ctx.availableBalance(owner, Types.QUOTE_TOKEN);
          let spendCap = Nat.min(takerBal, bud);
          zeroCostStop := if (bud <= takerBal) { #budgetExhausted } else { #unfunded };
          let feeRole = if (aggMakerVs(best.owner)) { #makerDebit } else { #takerDebit };
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
            if (affordableQty == 0) {
              // Not one more base unit fits under min(balance, budget): the
              // BUDGET bound it when it is the tighter cap — its conversion
              // is COMPLETE (the release reads this, not a crumb) — else the
              // taker's available balance did.
              stop := if (bud <= takerBal) { #budgetExhausted } else { #unfunded };
              if (swept) { aggressorUnfunded := true };
              break matchLoop;
            };
            fillQty := Nat.min(fillQty, affordableQty);
          };
        };
        case null {};
      };
      // H-10: the #sell twin of the budget shrink, for a swept ASK. The
      // sweep passes a #buy's available quote as its budget (the shrink
      // above); a #sell aggressor has no budget, so shrink its slice to the
      // base it can actually deliver — fill what is funded, and stop (the
      // remainder is cancelled after the loop) when nothing is.
      if (swept and side == #sell) {
        let deliverable = ctx.availableBalance(owner, baseToken);
        if (deliverable < fillQty) {
          if (deliverable == 0) {
            stop := #unfunded; aggressorUnfunded := true;
            break matchLoop;
          };
          fillQty := deliverable;
        };
      };

      let (buyer, seller) = switch (side) {
        case (#buy) { (owner, best.owner) };
        case (#sell) { (best.owner, owner) };
      };
      let tradePrice = best.price;
      let tradeCost = Fixed.mul(fillQty, tradePrice, false);

      // Zero-cost slice (issue #54; latent below 1.0 quote) — the market
      // variant's fence: a slice whose fillQty·price floors to 0 quote must
      // not settle (base would move for nothing, and a budget that never
      // draws down repeats it to the iteration cap). BREAK, not continue —
      // except the maker-bound sub-case (task 1788497411; the market
      // variant's twin): when the taker's cap did not shrink the slice below
      // the maker's available remaining, the MAKER's remainder is the dust,
      // and breaking would leave it jamming the level. Notice + cancel +
      // walk on.
      if (tradeCost == 0) {
        if (fillQty == availableForFill) {
          ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
          ignore OrderBook.cancelOrder(store, best.id);
          continue matchLoop;
        };
        // H-10: under the sweep the dust remainder is the AGGRESSOR's — a
        // re-rest would jam its level and re-sweep every requote, exactly
        // the maker-side residue task 1788497411 cleared. Cancel it too.
        if (swept) { aggressorUnfunded := true };
        stop := zeroCostStop; break matchLoop;
      };

      // Symmetric maker/taker fee, both legs in QUOTE. Incoming taker is `owner`,
      // resting maker is best.owner; buyer is the taker iff this is a #buy. Each
      // fee is 0 for internal principals (ctx.quoteFee exempts both sides).
      // W4-22 / H-24: under #swept the AGGRESSOR leg is fee-rated maker
      // against the AMM only (the sweep's price mechanic must not decide the
      // fee role; a user counterparty makes this a plain taker leg). The
      // resting leg keeps its own role either way.
      let buyerIsTaker = (side == #buy);
      let aggMaker  = aggMakerVs(best.owner);
      let aggDebit  = if (aggMaker) { #makerDebit }  else { #takerDebit };
      let aggCredit = if (aggMaker) { #makerCredit } else { #takerCredit };
      let buyerFee  = ctx.quoteFee(buyer,  tradeCost, if (buyerIsTaker) aggDebit  else #makerDebit);
      let sellerFee = ctx.quoteFee(seller, tradeCost, if (buyerIsTaker) #makerCredit else aggCredit);

      // H-34 (D5 option (d)): BORROW AT FILL. Each party is funded for THIS
      // slice before its gate — a margin pool (maker OR aggressor) borrows
      // exactly the slice's shortfall from the vault here, on fresh marks,
      // through BorrowEngine.borrowCheck; a wallet is a no-op. A party the
      // vault cannot fund is an UNFUNDED party: a resting maker is cancelled
      // with the one W4-24 notice (the branch below), an aggressor stops
      // here and its remainder is cancelled after the loop — never rested,
      // never re-parked — with the one H-10 notice. Fail-closed: nothing of
      // this slice settles, every slice already settled stands.
      let buyerFunded  = ctx.fundForFill(buyer,  baseToken, Types.QUOTE_TOKEN, tradeCost + buyerFee, fillQty);
      let sellerFunded = buyerFunded and ctx.fundForFill(seller, baseToken, baseToken, fillQty, fillQty);
      if (not (buyerFunded and sellerFunded)) {
        let unfundedIsMaker = if (buyerFunded) { Principal.equal(seller, best.owner) } else { Principal.equal(buyer, best.owner) };
        if (unfundedIsMaker) {
          ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
          ignore OrderBook.cancelOrder(store, best.id);
          continue matchLoop;
        };
        aggressorUnfunded := true;
        stop := #unfunded; break matchLoop;
      };

      // ── Settlement (the engine's one path since task 1788516198) ──
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
          // The AGGRESSOR cannot fund this slice. A taker rests its
          // remainder (legacy); a swept resting order is an unfunded maker
          // in the doctrine's sense — H-10 cancels it after the loop.
          if (swept) { aggressorUnfunded := true };
          stop := #unfunded; break matchLoop;
        };
      };
      if (ctx.availableBalance(seller, baseToken) < fillQty) {
        if (Principal.equal(seller, best.owner)) {
          ctx.onUnfundedMaker(marketId, best.owner, best.side, best.price, OrderBook.remaining(best));
          ignore OrderBook.cancelOrder(store, best.id);
          continue matchLoop;
        } else {
          if (swept) { aggressorUnfunded := true };
          stop := #unfunded; break matchLoop;
        };
      };
      let buyerOk = Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
      if (not buyerOk) { stop := #unfunded; break matchLoop };
      Accounts.addBalance(accounts, buyer, baseToken, fillQty);
      let sellerOk = Accounts.subtractBalance(accounts, seller, baseToken, fillQty);
      if (not sellerOk) {
        Accounts.addBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);
        ignore Accounts.subtractBalance(accounts, buyer, baseToken, fillQty);
        stop := #unfunded; break matchLoop;
      };
      // Skim both fees to the treasury ONCE, after both legs subtract; net the
      // seller credit. buyer_out(C+bF) == seller_net(C-sF) + treasury(bF+sF).
      ctx.creditTreasury(buyerFee + sellerFee);
      Accounts.addBalance(accounts, seller, Types.QUOTE_TOKEN, tradeCost - sellerFee);
      ignore OrderBook.fillOrder(store, best.id, fillQty);
      // W4-22 / H-24: the aggressor side carries its pre-reserved id only
      // on a slice rated MAKER (swept, against the AMM); a taker-rated
      // slice carries 0 — the historical sentinel every other caller
      // writes — so bumpPartyVolume bins it taker.
      let aggTradeId : Nat = if (aggMaker) { aggressorId } else { 0 };
      let (buyOrderId, sellOrderId) = switch (side) {
        case (#buy) { (aggTradeId, best.id) };
        case (#sell) { (best.id, aggTradeId) };
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

      // This slice is settled: on
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
    // Fell out of the loop without a break: quantity done (#filled) or the
    // per-call work bound (#workBound).
    if (remainingQty > 0 and stop == #filled) { stop := #workBound };

    // H-10: a swept resting order whose owner could not fund a slice gets the
    // SAME treatment as an unfunded resting maker — one notice (the owner's
    // release-rejection feed, via ctx.onUnfundedMaker), and the unfundable
    // remainder is cancelled below instead of re-rested. Fired once per
    // walk, here rather than at the break sites, so a partial fill followed
    // by an unfunded slice reports the remainder that was actually dropped.
    // H-34: the same one notice for a margin-pool AGGRESSOR whose borrow-at-
    // fill was refused (fundForFill false) — aggressorUnfunded is set there
    // for every caller, sweep or not; its remainder is cancelled below.
    if (aggressorUnfunded) {
      ctx.onUnfundedMaker(marketId, owner, side, price, remainingQty);
    };

    // Decide whether there's anything to create in the order book. Three
    // cases:
    //   (a) remainingQty > 0 (normal resting order, possibly after some
    //       immediate fills)
    //   (b) remainingQty == 0 and totalFilled > 0 (fully filled immediately —
    //       we still create a record so trade history has a concrete order
    //       id for buyOrderId/sellOrderId lookups, and the fillOrder call
    //       removes it from the open-book indexes by marking it #filled)
    //   (c) remainingQty == 0 and totalFilled == 0 (only a zero-quantity
    //       request reaches this since the deferred-fill arm was retired —
    //       task 1788516198; it once meant "every fill went pending". No
    //       book presence: a 0-qty #open record would be a zombie stuck in
    //       openOrdersByMarketSide, returned by findBestMatch as the "best"
    //       at its price and breaking the matcher on availableForFill == 0.
    //       So we skip the book entirely and return a synthetic #filled
    //       record.)
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
    } else if (aggressorUnfunded) {
      // H-10: the unfundable remainder of a swept order is NOT re-rested.
      // With immediate fills the trades above already carry aggressorId, so
      // the record must exist: create it at the full requested size, apply
      // the fills, then close it #cancelled (an honest "cancelled after a
      // partial fill" row — filled < quantity — for the reaper to seal).
      // With no fill nothing is created: id 0 is the "nothing rested"
      // sentinel the #market dry cycle already returns, the reserved
      // aggressorId is a harmless gap, and the caller's old order (which it
      // cancelled before re-submitting) is the ONE closure the reaper seals.
      // H-34: a #limit margin-pool aggressor whose borrow-at-fill was refused
      // lands here too (aggressorId 0 — no sweep reserved one): same shape,
      // a fresh id when fills must be recorded, nothing rested either way.
      if (totalFilled > 0) {
        let order = if (aggressorId != 0) {
          OrderBook.createOrderWithId(store, aggressorId, marketId, owner, side, orderType, price, remainingQty + totalFilled, timestamp)
        } else {
          OrderBook.createOrder(store, marketId, owner, side, orderType, price, remainingQty + totalFilled, timestamp)
        };
        ignore OrderBook.fillOrder(store, order.id, totalFilled);
        switch (OrderBook.cancelOrder(store, order.id)) {
          case (?o) { o };
          case null { order };
        };
      } else {
        {
          id = 0; marketId; owner; side; orderType; price;
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
      // Case (c): nothing to rest, nothing settled. Status = #filled signals
      // that this order will never rest or see further matching. id = 0 is
      // the same sentinel we use in Trade records for "taker side has no
      // order id".
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
      affected,
      quoteSpent,
      stop,
    );
  };
};
