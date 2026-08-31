import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Option "mo:core/Option";
import Types "Types";

module {

  // Balances are integer base units (10^8 = 1 whole token — see lib/Fixed.mo).
  //
  // `journal` is the LEDGER OF RECORD's feed: every balance mutation — from
  // any module, any code path — appends its exact signed delta here, because
  // setBalance below is the single write funnel (addBalance/subtractBalance
  // route through it, and nothing else touches `balances`). main drains the
  // journal into #delta archive events each heartbeat, so replaying those
  // events reproduces every account balance BY CONSTRUCTION — no per-feature
  // event enumeration to keep complete. Rollback branches self-cancel (the
  // do and the undo both journal). NOTE: adding this field to AccountState
  // is a stable-layout change — deploying it over an existing canister needs
  // a REINSTALL (+ reseed), not an upgrade.
  public type AccountState = {
    balances : Map.Map<Text, Nat>;
    journal : List.List<(Principal, Types.TokenId, Int)>;
  };

  public func emptyState() : AccountState {
    { balances = Map.empty<Text, Nat>(); journal = List.empty<(Principal, Types.TokenId, Int)>() };
  };

  // Shared key used by both the balance map and the (externally-held)
  // reserved-ledger map in main.mo. Exposed so callers can coordinate.
  public func balKey(user : Principal, token : Types.TokenId) : Text {
    Principal.toText(user) # "#" # token;
  };

  public func getBalance(state : AccountState, user : Principal, token : Types.TokenId) : Nat {
    Option.get(Map.get(state.balances, Text.compare, balKey(user, token)), 0);
  };

  public func setBalance(state : AccountState, user : Principal, token : Types.TokenId, amount : Nat) {
    let old = getBalance(state, user, token);
    if (amount != old) {
      List.add(state.journal, (user, token, (amount : Int) - old));
    };
    Map.add(state.balances, Text.compare, balKey(user, token), amount);
  };

  public func addBalance(state : AccountState, user : Principal, token : Types.TokenId, amount : Nat) {
    setBalance(state, user, token, getBalance(state, user, token) + amount);
  };

  // Refuses an overdraft (returns false, balance untouched) and can never go
  // negative — exact integer arithmetic, no tolerance needed.
  public func subtractBalance(state : AccountState, user : Principal, token : Types.TokenId, amount : Nat) : Bool {
    let current = getBalance(state, user, token);
    if (current < amount) { return false };
    setBalance(state, user, token, current - amount);
    true;
  };

  public func getUserBalances(state : AccountState, user : Principal) : [(Types.TokenId, Nat)] {
    // W5-19 (F10): the balance map is ordered and keyed "principal#token", so
    // one user's rows are a contiguous range — seek to the prefix and stop at
    // the first key past it, instead of scanning every account on the venue.
    // This is a QUERY-reachable path (the ~8×-lower instruction ceiling).
    let prefix = Principal.toText(user) # "#";
    let results = Map.empty<Text, Nat>();
    label walk for ((key, bal) in Map.entriesFrom(state.balances, Text.compare, prefix)) {
      if (not Text.startsWith(key, #text prefix)) { break walk };
      let token = textAfter(key, Text.size(prefix));
      if (bal > 0) {
        Map.add(results, Text.compare, token, bal);
      };
    };
    Iter.toArray(Map.entries(results));
  };

  func textAfter(t : Text, skip : Nat) : Text {
    var i = 0;
    var result = "";
    for (c in t.chars()) {
      if (i >= skip) { result #= Text.fromChar(c) };
      i += 1;
    };
    result;
  };
};
