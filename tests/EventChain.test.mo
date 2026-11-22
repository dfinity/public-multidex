// Unit tests for src/backend/lib/EventChain.mo — the tamper-evidence hash
// over permanent user-history events (archive-design.md Phase D).
//
// These are the UNIT HALF of W2-01's perturbation proof. verifyChain
// (ArchiveCanister.mo) anchors the recomputed tail hash to the certified
// chainHead, so "corrupting the newest stored event flips ok to false"
// decomposes into:
//   (a) the endpoint compares hash(last event) against the certified head —
//       asserted behaviourally on a SEALED archive by test_archive_chain.sh
//       (sealed segments never append, so those assertions are
//       deterministic forever), and
//   (b) the hash is sensitive to every field of the record — asserted HERE.
// A dev corruption hook on the archive itself was rejected: the permanent
// append-only ledger canister should not carry a tamper-with-me endpoint,
// posture-gated or not.
//
// ── Cross-encoder equivalence (#44.4 residual) ──────────────────────
// EventChain itself has NOT been untested since W2-01 (this file), and the
// standalone verifier is exercised by tests/test_verify_ledger_gate.sh
// (W5-09). The residual gap #44.4 closes is MIRROR DIVERGENCE: three
// hand-written copies of the frozen v1 canonical form exist —
//   1. src/backend/lib/EventChain.mo            (this module — the origin)
//   2. src/frontend/src/ledger.js               canonicalEvent()/hashEvent()
//   3. scripts/verify_ledger.mjs                canonical()/hashEvent()
// — and nothing asserted they produce IDENTICAL BYTES for the same event.
// The MDX-VECTORS pin below is the bridge: it was PRODUCED by this Motoko
// module (one vector per event kind + header/format variants), this test
// re-asserts the Motoko encoder still produces it, and
// tests/eventchain_equivalence.test.mjs parses the same pin out of this
// file and asserts BOTH JavaScript mirrors reproduce every byte. Any one
// encoder drifting in field order/format goes red in mops test (Motoko)
// or the node suite (either JS mirror). Regenerate the pin ONLY on a
// deliberate format version bump (empty the list; this test prints the
// fresh tuples), and update the .mjs fixture twins in the same commit.

import EventChain "../src/backend/lib/EventChain";
import Types "../src/backend/lib/Types";
import Principal "mo:core/Principal";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Text "mo:core/Text";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

let alice = Principal.fromText("2vxsx-fae");
let bob = Principal.fromText("aaaaa-aa");

