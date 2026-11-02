// AdminOps.mo — the balance-mint admin endpoints.
//
// Surfaces:
//   - setTestBalance       (single-user balance write — a controller OR the
//                           designated funding authority)
//   - bulkSetTestBalances  (batched balance writes for cold-start seeding —
//                           same callers, genesis-bound on #play)
//   - getTestBalance       (query — your own, or anyone's as a controller /
//                           the funding authority)
//
// The actor passes in only what these endpoints touch: the accounts
// state, the registered-users map, and an `isFundingAuthority` reader
// (main.mo's `_fundingAuthority`, set by a controller via
// setFundingAuthority — task 1789609263). The caller verdict is the pure
// lib/Funding.mintAdmitted(posture, isController, isFundingAuthority):
// #production never; #dev / #play a controller or the authority. The mixin
// does NOT call `ensureInit` — the actor's other entry points (or its
// install-time top-level) are responsible for canister bootstrap; by
// the time any admin endpoint is reached in practice, init has run.

import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Map "mo:core/Map";
import Runtime "mo:core/Runtime";
import Types "../lib/Types";
import Accounts "../lib/Accounts";
import Genesis "../lib/Genesis";
import Funding "../lib/Funding";

mixin (
  accounts          : Accounts.AccountState,
  registeredUsers   : Map.Map<Text, Bool>,
  // The FUNDING AUTHORITY reader (task 1789609263): is this principal the
  // one a controller designated via setFundingAuthority? A READER, not a
  // value — the stable field is set after the include runs.
  isFundingAuthority : Principal -> Bool,
  isProduction      : Bool,
  // Leaderboard baseline: a balance SET is an external capital injection or
  // removal, so its delta must count as a flow — otherwise seeded balances
  // read as pure trading profit. (Real deposits/withdrawals record via
  // appendDeposit; this covers the dev/seed path.)
  recordFlow        : (Principal, Types.TokenId, Int) -> (),
  // H-36 (D4 (a′)): both balance setters REGISTER their target, so both lift
  // it out of the bounded pre-registration store (its profile/preferences
  // become permanent — never capped, never expired).
  onRegistered      : Principal -> (),
  // The genesis window (decision 1788529484, lib/Genesis.mo): the live
  // posture and a reader of main.mo's `_ammEverEnabled` latch — a READER,
  // because a Bool argument would capture the value at include time and the
  // latch flips later, on the first enableAmm.
  posture           : Genesis.Posture,
  genesisLatched    : () -> Bool,
) {

  // The one caller gate for both mints (task 1789609263): a canister
  // controller OR the designated funding authority, on #dev / #play only —
  // lib/Funding.mintAdmitted is the verdict (exhaustive on the posture;
  // tests/Funding.test.mo pins it). The refusal keeps the historical
  // "not a canister controller" phrase (suites grep it) and names the
  // designation path so an operator reading a fleet log knows the cure.
  func requireMinter(caller : Principal, method : Text) {
    if (not Funding.mintAdmitted(posture, Principal.isController(caller), isFundingAuthority(caller))) {
      Runtime.trap(method # ": caller is not a canister controller and not the designated funding authority (a controller designates one via setFundingAuthority; fleet refills sign with MDX_FUNDING_IDENTITY)");
    };
  };

  // These mint/read test balances — dev & cold-start seeding only. They are
  // already controller-gated, but in a production build they become hard
  // no-ops regardless of caller (a controller must never mint balances live).
  //
  // DECISION (operator, 2026-09-06, task 1788529484 — F29-backend): on #play
  // setTestBalance is RATIFIED as a live controller bootstrap tool — an
  // absolute SET (a repeat re-mints only what was spent), controller-only,
  // extNetFlow-recorded (capital, never leaderboard profit) — because the
  // fleet's standing refill (sim_trading.sh fund_call) and play_start.sh's
  // per-market base legs inside the loop (after the first enableAmm) need it
  // live; the repeat-deploy mint is bounded by H-02's fail-closed seed probe
  // and H-17's seedInsuranceFund refusal. It is deliberately NOT bound to the
  // genesis window below (fundArbitrageur in main.mo rides the same
  // decision). bulkSetTestBalances IS bound: no #play path calls it.
  public shared (msg) func setTestBalance(
    user   : Principal,
    token  : Types.TokenId,
    amount : Nat,
  ) : async () {
    if (isProduction) { Runtime.trap("setTestBalance is not available on #production") };
    requireMinter(msg.caller, "setTestBalance");
    let old = Accounts.getBalance(accounts, user, token);
    Accounts.setBalance(accounts, user, token, amount);
    recordFlow(user, token, (amount : Int) - (old : Int));
    Map.add(registeredUsers, Text.compare, Principal.toText(user), true);
    onRegistered(user);
  };

  public shared (msg) func bulkSetTestBalances(
    entries : [{
      principal : Principal;
      balances  : [{ token : Types.TokenId; amount : Nat }];
    }]
  ) : async Nat {
    if (isProduction) { Runtime.trap("bulkSetTestBalances is not available on #production") };
    requireMinter(msg.caller, "bulkSetTestBalances");
    // H-17 second half (decision 1788529484): the batched seed mint is bound
    // to the same genesis window as injectHistoricalTrades and the repeat
    // seedInsuranceFund — on #play, once a market has been enabled on this
    // install (main.mo's _ammEverEnabled: survives upgrades AND season
    // resets; only a reinstall re-arms it), ONE controller call re-minting
    // every seed account at once is a live-venue supply change with no
    // sanctioned caller (scripts/seed.sh is the #dev seeder; play_start.sh,
    // deploy.sh and the fleets fund per account through setTestBalance,
    // which stays live). A trap, not a typed #err: the signature is a bare
    // Nat (THE RULE at requireDevHook — refuse in whichever way the
    // signature allows), and it mirrors seedInsuranceFund's refusal. The
    // gate reads the latch even for an empty batch, so a script may probe
    // it the way inject_history.sh probes injectHistoricalTrades. #dev is
    // unrestricted (the predicate's exhaustive switch, lib/Genesis.mo).
    if (Genesis.bulkSeedWindowClosed(posture, genesisLatched())) {
      Runtime.trap("bulkSetTestBalances: genesis window closed — a market has been enabled on this #play install, and a bulk balance seed after that point would re-mint every seed account into a live venue. Fund accounts one at a time via setTestBalance (the ratified live bootstrap tool, extNetFlow-recorded). Only a reinstall (a new venue) re-arms the window.");
    };
    var n : Nat = 0;
    for (entry in entries.vals()) {
      for (b in entry.balances.vals()) {
        let old = Accounts.getBalance(accounts, entry.principal, b.token);
        Accounts.setBalance(accounts, entry.principal, b.token, b.amount);
        recordFlow(entry.principal, b.token, (b.amount : Int) - (old : Int));
        n += 1;
      };
      Map.add(registeredUsers, Text.compare, Principal.toText(entry.principal), true);
      onRegistered(entry.principal);
    };
    n;
  };

  // Read a balance. SCOPED: your own, or anyone's if you are a controller or
  // the designated funding authority (task 1789609263: the fleet's refill
  // loop reads every bot's balance before deciding to refill it — an
  // authority that could mint but not read would see 0 and refill forever).
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
    if (not (Principal.equal(msg.caller, user) or Principal.isController(msg.caller) or isFundingAuthority(msg.caller))) { return 0 };
    Accounts.getBalance(accounts, user, token);
  };
};
