// fuel-mock — a DEV-ONLY stand-in for the ICP ledger + cycles-minting canister.
//
// Purpose (see the Stage-2 fuel block in src/backend/main.mo): the DEX's
// treasury→cycles loop ends in two mainnet canisters — the ICP ledger
// (icrc1_transfer) and the CMC (notify_top_up). This mock plays BOTH roles so
// the ENTIRE loop runs for real locally: cold_start wires setFuelRoute at this
// canister, the DEX transfers "ICP" here, notifies, and the mock actually
// deposit_cycles the DEX — so a test can assert a genuine cycle-balance rise.
//
// Fidelity notes:
//   • icrc1_transfer returns a monotonically increasing block index and
//     records (amount, to.subaccount) — like a ledger, minus balance checks
//     (the DEX's internal debit is the accounting under test, not ours);
//   • notify_top_up verifies the block exists, pays cycles ONCE per block
//     (a second notify → #Err, mirroring the real CMC's already-processed
//     refusal), and mints at a fixed RATE (1 ICP = 1T cycles — the right
//     order of magnitude; the real rate floats with the ICP/XDR price);
//   • unknown block → #Err(#InvalidTransaction);
//   • a deposit the mock's own balance can't fund → #Err(#Refunded), block
//     NOT consumed. The real CMC can never hit this branch — it MINTS
//     cycles and cannot be short — so there is no behaviour to mirror:
//     #Refunded is borrowed as the definitive-refusal shape the backend
//     saga clears its pending on (a TRAP here reads as a transport error
//     and wedges the saga forever — the 2026-08-06 incident), and keeping
//     the block unconsumed is the mock's stand-in for the real refund's
//     "funds stay recoverable": top the mock up, then
//     adminRetryFuelNotify(opt block) completes the SAME top-up, where
//     mainnet would re-transfer the refunded ICP as a new block.
// NEVER deploy to a value-bearing target: transfer is open and mints cycles.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Cycles "mo:core/Cycles";

actor {
  public type Icrc1TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };
  public type NotifyError = {
    #Refunded : { reason : Text; block_index : ?Nat64 };
    #InvalidTransaction : Text;
    #TransactionTooOld : Nat64;
    #Processing;
    #Other : { error_code : Nat64; error_message : Text };
  };

  transient let CYCLES_PER_E8S : Nat = 10_000;   // 1 ICP (1e8 e8s) → 1T cycles
  // Refusal margin: the attach ceiling is balance − freezing reserve (~30G
  // here) − call fees; 1T dwarfs both and keeps the mock alive afterwards.
  // Local cycles are free (icp canister top-up), so err on the refuse side.
  transient let DEPOSIT_MARGIN : Nat = 1_000_000_000_000;
  transient let ic00 = actor "aaaaa-aa" : actor {
    deposit_cycles : shared { canister_id : Principal } -> async ();
  };

  var nextBlock : Nat = 1;
  // block → (e8s received, consumed-by-notify)
  let blocks = Map.empty<Nat, { e8s : Nat; var consumed : Bool }>();

  // Test hook (W3-02): trap the NEXT transfers so the DEX's catch sees a
  // canister_error — the NOT-clean reject class its ambiguous interlock is
  // for. Trapping first line = no mock state changes either.
  var trapTransfers : Bool = false;
  public shared func setTrapTransfers(on : Bool) : async () { trapTransfers := on };

  // Test hook (#47.2): answer every notify with #Err(#Processing) — the real
  // CMC's "not settled yet" reply. The backend KEEPS its pending record on
  // this (the saga latch), which is exactly the stranded state whose
  // auto-retry test_fuel_topup §3c exercises. Block untouched: a later
  // notify with the mode off completes the SAME top-up, like the real CMC
  // finishing its processing.
  var processingNotifies : Bool = false;
  public shared func setProcessingNotifies(on : Bool) : async () { processingNotifies := on };

  public shared func icrc1_transfer(arg : {
    from_subaccount : ?Blob;
    to : { owner : Principal; subaccount : ?Blob };
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  }) : async { #Ok : Nat; #Err : Icrc1TransferError } {
    if (trapTransfers) { assert false };
    let block = nextBlock;
    nextBlock += 1;
    Map.add(blocks, Nat.compare, block, { e8s = arg.amount; var consumed = false });
    #Ok(block);
  };

  public shared func notify_top_up(arg : { block_index : Nat64; canister_id : Principal }) : async {
    #Ok : Nat; #Err : NotifyError;
  } {
    if (processingNotifies) { return #Err(#Processing) };
    switch (Map.get(blocks, Nat.compare, Nat64.toNat(arg.block_index))) {
      case null { #Err(#InvalidTransaction("no such block")) };
      case (?b) {
        if (b.consumed) { return #Err(#InvalidTransaction("block already processed")) };
        let cycles = b.e8s * CYCLES_PER_E8S;
        let bal = Cycles.balance();
        if (bal < cycles + DEPOSIT_MARGIN) {
          // Definitive refusal, block kept unconsumed — fidelity note above.
          return #Err(#Refunded({
            reason = "insufficient mock cycles: deposit " # Nat.toText(cycles)
              # " + margin " # Nat.toText(DEPOSIT_MARGIN) # " > balance " # Nat.toText(bal)
              # "; block kept — top up the fuel-mock, then adminRetryFuelNotify(opt block)";
            block_index = ?arg.block_index;
          }));
        };
        b.consumed := true;
        await (with cycles = cycles) ic00.deposit_cycles({ canister_id = arg.canister_id });
        #Ok(cycles);
      };
    };
  };
}
