// UserAccount.mo — every endpoint that touches a single user's own
// state: profile, preferences, balances, trade history, deposit /
// adjustment history, status (the per-user nonce used for change
// detection on the frontend).
//
// All endpoints are `requireAuth` (non-anonymous principal). None
// require controller privileges. State (userProfiles, userPreferences,
// accounts, userDeposits, userAdjustments, userStatuses, orderStore,
// registeredUsers) is owned by the actor and passed by reference.

import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:core/Map";
import Runtime "mo:core/Runtime";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Option "mo:core/Option";
import Time "mo:core/Time";
import Types "../lib/Types";
import Accounts "../lib/Accounts";
import OrderBook "../lib/OrderBook";
import Profiles "../lib/Profiles";
import UserStatus "../lib/UserStatus";
import MarginEngine "../lib/MarginEngine";
import SafeMath "../lib/SafeMath";

mixin (
  accounts        : Accounts.AccountState,
  orderStore      : OrderBook.OrderStore,
  marginAccounts  : MarginEngine.MarginState,
  marginPriceLookup : MarginEngine.PriceLookup,
  availableBalance  : (Principal, Types.TokenId) -> Nat,
  reservedBalance   : (Principal, Types.TokenId) -> Nat,
  userProfiles    : Map.Map<Text, Types.UserProfile>,
  userPreferences : Map.Map<Text, Types.UserPreferences>,
  userDeposits    : Map.Map<Text, List.List<Types.DepositRecord>>,
  // FOSSIL-PARKED pre-reason rows (frozen at the deployed layout; never
  // written after the reason field landed) + the live V2 map new records go
  // to. getMyAdjustments merges them, fossil rows first (strictly older).
  userAdjustments   : Map.Map<Text, List.List<Types.OrderAdjustmentLegacy>>,
  userAdjustmentsV2 : Map.Map<Text, List.List<Types.OrderAdjustment>>,
  userStatuses    : Map.Map<Text, Types.UserStatus>,
  registeredUsers : Map.Map<Text, Bool>,
  requireAuth     : Principal -> (),
  // TRUE on play + production postures: the open faucet must be dead on any
  // PUBLIC deployment — in play mode users get exactly one fixed starter
  // basket via claimPlayFunds instead (leaderboard fairness), and on a
  // value-bearing deploy minting would be theft (security review C1).
  faucetDisabled  : Bool,
  // TRUE only on the #production posture. `withdraw` below still has NO
  // custody transfer behind it, so on a value-bearing deployment it would
  // destroy real balances while reporting success — this is the interlock.
  isProduction    : Bool,
  // Draws a friendly username from the actor's entropy pool. NOT derived from
  // the principal — see Profiles.usernameFromDraws for why that mattered.
  drawUsername    : () -> Text,
  // Writes a deposit record AND captures it for permanent history (the
  // actor's appendDeposit wrapper) — the mixin must not append to the map
  // directly or the archive would miss faucet deposits.
  recordDeposit   : (Principal, Types.DepositRecord) -> (),
) {

  // Bounds on the one payload a free, unregistered identity can persist.
  // 8 is generous against a frontend that slices to 3; a market id like
  // "BTC-ICPUSD" is 10 chars, so 32 leaves room without admitting a blob.
  transient let PREFS_MAX_RECENT_MARKETS : Nat = 8;
  transient let PREFS_MAX_MARKET_LEN : Nat = 32;

  // ── Profile ─────────────────────────────────────────────────
  // Update call (may create profile on first hit). Auto-generates a
  // friendly username; the user can regenerate up to MAX_USERNAME_REGENS
  // times before being locked in.
  public shared (msg) func getMyProfile() : async Types.UserProfile {
    requireAuth(msg.caller);
    let key = Principal.toText(msg.caller);
    switch (Map.get(userProfiles, Text.compare, key)) {
      case (?p) { p };
      case null {
        let p = Profiles.createProfile(msg.caller, Time.now(), drawUsername());
        Map.add(userProfiles, Text.compare, key, p);
        // NB: does NOT register. Registration (the `registeredUsers` flag that
        // the inspect admission gate keys on) happens only on a value-bearing
        // DEPOSIT — addTestTokens in dev, the chain-key custody credit in prod —
        // so "joining" costs real assets and the gate can't be spammed open by
        // calling getMyProfile from throwaway principals. In prod an unregistered
        // principal can't reach this method anyway (inspect rejects it); they
        // register by depositing first, then this creates their profile.
        p
      };
    };
  };

  public shared (msg) func regenerateUsername() : async { #ok : Types.UserProfile; #err : Text } {
    requireAuth(msg.caller);
    let key = Principal.toText(msg.caller);
    switch (Map.get(userProfiles, Text.compare, key)) {
      case null { #err("Profile not found — call getMyProfile first") };
      case (?profile) {
        switch (Profiles.regenerate(profile, drawUsername())) {
          case (#err(e)) { #err(e) };
          case (#ok(newProfile)) {
            Map.add(userProfiles, Text.compare, key, newProfile);
            #ok(newProfile)
          };
        };
      };
    };
  };

  // ── Preferences ─────────────────────────────────────────────
  public shared (msg) func getUserPreferences() : async Types.UserPreferences {
    requireAuth(msg.caller);
    let key = Principal.toText(msg.caller);
    switch (Map.get(userPreferences, Text.compare, key)) {
      case null { { recentMarkets = []; lastMarket = null } };
      case (?prefs) { prefs };
    };
  };

  // VALIDATED BEFORE IT PERSISTS. requireAuth rejects only the anonymous
  // principal — it is not an authorization boundary — so this was the one write
  // endpoint reachable before any anti-Sybil control, storing an unbounded,
  // unvalidated blob per free identity with no eviction and no purge path
  // (performWorldWipe clears ~60 maps and never touched this one). The only
  // ceiling was the ~2 MiB ingress limit, so a few thousand calls from rotating
  // throwaway identities reached the memory wall the order-map leak already hit
  // once. The frontend's slice-to-3 is a client convention, not a control.
  public shared (msg) func setUserPreferences(prefs : Types.UserPreferences) : async () {
    requireAuth(msg.caller);
    if (prefs.recentMarkets.size() > PREFS_MAX_RECENT_MARKETS) { return };
    for (m in prefs.recentMarkets.vals()) {
      if (m.size() > PREFS_MAX_MARKET_LEN) { return };
    };
    switch (prefs.lastMarket) {
      case (?m) { if (m.size() > PREFS_MAX_MARKET_LEN) { return } };
      case null { };
    };
    let key = Principal.toText(msg.caller);
    Map.add(userPreferences, Text.compare, key, prefs);
  };

  // ── Test-token faucet (self-service) ────────────────────────
  // User credits themselves with `amount` of `token`. Open to any
  // authenticated caller in DEV builds only — the sim and the frontend
  // faucet depend on it. HARD NO-OP on play and production postures
  // (security review C1): the minted balance is spendable and
  // vault-redeemable, and `requireAuth` is NOT a guard (any principal
  // self-authenticates), so this must be dead on any public deploy.
  public shared (msg) func addTestTokens(token : Types.TokenId, amount : Nat) : async () {
    // THE RULE (main.mo requireDevHook): refuse loudly — no Result channel
    // here, so trap. This was the one posture gate still SILENT on the live
    // #play posture (W6-02 / #41.2 step 5).
    if (faucetDisabled) { Runtime.trap("addTestTokens is a dev-only faucet (posture: play/production)") };
    requireAuth(msg.caller);
    Accounts.addBalance(accounts, msg.caller, token, amount);
    Map.add(registeredUsers, Text.compare, Principal.toText(msg.caller), true);
    recordDeposit(msg.caller, {
      token; amount; timestamp = Time.now(); kind = #deposit
    });
    UserStatus.bumpVersion(userStatuses, orderStore, msg.caller);
  };

  // ── Balance views ───────────────────────────────────────────
  public query (msg) func getBalances() : async [(Types.TokenId, Nat)] {
    Accounts.getUserBalances(accounts, msg.caller);
  };

  public query (msg) func getBalance(token : Types.TokenId) : async Nat {
    Accounts.getBalance(accounts, msg.caller, token);
  };

  // ── Wallet: deposit address + withdraw ──────────────────────
  // The Wallet holds withdrawable virtual balances (getBalances above). In
  // production each (user, asset) gets a chain-key custody deposit address;
  // tokens sent there — including directly from a CEX — credit the balance
  // after finality and stay in custody until withdrawal. Chain-key custody is
  // not yet wired: DEV deposits use the faucet (addTestTokens), getDepositAddress
  // returns a deterministic placeholder, and withdraw debits the virtual balance
  // with no real chain transfer. See docs/wallet-and-positions-design.md.
  public query (msg) func getDepositAddress(token : Types.TokenId) : async Text {
    "uplands-dev:" # token # ":" # Principal.toText(msg.caller)
  };

  // Withdraw uncommitted Wallet balance to an external address. Only wallet
  // funds are reachable — collateral committed to a margin pool lives under the
  // pool principal, so it can't be withdrawn here (close the position first).
  //
  // ⚠️ SECURITY — PRODUCTION SAGA IS DEFERRED. Today this is atomic and safe:
  // the whole body is SYNCHRONOUS (no `await`), so it commits as one message and
  // cannot be reentered or raced, and `destination` is ignored (no real transfer
  // happens yet — dev/play post the debit only). When chain-key custody wires
  // the REAL external transfer this becomes `debit → await transfer`, which
  // introduces an interleaving point. At THAT point this MUST become a saga or
  // assets can be lost / double-paid:
  //   1. Keep the debit BEFORE the await (already the case below) — two racing
  //      withdraws then serialize, because the second sees the reduced balance.
  //   2. Give each withdraw a unique id; make the custody transfer idempotent on
  //      it, so a retry can't pay twice.
  //   3. CONFIRMED failure → refund exactly once. AMBIGUOUS outcome (timeout) →
  //      reconcile against the ledger before acting. Never blind-refund (double
  //      pay = protocol loss) and never blind-drop (user loss).
  //   4. Add a per-(user,asset) in-flight guard around the await. (A guard is
  //      pointless while the body is synchronous, so it lands WITH the transfer,
  //      not before — adding it now would be dead code that protects nothing.)
  // Refs: docs/wallet-and-positions-design.md, docs/bridge-and-cks-design.md.
  public shared (msg) func withdraw(token : Types.TokenId, amount : Nat, destination : Text) : async { #ok; #err : Text } {
    requireAuth(msg.caller);
    // POSTURE INTERLOCK. Everything below debits the balance and records a
    // #withdrawal — and then stops. There is no custody transfer yet (the
    // steps are enumerated above; the Bridge is a stub), so `destination` is
    // read and dropped. On #play that is exactly right: play balances are
    // fake, and burning them is the whole meaning of a withdrawal.
    //
    // On #production the same code path silently DESTROYS real value and
    // returns #ok — the worst possible failure, because it reports success.
    // The posture flip is a one-line edit in main.mo (docs/pre-mainnet-
    // checklist.md), so this refuses rather than trusting whoever flips it to
    // remember. Delete this guard in the same change that lands the transfer.
    if (isProduction) {
      return #err("Withdrawals are disabled: on-chain custody transfer is not implemented yet. Your balance is unchanged.");
    };
    let _ = destination;   // no custody leg yet — see the interlock above
    if (amount == 0) { return #err("Amount must be positive") };
    if (availableBalance(msg.caller, token) < amount) {
      return #err("Insufficient withdrawable " # token # " in your wallet");
    };
    if (not Accounts.subtractBalance(accounts, msg.caller, token, amount)) {
      return #err("Withdrawal failed");
    };
    recordDeposit(msg.caller, { token; amount; timestamp = Time.now(); kind = #withdrawal });
    UserStatus.bumpVersion(userStatuses, orderStore, msg.caller);
    #ok
  };

  // ── History queries ─────────────────────────────────────────
  public query (msg) func getMyTradeHistory() : async [Types.Trade] {
    OrderBook.getUserTrades(orderStore, msg.caller, 200);
  };

  public query (msg) func getMyTradeHistorySince(sinceTimestamp : Int) : async [Types.Trade] {
    OrderBook.getUserTradesSince(orderStore, msg.caller, sinceTimestamp, 200);
  };

  public query (msg) func getMyAdjustments() : async [Types.OrderAdjustment] {
    let key = Principal.toText(msg.caller);
    let merged = List.empty<Types.OrderAdjustment>();
    // Fossil rows first: the legacy map predates the reason field and is
    // never appended to after the upgrade, so its rows are strictly older
    // than every V2 row. They surface with reason = null.
    switch (Map.get(userAdjustments, Text.compare, key)) {
      case (?lst) {
        for (a in List.values(lst)) {
          List.add(merged, {
            orderId     = a.orderId;
            marketId    = a.marketId;
            side        = a.side;
            oldQuantity = a.oldQuantity;
            newQuantity = a.newQuantity;
            cancelled   = a.cancelled;
            timestamp   = a.timestamp;
            reason      = null;
          });
        };
      };
      case null {};
    };
    switch (Map.get(userAdjustmentsV2, Text.compare, key)) {
      case (?lst) { for (a in List.values(lst)) { List.add(merged, a) } };
      case null {};
    };
    let all = Iter.toArray(List.values(merged));
    let n = all.size();
    if (n <= 200) { return all };
    let result = List.empty<Types.OrderAdjustment>();
    var i : Nat = n - 200;
    while (i < n) { List.add(result, all[i]); i += 1 };
    Iter.toArray(List.values(result))
  };

  public query (msg) func getMyDeposits() : async [Types.DepositRecord] {
    let key = Principal.toText(msg.caller);
    Iter.toArray(List.values(
      Option.get(Map.get(userDeposits, Text.compare, key), List.empty<Types.DepositRecord>())
    ))
  };

  // ── Status nonce (for frontend change detection) ────────────
  public query (msg) func getUserStatus() : async Types.UserStatus {
    UserStatus.get(userStatuses, msg.caller);
  };

  // ── Cross-market bid headroom + cross-margin collateral surface ──
  // Surfaces the user's combined open-buy exposure vs. their bid cap
  // (Phase 0 soft-leverage limit, = available cash × factor), plus the
  // whole-portfolio LTV-weighted collateral breakdown when they have a
  // margin account. The health bar / debt live in getMyMarginHealth +
  // getMyDebt (main.mo).
  public query (msg) func getMyBidHeadroom() : async Types.BidHeadroom {
    let availCash = availableBalance(msg.caller, Types.QUOTE_TOKEN);
    let totalCash = Accounts.getBalance(accounts, msg.caller, Types.QUOTE_TOKEN);
    let gross = OrderBook.getUserGrossBuyValue(orderStore, msg.caller);
    let margin = MarginEngine.get(marginAccounts, msg.caller);
    let vals  = MarginEngine.valuations(marginAccounts, accounts, reservedBalance, msg.caller, marginPriceLookup);
    let collUsd = MarginEngine.collateralValueUsd(vals);
    let cap   = MarginEngine.computeBidCap(availCash);
    let headroom = SafeMath.subOrZero(cap, gross);
    {
      cashBalance   = availCash;
      totalBalance  = totalCash;
      grossBidValue = gross;
      maxAllowed    = cap;
      headroom;
      factor        = Types.CROSS_MARKET_BID_FACTOR;
      marginAccount = margin;
      collateralBreakdown = vals;
      collateralValueUsd  = collUsd;
    };
  };

  // ── Margin account lifecycle (REMOVED — model 2) ─────────────
  // Whole-wallet cross-margin is gone: the Wallet is pure custody, never
  // collateral. Leverage/short happen only in margin pools (main.mo
  // createMarginPool / openPosition), which own their own margin accounts on
  // the pool principal. The always-empty compat read getMyMarginAccount was
  // RETIRED here (W5-23): the frontend dropped its callers when model 2
  // landed (src/frontend/src/main.js records it), and the removal rides the
  // still-unpublished API 3.0.0 window. See docs/wallet-and-positions-design.md.
};