func fill(marketId : Text, side : Types.Side, price : Nat, qty : Nat, orderId : Nat, tradeId : Nat) : Types.UserEventKind {
  #fill({ marketId; side; price; qty; orderId; tradeId });
};
func mk() : Types.UserEvent = {
  seq = 7; ts = 1_000_000; user = alice; counterparty = null;
  kind = fill("ICP-ICPUSD", #buy, 10, 3, 1, 2);
  prevHash = null;
};
let base = mk();
let h = EventChain.hash(base);

Debug.print("── EventChain.test ──");

// ── shape ──
truth("hash is deterministic (same fields → same hash)", EventChain.hash(mk()) == h);
truth("hash is 32 bytes", h.size() == 32);

// ── every header field perturbs the hash ──
truth("seq perturbs",  EventChain.hash({ base with seq = 8 }) != h);
truth("ts perturbs",   EventChain.hash({ base with ts = 1_000_001 }) != h);
truth("user perturbs", EventChain.hash({ base with user = bob }) != h);
truth("counterparty perturbs (null → some)", EventChain.hash({ base with counterparty = ?bob }) != h);
truth("prevHash perturbs (each hash commits to all history)", EventChain.hash({ base with prevHash = ?h }) != h);

// ── the kind payload perturbs the hash ──
truth("payload price perturbs",  EventChain.hash({ base with kind = fill("ICP-ICPUSD", #buy, 11, 3, 1, 2) }) != h);
truth("payload qty perturbs",    EventChain.hash({ base with kind = fill("ICP-ICPUSD", #buy, 10, 4, 1, 2) }) != h);
truth("payload side perturbs",   EventChain.hash({ base with kind = fill("ICP-ICPUSD", #sell, 10, 3, 1, 2) }) != h);
truth("payload market perturbs", EventChain.hash({ base with kind = fill("BTC-ICPUSD", #buy, 10, 3, 1, 2) }) != h);
truth("payload orderId perturbs", EventChain.hash({ base with kind = fill("ICP-ICPUSD", #buy, 10, 3, 9, 2) }) != h);
truth("payload tradeId perturbs", EventChain.hash({ base with kind = fill("ICP-ICPUSD", #buy, 10, 3, 1, 9) }) != h);
truth("kind tag perturbs",       EventChain.hash({ base with kind = #borrow({ token = "ICP"; amount = 1 }) }) != h);

// ── netstring framing: a boundary shift cannot alias two field lists ──
// "ICP-ICPUSD" + orderId 1 vs "ICP-ICPUSD1" + a colliding neighbour would
// concatenate identically WITHOUT length prefixes; with them the hashes
// must differ.
truth("field-boundary shift cannot collide",
  EventChain.hash({ base with kind = fill("ICP-ICPUSD1", #buy, 10, 3, 1, 2) })
  != EventChain.hash({ base with kind = fill("ICP-ICPUSD", #buy, 10, 3, 11, 2) }));

// ── #config (#47.4) — both Text fields perturb, and frame independently ──
truth("config setter perturbs",
  EventChain.hash({ base with kind = #config({ setter = "setBridge"; value = "x" }) })
  != EventChain.hash({ base with kind = #config({ setter = "setAutoFuel"; value = "x" }) }));
truth("config value perturbs",
  EventChain.hash({ base with kind = #config({ setter = "setAutoFuel"; value = "enabled" }) })
  != EventChain.hash({ base with kind = #config({ setter = "setAutoFuel"; value = "disabled" }) }));
truth("config setter/value boundary cannot alias",
  EventChain.hash({ base with kind = #config({ setter = "setAutoFuelen"; value = "abled" }) })
  != EventChain.hash({ base with kind = #config({ setter = "setAutoFuel"; value = "enabled" }) }));

// ── the chain property the anchor stands on ──
// A successor commits to its predecessor's hash; re-deriving the head over
// the pair reproduces it, and perturbing the FIRST event changes the head
// derived at the SECOND — the transitivity verifyChain's tail anchor uses.
let e2 = { base with seq = 8; prevHash = ?h };
let head = EventChain.hash(e2);
let basePerturbed = { base with ts = 999 };
let e2OverPerturbed = { base with seq = 8; prevHash = ?EventChain.hash(basePerturbed) };
truth("head over a perturbed predecessor differs", EventChain.hash(e2OverPerturbed) != head);
truth("recomputing the same pair reproduces the head", EventChain.hash({ base with seq = 8; prevHash = ?EventChain.hash(mk()) }) == head);

// ── Frozen v1 canonical vectors (#44.4 — the cross-encoder pin) ──────
// One fixture per event kind, plus header variants (prevHash set,
// counterparty set), every variant tag branch (deposit/withdrawal, all four
// order statuses, market/limit, buy/sell), negative Int payloads, and both
// basket shapes. tests/eventchain_equivalence.test.mjs MIRRORS this exact
// list — edit both together, in the same order, with the same values.
let prev32 = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) }));
func ev(kind : Types.UserEventKind) : Types.UserEvent = {
  seq = 7; ts = 1_723_456_789_000_000_123; user = alice; counterparty = null; kind; prevHash = null;
};
let fixtures : [(Text, Types.UserEvent)] = [
  ("fill-buy", ev(#fill({ marketId = "ICP-ICPUSD"; side = #buy; price = 105_000_000; qty = 250_000_000; orderId = 42; tradeId = 9_001 }))),
  ("fill-sell-linked", { seq = 8; ts = 1_723_456_789_000_000_124; user = alice; counterparty = ?bob; prevHash = ?prev32;
    kind = #fill({ marketId = "BTC-ICPUSD"; side = #sell; price = 6_500_000_000_000; qty = 1_000; orderId = 7; tradeId = 8 }) }),
  ("deposit", ev(#deposit({ token = "ICP"; amount = 500_000_000; timestamp = 1_723_000_000_000_000_000; kind = #deposit }))),
  ("withdrawal", ev(#deposit({ token = "USDT"; amount = 25_000_000; timestamp = 1_723_000_000_000_000_001; kind = #withdrawal }))),
  ("orderClosed-filled-market", ev(#orderClosed({ id = 11; marketId = "ICP-ICPUSD"; side = #buy; orderType = #market; price = 100_000_000; quantity = 3_000_000; filled = 3_000_000; status = #filled; placedAt = 1_723_000_000_000_000_002; closedAt = 1_723_000_000_000_000_003 }))),
  ("orderClosed-cancelled-limit", ev(#orderClosed({ id = 12; marketId = "BTC-ICPUSD"; side = #sell; orderType = #limit; price = 99_000_000; quantity = 5; filled = 0; status = #cancelled; placedAt = 1_723_000_000_000_000_004; closedAt = 1_723_000_000_000_000_005 }))),
  ("orderClosed-open-market", ev(#orderClosed({ id = 13; marketId = "ICP-ICPUSD"; side = #buy; orderType = #market; price = 1; quantity = 2; filled = 1; status = #open; placedAt = 1_723_000_000_000_000_006; closedAt = 1_723_000_000_000_000_007 }))),
  ("orderClosed-partial-limit", ev(#orderClosed({ id = 14; marketId = "ICP-ICPUSD"; side = #sell; orderType = #limit; price = 42; quantity = 10; filled = 4; status = #partiallyFilled; placedAt = 1_723_000_000_000_000_008; closedAt = 1_723_000_000_000_000_009 }))),
  ("liquidation", ev(#liquidation({ user = bob; debtToken = "USDT"; debtRepaid = 1_000_000; debtRepaidUsd = 1_000_000; collateralToken = "ICP"; collateralSeized = 120_000; proceedsUsd = 1_050_000; penaltyUsd = 50_000; healthBefore = 95_000_000; healthAfter = 101_000_000; timestamp = 1_723_000_000_000_000_010 }))),
  ("borrow", ev(#borrow({ token = "ICP"; amount = 77_000 }))),
  ("repay", ev(#repay({ token = "USDT"; amount = 88_000 }))),
  ("lpDeposit", ev(#lpDeposit({ marketId = "ICP-ICPUSD"; baseAmount = 1_000; quoteAmount = 2_000; lpMinted = 1_414 }))),
  ("lpWithdraw-basket2", ev(#lpWithdraw({ lpBurned = 500; basket = [("ICP", 300), ("USDT", 600)] }))),
  ("lpWithdraw-empty", ev(#lpWithdraw({ lpBurned = 1; basket = [] }))),
  ("insuranceStake", ev(#insuranceStake({ amountUsd = 10_000_000; shares = 9_999 }))),
  ("insuranceUnstake", ev(#insuranceUnstake({ shares = 9_999; payoutUsd = 10_100_000 }))),
  ("delta-negative", ev(#delta({ token = "ICP"; amount = -123_456_789 }))),
  ("debtDelta-negative", ev(#debtDelta({ token = "USDT"; amount = -1 }))),
  ("lpShareDelta-negative", ev(#lpShareDelta({ marketId = "ICP-ICPUSD"; amount = -42 }))),
  ("insShareDelta-positive", ev(#insShareDelta({ amount = 314_159 }))),
  ("gap", ev(#gap({ fromSeq = 1_000; toSeq = 2_000 }))),
  ("config", ev(#config({ setter = "setAutoFuel"; value = "disabled" }))),
];

let hexDigits : [Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
func hexOf(b : Blob) : Text {
  var t = "";
  for (byte in b.values()) {
    let n = Nat8.toNat(byte);
    t #= Text.fromChar(hexDigits[n / 16]) # Text.fromChar(hexDigits[n % 16]);
  };
  t;
};

// The pin. (name, canonical bytes hex, sha256 hash hex) — produced by THIS
// module; parsed textually by tests/eventchain_equivalence.test.mjs, which
// holds both JS mirrors to the same bytes. Do not hand-edit the hex.
// MDX-VECTORS-BEGIN
let vectors : [(Text, Text, Text)] = [
  ("fill-buy", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a343a66696c6c31303a4943502d494350555344333a627579393a313035303030303030393a323530303030303030323a3432343a39303031", "05d53c4441bb9732b22af6b2deccfe7b6084f928f831aae0348be59cdab073ee"),
  ("fill-sell-linked", "323a763133323a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f313a3831393a31373233343536373839303030303030313234393a32767873782d666165383a61616161612d6161343a66696c6c31303a4254432d494350555344343a73656c6c31333a36353030303030303030303030343a31303030313a37313a38", "46d479516026a57b6c036bb3add4119bb176deae316002ef8d8669d1d2b85bc9"),
  ("deposit", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a373a6465706f736974333a494350393a35303030303030303031393a31373233303030303030303030303030303030", "7bf40c2b33d7d64c827602e1cee67b0c9c1cf8dce16ec7bbce8b0a048013ca82"),
  ("withdrawal", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31303a7769746864726177616c343a55534454383a323530303030303031393a31373233303030303030303030303030303031", "92737d6a0625cfc6ae9cfe11693628d662664ef7a1058c8202a54011223417f0"),
  ("orderClosed-filled-market", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31313a6f72646572436c6f736564323a313131303a4943502d494350555344333a627579363a6d61726b6574393a313030303030303030373a33303030303030373a33303030303030363a66696c6c656431393a3137323330303030303030303030303030303231393a31373233303030303030303030303030303033", "17fa93f101d2d4a1cf4683e769f054041127dfaf2e90a16391a3e33e3a96aba0"),
  ("orderClosed-cancelled-limit", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31313a6f72646572436c6f736564323a313231303a4254432d494350555344343a73656c6c353a6c696d6974383a3939303030303030313a35313a30393a63616e63656c6c656431393a3137323330303030303030303030303030303431393a31373233303030303030303030303030303035", "eb4ae99ca96ce0e65b36efb29d0026eee9a9145c27d9af4856509f09839c3461"),
  ("orderClosed-open-market", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31313a6f72646572436c6f736564323a313331303a4943502d494350555344333a627579363a6d61726b6574313a31313a32313a31343a6f70656e31393a3137323330303030303030303030303030303631393a31373233303030303030303030303030303037", "3ec3d5c9d9cbea582c3637061e1959eaeb2b07edcd01e6e926ca1af8b251ab2c"),
  ("orderClosed-partial-limit", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31313a6f72646572436c6f736564323a313431303a4943502d494350555344343a73656c6c353a6c696d6974323a3432323a3130313a3431353a7061727469616c6c7946696c6c656431393a3137323330303030303030303030303030303831393a31373233303030303030303030303030303039", "d0d63660050c2d1475a2aaf310d751c6f392b32abf72fb4316dd89627834e5c5"),
  ("liquidation", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31313a6c69717569646174696f6e383a61616161612d6161343a55534454373a31303030303030373a31303030303030333a494350363a313230303030373a31303530303030353a3530303030383a3935303030303030393a31303130303030303031393a31373233303030303030303030303030303130", "4596a6826a5a24c06d40701cf10515a2a856d1a48b1e03bf0502f3599c449f06"),
  ("borrow", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a363a626f72726f77333a494350353a3737303030", "6b817fb5066caf647e52a4f2038e9f85d7e1d744cfbdbfe3678913ae937a4f4a"),
  ("repay", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a353a7265706179343a55534454353a3838303030", "0987aee6a36be13ea2b7eb4689f7991a186d248f613cd65fa26bb8a99e763ea9"),
  ("lpDeposit", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a393a6c704465706f73697431303a4943502d494350555344343a31303030343a32303030343a31343134", "870ee240ce5d5f9900154d71e855dc70ca0f5fa290bd15cac58519c06b5e5f8e"),
  ("lpWithdraw-basket2", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31303a6c705769746864726177333a353030313a32333a494350333a333030343a55534454333a363030", "902ba0c039d38b665346edc4480e0855f0c00ba1efb5afd6a107cb2a6b438a0b"),
  ("lpWithdraw-empty", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31303a6c705769746864726177313a31313a30", "633121966e67981c5f9b17be95365d88aaee507907f0cfa8e648f4ea0a86f84b"),
  ("insuranceStake", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31343a696e737572616e63655374616b65383a3130303030303030343a39393939", "fc8651d8b4e270974e0783058b09d2c61c4d5abda24b4bd3a04b103f5f1da819"),
  ("insuranceUnstake", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31363a696e737572616e6365556e7374616b65343a39393939383a3130313030303030", "8366b94c91a24909bc2c66e574b4c0eaff11174673d2218b9be6fbb81ffcfef1"),
  ("delta-negative", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a353a64656c7461333a49435031303a2d313233343536373839", "aa3b08e9968b2147a7501c922591e656f1f5f54b070337c2cfb951fc49341b21"),
  ("debtDelta-negative", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a393a6465627444656c7461343a55534454323a2d31", "c8c27163f67ee2c47aa35f8d1d83759e3d3cf7574d629abed12b45f5e14b8856"),
  ("lpShareDelta-negative", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31323a6c70536861726544656c746131303a4943502d494350555344333a2d3432", "5f8723cb25a75e86b43142feb6265666aec2c47c4adf2dd12e737e485a59904b"),
  ("insShareDelta-positive", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a31333a696e73536861726544656c7461363a333134313539", "95f7c16f43d45a9d1fcdb7b989e8f0ebf39aae845e18eba04b2e35be66733f78"),
  ("gap", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a333a676170343a31303030343a32303030", "f84eeed8c8d59c5b75c8d29da83c5121f0d581ea2d86a16d9a8cb81b13d08883"),
  ("config", "323a7631303a313a3731393a31373233343536373839303030303030313233393a32767873782d666165303a363a636f6e66696731313a7365744175746f4675656c383a64697361626c6564", "722d7d14cc20db5effd23a337007d1d6367c8309f1414ba0c11467588fb249b8"),
];
// MDX-VECTORS-END

if (vectors.size() != fixtures.size()) {
  Debug.print("  pin out of date (" # Nat.toText(vectors.size()) # " pinned, " # Nat.toText(fixtures.size()) # " fixtures) — fresh Motoko-produced vectors:");
  for ((name, e) in fixtures.values()) {
    Debug.print("  (\"" # name # "\", \"" # hexOf(EventChain.canonical(e)) # "\", \"" # hexOf(EventChain.hash(e)) # "\"),");
  };
  Runtime.trap("FAIL: canonical vector pin does not cover the fixtures — paste the tuples printed above into MDX-VECTORS");
};
var vi = 0;
while (vi < fixtures.size()) {
  let (name, e) = fixtures[vi];
  let (pinName, pinCanon, pinHash) = vectors[vi];
  if (name != pinName) { Runtime.trap("FAIL: vector " # Nat.toText(vi) # " name mismatch: fixture '" # name # "' vs pin '" # pinName # "'") };
  let gotCanon = hexOf(EventChain.canonical(e));
  let gotHash = hexOf(EventChain.hash(e));
  if (gotCanon != pinCanon or gotHash != pinHash) {
    Debug.print("  ✗ " # name # " drifted from the frozen v1 pin");
    Debug.print("    pinned: (\"" # pinName # "\", \"" # pinCanon # "\", \"" # pinHash # "\"),");
    Debug.print("    actual: (\"" # name # "\", \"" # gotCanon # "\", \"" # gotHash # "\"),");
    Runtime.trap("FAIL: canonical form drifted at vector '" # name # "' — the v1 format is FROZEN; if this is a deliberate version bump, regenerate the pin AND the two JS mirrors together");
  };
  vi += 1;
};
truth("all " # Nat.toText(fixtures.size()) # " canonical vectors match the frozen v1 pin", true);

Debug.print("EventChain.test: all green");
