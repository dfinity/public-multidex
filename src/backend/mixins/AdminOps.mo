// AdminOps.mo — controller-only admin endpoints.
//
// Surfaces:
//   - setTestBalance       (single-user balance write, controller-only)
//   - bulkSetTestBalances  (batched balance writes for cold-start seeding)
//   - getTestBalance       (public query — no auth needed)
//
// The actor passes in only what these endpoints touch: the accounts
// state, the registered-users map, and a `requireController` callback
// that traps if the caller is not a canister controller. The mixin
// does NOT call `ensureInit` — the actor's other entry points (or its
// install-time top-level) are responsible for canister bootstrap; by
// the time any admin endpoint is reached in practice, init has run.

import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:core/Map";
import Runtime "mo:core/Runtime";
import Types "../lib/Types";
import Accounts "../lib/Accounts";

mixin (
  accounts          : Accounts.AccountState,
  registeredUsers   : Map.Map<Text, Bool>,
  requireController : Principal -> (),
  isProduction      : Bool,
  // Leaderboard baseline: a balance SET is an external capital injection or
  // removal, so its delta must count as a flow — otherwise seeded balances
  // read as pure trading profit. (Real deposits/withdrawals record via
  // appendDeposit; this covers the dev/seed path.)
  recordFlow        : (Principal, Types.TokenId, Int) -> (),
) {

  // These mint/read test balances — dev & cold-start seeding only. They are
  // already controller-gated, but in a production build they become hard
  // no-ops regardless of caller (a controller must never mint balances live).
  public shared (msg) func setTestBalance(
    user   : Principal,
    token  : Types.TokenId,
    amount : Nat,
  ) : async () {
    if (isProduction) { Runtime.trap("setTestBalance is not available on #production") };
    requireController(msg.caller);
    let old = Accounts.getBalance(accounts, user, token);
    Accounts.setBalance(accounts, user, token, amount);
    recordFlow(user, token, (amount : Int) - (old : Int));
    Map.add(registeredUsers, Text.compare, Principal.toText(user), true);
  };

  public shared (msg) func bulkSetTestBalances(
    entries : [{
      principal : Principal;
      balances  : [{ token : Types.TokenId; amount : Nat }];
    }]
  ) : async Nat {
    if (isProduction) { Runtime.trap("bulkSetTestBalances is not available on #production") };
    requireController(msg.caller);
    var n : Nat = 0;
    for (entry in entries.vals()) {
      for (b in entry.balances.vals()) {
        let old = Accounts.getBalance(accounts, entry.principal, b.token);
        Accounts.setBalance(accounts, entry.principal, b.token, b.amount);
        recordFlow(entry.principal, b.token, (b.amount : Int) - (old : Int));
        n += 1;
      };
      Map.add(registeredUsers, Text.compare, Principal.toText(entry.principal), true);
    };
    n;
  };

  // Read a balance. SCOPED: your own, or anyone's if you are a controller.
  //
  // This was `public query func` taking the principal as an ARGUMENT with no
  // caller check at all — so on #play any anonymous caller could read any
  // principal's exact holdings. Combined with getLeaderboard publishing the
  // ranked principals as text, that handed out every ranked trader's full
  // balance sheet for free (queries also bypass `inspect`). Note this reads
  // LIVE balances, not the event tape, so nothing about Proof-of-Reserves
  // depends on it — PoR folds #delta events from the public archive.
  //
  // Operational note: bot fleets poll this to refill (scripts/sim_trading.sh
  // `bal_of`) and deploy.sh guards the arb top-up with it. Those read OTHER
  // principals, so they must now call as the controller identity — both were
  // updated alongside this change.
  public query (msg) func getTestBalance(user : Principal, token : Types.TokenId) : async Nat {
    // Loud on the POSTURE (the gate class the rule covers); the caller-auth
    // return-0 below stays — that silence is a deliberate anti-oracle choice
    // (see main.mo's getTestBalance note), not a posture gate.
    if (isProduction) { Runtime.trap("getTestBalance is not available on #production") };
    if (not (Principal.equal(msg.caller, user) or Principal.isController(msg.caller))) { return 0 };
    Accounts.getBalance(accounts, user, token);
  };
};
