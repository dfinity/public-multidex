// Bridge canister — DUMMY / STUB.
//
// This is a DEV STUB so the frontend Deposit page and the DEX↔Bridge integration
// contract can be built and demoed end-to-end. The REAL custody logic — threshold-
// derived per-user addresses, the Chain-Key System, confirmation tracking, sweeps,
// withdrawals — is NOT implemented here; that is a separate team's job, on a
// separate branch. See docs/bridge-and-cks-design.md for the full design.
//
// What IS real here:
//   • the public interface the frontend talks to (createDepositAddress /
//     getMyDeposits / claim),
//   • the DEX integration: claim → DEX.creditAndRegister (an INTER-CANISTER call,
//     which bypasses the DEX's caller-only `inspect`, so the user is registered
//     off-ingress — exactly as the inspect gate assumes),
//   • the two-ledger accounting shape (credit axis: cumulative confirmed inflow vs
//     claimed; the location axis is out of scope for the stub).
//
// What is FAKE here:
//   • addresses are deterministic faux strings, not real chain addresses,
//   • dev-only devSimulateDeposit / devConfirmDeposits stand in for real external-
//     chain deposits + confirmations. The real Bridge has no such methods.

import Map "mo:core/Map";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Error "mo:core/Error";
import Cycles "mo:core/Cycles";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Char "mo:core/Char";
import Blob "mo:core/Blob";
import List "mo:core/List";

persistent actor Bridge {

  // ── Deployment posture ───────────────────────────────────────────
  // MIRRORS the DEX's posture axis (src/backend/main.mo — same type, same
  // committed default, same `transient` reasoning). The Bridge had NO posture
  // concept at all: devSimulateDeposit/devConfirmDeposits were labelled
  // "DEV ONLY" in a comment and gated by nothing, and their only real
  // restraint was the DEX's playDepositCap() — which is active on #play but
  // returns null on BOTH #dev and #production. So on a flip to #production
  // these methods (and the claim they feed) would mint UNCAPPED balance into
  // a value-bearing DEX, and icp.yaml wires this same stub into both
  // production-facing targets (`engine` and `subnet`/multidex.ai). The gate
  // now lives here rather than being outsourced.
  //
  // `transient` is load-bearing exactly as on the DEX: a plain `let` in a
  // `persistent actor` is implicitly STABLE, so an edited literal would be
  // silently overwritten by the stored value on `--mode upgrade` and the flip
  // would never land. Transient re-evaluates on install AND upgrade.
  //
  // The DEX also derives an IS_DEV from this literal; the Bridge did not
  // until devTestStrandAdmission (below) needed a #dev-only gate — the
  // on-ramp itself stays live on #play (see requireNotProduction below for
  // why that line sits at #production). A declared-but-unread constant is a
  // dead binding — moc says so itself, M0194 — so IS_DEV exists exactly
  // because one hook reads it; nothing on the user path may.
  public type DeployMode = { #dev; #play; #production };
  transient let DEPLOY_MODE : DeployMode = #play;
  transient let IS_PRODUCTION : Bool = DEPLOY_MODE == #production;
  transient let IS_DEV : Bool = DEPLOY_MODE == #dev;

  // THE RULE for every posture gate, copied from the DEX's requireDevHook:
  // refuse LOUDLY, in whichever way the signature allows — a typed #err where
  // there is a Result channel, a trap where there is not. Never a silent
  // return.
  //
  // WHY THE LINE IS AT #production AND NOT AT #dev. The `dev` prefix on these
  // two methods is a naming fossil: devSimulateDeposit is the LIVE #play
  // on-ramp. It is what the Deposit page calls (src/frontend/src/main.js), it
  // is what drives the play allowance (DEX playDepositReserve →
  // playDepositCap → PLAY_DEPOSIT_CAP_USD, which is ONLY non-null on #play),
  // and tests/test_play_deposit_cap.sh exercises it on that posture. Gating
  // it to #dev would delete the only on-ramp the committed default posture
  // has. The hole the gate must close is the UNCAPPED posture — #production,
  // where playDepositCap() returns null and nothing else stands between an
  // authenticated caller and freshly minted DEX balance.
  func requireNotProduction(name : Text) : { #ok; #err : Text } {
    if (IS_PRODUCTION) {
      return #err(name # " is disabled on #production: this Bridge is a STUB with no custody behind it, so any balance it credits would be unbacked. Deploy the real chain-key Bridge (docs/bridge-and-cks-design.md) before flipping the posture.");
    };
    #ok;
  };

  // Depositable assets = the DEX's token ids. ICPUSD stands in for a USD
  // stablecoin (e.g. USDC). transient: a tunable constant, reset on upgrade.
  transient let ASSETS : [Text] = ["BTC", "ETH", "SOL", "ICP", "ICPUSD"];

  // ASSETS was declared and never used as a membership test, and there is no
  // length check anywhere in this file — so an arbitrary Text went straight
  // into a permanent map key on both write paths. Every entry point that can
  // reach `ledgers` validates through here FIRST.
  func isSupportedAsset(asset : Text) : Bool {
    for (a in ASSETS.vals()) { if (a == asset) { return true } };
    false;
  };

  // Per-(user, asset) deposit ledger — the CREDIT axis. `confirmed` is cumulative
  // confirmed inflow (monotonic); `pending` is simulated-but-unconfirmed; `claimed`
  // is the high-water mark so claims are idempotent.
  type Ledger = { var confirmed : Nat; var pending : Nat; var claimed : Nat };
  let ledgers = Map.empty<Text, Ledger>();          // key = principal # "#" # asset

  let onboarded = Map.empty<Text, Bool>();          // users who created their addresses

  // IN-FLIGHT GUARD — cleared by postupgrade, see the note there.
  let claiming  = Map.empty<Text, Bool>();          // reentrancy guard per (user, asset)

  // Play-allowance admission bookkeeping (see devSimulateDeposit): cumulative
  // units the DEX has admitted per (user, asset) — the admission seq — plus a
  // per-(user, asset) guard so two concurrent simulates can't race the seq
  // read across the await (identical seqs would make the DEX no-op the
  // second debit while both deposits get created).
  let admittedUnits = Map.empty<Text, Nat>();
  let admitting     = Map.empty<Text, Bool>();      // in-flight guard — cleared by postupgrade

  // H-26 (F41): the WIPE-PENDING FENCE. adminSeasonWipe refuses while any
  // claim or admission is mid-flight, and the DEX's resetSeason aborts on
  // that refusal — so a sustained stream of admissions (any keypair can
  // start one; eligibility is judged DEX-side, one round trip later) could
  // keep the venue-global interlock occupied for every retry the operator
  // made. A refused wipe now ARMS this flag: NEW claims and admissions are
  // refused with a typed #err until a wipe completes (or a controller
  // cancels), so the in-flight ones drain within one DEX round trip and the
  // next attempt finds the interlock free. Deliberately STABLE (a plain
  // `var` in a persistent actor): a wipe the operator armed must survive the
  // Bridge upgrade that may sit between two reset attempts — an upgrade
  // clears the in-flight guards (postupgrade), never the operator's intent.
  var wipePending : Bool = false;

  // The DEX we credit into, set by a controller after deploy (setDex).
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

  // Only the DEX methods we call. Must match the DEX's signatures exactly.
  type DexActor = actor {
    // seq = this claim's post-credit cumulative `claimed` (monotonic per
    // user+asset); the DEX no-ops any seq it has already applied, so a
    // lost-reply retry of this call can never double-credit. The trailing
    // ?Nat is our PENDING units for (user, asset) at claim time: the DEX's
    // reservation covers admitted-but-uncredited units, pending ones
    // included, and a claim only ever covers confirmed units (claimable and
    // pending are disjoint) — so the DEX fences the pending's units off from
    // the reservation this claim consumes (3088472021). Candid-additive (opt).
    creditAndRegister : (Principal, Text, Nat, Nat, ?Nat) -> async { #ok; #err : Text };
    // seq = this admission's post-admit cumulative admitted units (monotonic
    // per user+asset, same discipline as the claim seq); the DEX no-ops any
    // seq it has already applied, so a lost-reply retry can never double-
    // consume the play allowance.
    playDepositReserve : (Principal, Text, Nat, Nat) -> async { #ok; #err : Text };
    // #55: the reservation view devConfirmDeposits reconciles a written-ahead
    // pending against before it becomes claimable. `admitSeq` is the last
    // admission seq the DEX APPLIED for (user, token); our admittedUnits
    // running ahead of it names exactly the units the DEX never reserved.
    playDepositReservation : shared query (Principal, Text) -> async { #ok : { capActive : Bool; reservedUnits : Nat; admitSeq : Nat }; #err : Text };
  };

  func key(user : Principal, asset : Text) : Text { Principal.toText(user) # "#" # asset };

  func requireAuth(caller : Principal) {
    if (Principal.isAnonymous(caller)) { Runtime.trap("Authentication required") };
  };
  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  func ledgerOf(user : Principal, asset : Text) : Ledger {
    let k = key(user, asset);
    switch (Map.get(ledgers, Text.compare, k)) {
      case (?l) { l };
      case null { let l : Ledger = { var confirmed = 0; var pending = 0; var claimed = 0 }; Map.add(ledgers, Text.compare, k, l); l };
    };
  };

  // H-26 (F40): a refused admission must leave the stable maps IDENTICAL to
  // their pre-call state. The write-ahead (W3-04) get-or-creates the counter
  // and the Ledger row before the DEX's verdict; the rollback restored their
  // VALUES but never deleted the rows it had created, so every refused
  // first-time deposit — every unbound keypair, on demand — left two
  // permanent zero rows per asset, reclaimable only by the season wipe. An
  // absent counter reads as 0 and an absent Ledger reads as all-zero
  // (Option.get / getMyDeposits both say so), so deleting a zero-valued row
  // is a pure no-op semantically and the only way to make refusal free.
  // Never called on a key that is mid-flight: a held admission carries
  // admitted + amount > 0 and pending > 0, so nothing here can match one.
  func pruneZeroRows(k : Text) {
    switch (Map.get(admittedUnits, Text.compare, k)) {
      case (?0) { ignore Map.delete(admittedUnits, Text.compare, k) };
      case _ {};
    };
    switch (Map.get(ledgers, Text.compare, k)) {
      case (?l) { if (l.confirmed == 0 and l.pending == 0 and l.claimed == 0) { ignore Map.delete(ledgers, Text.compare, k) } };
      case null {};
    };
  };

  transient let WIPE_PENDING_MSG : Text = "A season wipe is pending on the Bridge — new deposits and claims are paused until the season reset completes (the operator retries it once in-flight admissions settle)";

  // H-27 (F5-Bridge): the AMOUNT CEILING. `amount` is an unbounded Nat from
  // the caller, and until this gate the only bound was `amount == 0`. A
  // ~100 KB Nat sailed through the write-ahead and into the DEX's
  // playDepositReserve, whose refusal formats the valued amount through
  // Nat.toText — the per-decimal-digit bignum loop, Θ(bits²) — so the DEX
  // burned its whole 40 B instruction budget (~20 DTS rounds during which
  // nothing else ran) and trapped; the Bridge's catch arm (1788465034) rolls
  // its own writes back, but the DEX stall was reachable on demand by any
  // email-bound player. Now anything above 2^128 units is refused HERE,
  // before any state write and before the DEX call is even sent. 2^128 is
  // the ceiling H-15's brief names for the DEX side (kept in step so the two
  // halves agree): a fixed, price-independent constant that no real deposit
  // approaches (2^128 e8s of any asset is ~3.4e30 whole units), while the
  // comparison itself is a single bignum compare — linear in the caller's
  // bit length, not quadratic — and every value that passes it has at most
  // 39 decimal digits, so no downstream toText can ever be expensive again.
  // The refusal text deliberately does NOT echo the amount (formatting it is
  // the very cost this gate exists to avoid).
  transient let AMOUNT_CEILING : Nat = 2 ** 128;
  transient let AMOUNT_CEILING_MSG : Text = "Amount exceeds the Bridge deposit ceiling (2^128 units) — refused before admission; nothing was written and the DEX was not called";
  // Observability for the "no DEX call" property (H-27 verify): counts every
  // playDepositReserve the Bridge actually SENDS. Transient by design (a
  // diagnostic delta, not accounting): tests read it before/after a refused
  // call through getBridgeStats.
  transient var dexAdmitCalls : Nat = 0;

  // STUB address derivation. The real Bridge derives these under threshold ECDSA
  // (BTC/EVM) / Schnorr–Ed25519 (SOL) with the principal as the derivation path
  // (docs/bridge-and-cks-design.md §5). Here we instead synthesise a FORMAT-CORRECT
  // but FAKE address per chain: deterministic from the principal (stable across
  // calls) and shaped like the real thing (right prefix, charset, length) — but
  // with no valid checksum and no key behind it. Never send real funds to these.
  transient let HEX    : [Char] = ['0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'];
  transient let BECH32 : [Char] = ['q','p','z','r','y','9','x','8','g','f','2','t','v','d','w','0','s','3','j','n','5','4','k','h','c','e','6','m','u','a','7','l'];
  transient let BASE58 : [Char] = ['1','2','3','4','5','6','7','8','9','A','B','C','D','E','F','G','H','J','K','L','M','N','P','Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f','g','h','i','j','k','m','n','o','p','q','r','s','t','u','v','w','x','y','z'];

  // `n` deterministic chars from `alphabet`, seeded by the principal + a per-asset
  // salt (so each chain gets a distinct address). FNV-1a fold → xorshift64 stream.
  // NOT cryptographic — a dev stub only.
  func faux(p : Principal, salt : Nat64, alphabet : [Char], n : Nat) : Text {
    let base = Nat64.fromNat(alphabet.size());
    var h : Nat64 = 0xcbf29ce484222325 +% salt;
    for (b in Blob.toArray(Principal.toBlob(p)).vals()) {
      h := (h ^ Nat64.fromNat(Nat8.toNat(b))) *% 0x100000001b3;
    };
    var out = "";
    var i = 0;
    while (i < n) {
      h := h ^ (h << 13);
      h := h ^ (h >> 7);
      h := h ^ (h << 17);
      out #= Char.toText(alphabet[Nat64.toNat(h % base)]);
      i += 1;
    };
    out;
  };

  func fauxAddress(asset : Text, p : Principal) : Text {
    switch (asset) {
      case ("BTC")    { "bc1q" # faux(p, 1, BECH32, 38) };  // native SegWit (P2WPKH), 42 chars
      case ("ETH")    { "0x" # faux(p, 2, HEX, 40) };       // 20-byte EVM address
      case ("SOL")    { faux(p, 3, BASE58, 44) };           // base58 Ed25519 pubkey
      case ("ICP")    { faux(p, 4, HEX, 64) };              // ICP ledger AccountIdentifier (hex — NOT a principal)
      case ("ICPUSD") { "0x" # faux(p, 5, HEX, 40) };       // USDC (ERC-20 on Ethereum)
      case (_)        { faux(p, 9, HEX, 40) };
    };
  };

  // ── Admin wiring ────────────────────────────────────────────
  func cachedDex() : ?Principal {
    switch (dexPrincipal) { case (?p) { ?p }; case null { _envDexCache } };
  };
  public shared (msg) func setDex(p : Principal) : async () {
    requireController(msg.caller);
    dexPrincipal := ?p;
  };
  public query func getDex() : async ?Principal { cachedDex() };
  public query func getSupportedAssets() : async [Text] { ASSETS };

  // The Bridge's own posture, readable the same way and with the same
  // spelling as the DEX's getDeployMode. Deploy scripts and the pre-mainnet
  // checklist can now assert that the two agree instead of assuming it.
  public query func getDeployMode() : async Text {
    switch (DEPLOY_MODE) {
      case (#dev) { "dev" };
      case (#play) { "play" };
      case (#production) { "production" };
    };
  };

  // ── Addresses ───────────────────────────────────────────────
  public type ChainAddress = { chain : Text; asset : Text; address : Text };

  func addressesFor(p : Principal) : [ChainAddress] {
    [
      { chain = "Bitcoin";  asset = "BTC";    address = fauxAddress("BTC", p) },
      { chain = "Ethereum"; asset = "ETH";    address = fauxAddress("ETH", p) },
      { chain = "Solana";   asset = "SOL";    address = fauxAddress("SOL", p) },
      { chain = "ICP";      asset = "ICP";    address = fauxAddress("ICP", p) },
      { chain = "Ethereum"; asset = "ICPUSD"; address = fauxAddress("ICPUSD", p) },
    ];
  };

  // "Create deposit address" — really register/reveal (addresses are deterministic).
  public shared (msg) func createDepositAddress() : async [ChainAddress] {
    requireAuth(msg.caller);
    Map.add(onboarded, Text.compare, Principal.toText(msg.caller), true);
    addressesFor(msg.caller);
  };

  public query (msg) func getMyDepositAddresses() : async ?[ChainAddress] {
    if (Map.get(onboarded, Text.compare, Principal.toText(msg.caller)) == null) { return null };
    ?addressesFor(msg.caller);
  };

  // Self-reported cycle balance so the DEX's in-canister fuel watermark can
  // keep the Bridge alive WITHOUT controlling it (deposit_cycles needs no
  // controllership; canister_status does). The DEX calls this, and tops up
  // via deposit_cycles when it's low — see tickBridgeFuel in the backend.
  // Any real Bridge implementation should expose the same method to opt into
  // DEX-side fuelling; without it the DEX feeder no-ops and the operator
  // top-up script is the fuel source.
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // ── Deposit views ───────────────────────────────────────────
  public type DepositView = {
    asset : Text; chain : Text; address : Text;
    confirmed : Nat; pending : Nat; claimed : Nat; claimable : Nat;
  };

  public query (msg) func getMyDeposits() : async [DepositView] {
    let addrs = addressesFor(msg.caller);
    Iter.toArray(Iter.map<ChainAddress, DepositView>(addrs.vals(), func(a) {
      let l = switch (Map.get(ledgers, Text.compare, key(msg.caller, a.asset))) {
        case (?x) { x }; case null { { var confirmed = 0; var pending = 0; var claimed = 0 } };
      };
      // The guard proves confirmed > claimed in this branch, so the
      // subtraction cannot underflow — annotated `: Nat` rather than clamped
      // (W5-18): a subOrZero here would silently absorb a future break of
      // the confirmed ≥ claimed accounting invariant, and we want that loud.
      let claimable = if (l.confirmed > l.claimed) { ((l.confirmed - l.claimed) : Nat) } else { 0 };
      { asset = a.asset; chain = a.chain; address = a.address;
        confirmed = l.confirmed; pending = l.pending; claimed = l.claimed; claimable };
    }));
  };

  // ── Claim ───────────────────────────────────────────────────
  // Credit the confirmed-but-unclaimed amount into the user's DEX virtual wallet.
  // Idempotent (advances the `claimed` high-water mark only on success) and guarded
  // against concurrent re-entry (two in-flight claims could otherwise double-credit
  // across the await — the real Bridge needs the same saga discipline).
  public shared (msg) func claim(asset : Text) : async { #ok : Nat; #err : Text } {
    requireAuth(msg.caller);
    // FIRST statement after auth: an unvalidated asset must never reach a map
    // key. Without this, claim("<any junk>") was a permanent write.
    if (not isSupportedAsset(asset)) { return #err("Unsupported asset: " # asset) };
    switch (requireNotProduction("claim")) { case (#err(e)) { return #err(e) }; case (#ok) {} };
    // H-26 fence: a pending season wipe refuses NEW claims before the guard
    // is taken, so the in-flight ones drain and the wipe can land.
    if (wipePending) { return #err(WIPE_PENDING_MSG) };
    let dexP = switch (effectiveDex<system>()) { case (?p) { p }; case null { return #err("Bridge is not wired to a DEX yet") } };
    let k = key(msg.caller, asset);
    if (Map.get(claiming, Text.compare, k) != null) { return #err("A claim for " # asset # " is already in progress") };

    // READ-ONLY lookup, deliberately NOT ledgerOf. ledgerOf is get-or-CREATE,
    // and returning #err from an update method is a NORMAL RETURN, not a trap
    // — so the Map.add COMMITS. Calling it above the claimable==0 rejection
    // meant every no-op claim wrote a permanent ledger row. An absent row is
    // definitionally confirmed = claimed = 0, so it takes the same branch and
    // the caller sees the identical message; it just costs no state.
    let l = switch (Map.get(ledgers, Text.compare, k)) {
      case (?x) { x };
      case null { return #err("Nothing to claim for " # asset) };
    };
    // Guard-proven non-negative; annotated, not clamped — see the twin site
    // in getMyDeposits (W5-18).
    let claimable = if (l.confirmed > l.claimed) { ((l.confirmed - l.claimed) : Nat) } else { 0 };
    if (claimable == 0) { return #err("Nothing to claim for " # asset) };

    Map.add(claiming, Text.compare, k, true);
    let dex : DexActor = actor (Principal.toText(dexP));
    try {
      // Pass the post-claim high-water (l.claimed + claimable) as the DEX-side
      // idempotency key: on success we advance l.claimed to exactly this value,
      // so a retry after a lost #ok recomputes the SAME key and the DEX no-ops.
      // `?l.pending`: the units admitted but not yet confirmed — NOT part of
      // this claim, so the DEX must keep their reservation (see DexActor).
      // Read at send time: an admission that lands during the await adds to
      // both sides consistently (its reserve and its pending), and only an
      // EXCESS claim — a claimable larger than the reservation — can even
      // observe the difference.
      let r = await dex.creditAndRegister(msg.caller, asset, claimable, l.claimed + claimable, ?l.pending);
      ignore Map.delete(claiming, Text.compare, k);
      switch (r) {
        case (#ok) { l.claimed += claimable; #ok(claimable) };
        case (#err(e)) { #err("DEX credit failed: " # e) };
      };
    } catch (e) {
      ignore Map.delete(claiming, Text.compare, k);
      #err("DEX call failed: " # Error.message(e));
    };
  };

  // ── DEV ONLY (the real Bridge has NO such methods) ──────────
  // Stand in for real external-chain deposits + confirmations.
  //
  // Simulation is where the PLAY ALLOWANCE is exercised: before crediting the
  // pending amount we ask the DEX to ADMIT this deposit (playDepositReserve) —
  // the DEX values it at press-time marks, consumes that much of the user's
  // lifetime allowance up front, and reserves the units so the eventual claim
  // settles against the reservation with no re-valuation and can NEVER be
  // refused by the cap. A refused deposit is ROLLED BACK — on the DEX's
  // explicit #err and on a system-level rejection alike (the DEX stopped for
  // an upgrade is the routine one, #55) — and a pending the DEX never
  // reserved is dropped by devConfirmDeposits instead of becoming claimable,
  // so nothing unclaimable accumulates here. The admission seq (post-admit
  // cumulative admitted units) makes the call idempotent: if the DEX reserved
  // but our reply was lost, the user's retry recomputes the SAME seq and the
  // DEX no-ops instead of double-debiting the allowance.
  public shared (msg) func devSimulateDeposit(asset : Text, amount : Nat) : async { #ok; #err : Text } {
    requireAuth(msg.caller);
    // Validate the asset BEFORE anything can key a map with it (`admitting`,
    // `admittedUnits` and `ledgers` are all keyed on it below).
    if (not isSupportedAsset(asset)) { return #err("Unsupported asset: " # asset) };
    switch (requireNotProduction("devSimulateDeposit")) { case (#err(e)) { return #err(e) }; case (#ok) {} };
    if (amount == 0) { return #err("Amount must be positive") };
    // H-27: the ceiling sits with the other LOCAL checks — above the fence,
    // the wiring, the interlock, every write and the DEX call (see
    // AMOUNT_CEILING). Never format `amount` in a refusal below this line.
    if (amount > AMOUNT_CEILING) { return #err(AMOUNT_CEILING_MSG) };
    // H-26: EVERY eligibility check the Bridge can make locally — asset,
    // posture, amount, the wipe fence, DEX wiring — runs ABOVE the in-flight
    // guard and above any state write, so an ineligible call neither
    // occupies the interlock nor leaves a row. The one check that is not
    // local (the DEX's verified-binding gate, judged in playDepositReserve)
    // is what the fence exists for: a refused wipe pauses new admissions so
    // that stream cannot hold the interlock across the operator's retry.
    if (wipePending) { return #err(WIPE_PENDING_MSG) };
    switch (effectiveDex<system>()) {
      case (?dexP) {
        let k = key(msg.caller, asset);
        if (Map.get(admitting, Text.compare, k) != null) { return #err("A deposit for " # asset # " is already in progress") };
        let admitted = Option.get(Map.get(admittedUnits, Text.compare, k), 0);
        Map.add(admitting, Text.compare, k, true);
        // WRITE-AHEAD (W3-04, #27.2): commit the counter AND the pending
        // credit BEFORE the yield, and roll both back only on the DEX's
        // explicit #err. Behind-the-yield writes are lost whenever the
        // continuation does not run to its assignment — W3-04 told that as an
        // upgrade landing in the await window, a routine deploy; #55 (d)
        // measured that an upgrade cannot land inside an await on this
        // toolchain (the Motoko runtime refuses it while the DEX call is
        // outstanding — the upgrade lands only once the message is done), so
        // the shape that is real is a continuation that traps after the DEX
        // reserved. Then: postupgrade cleared `admitting`, the user retried,
        // the retry computed a DIFFERENT seq, and the DEX's replay gate —
        // keyed on seq — debited the lifetime allowance a second time for
        // units already admitted once. Write-ahead is safe on the ADMIT side
        // specifically because the reserve is amount-based: a SKIPPED seq
        // range costs nothing, while a repeated one double-reserves. On an
        // ambiguous transport failure both writes are KEPT (the DEX may
        // have committed; if it did not, the skipped range costs nothing
        // and the deposit shows as pending without an allowance charge —
        // the user-favorable direction, not reachable on demand from
        // outside). Do NOT mirror any of this onto claim(): its counter is
        // a slice base (`seq − prevSeq`), where advancing early loses funds.
        Map.add(admittedUnits, Text.compare, k, admitted + amount);
        let l = ledgerOf(msg.caller, asset);
        l.pending += amount;
        let dex : DexActor = actor (Principal.toText(dexP));
        dexAdmitCalls += 1;   // H-27 observability: a SENT admission, counted at the send
        try {
          switch (await dex.playDepositReserve(msg.caller, asset, amount, admitted + amount)) {
            case (#err(e)) {
              // Explicit refusal: the DEX committed nothing — roll BOTH back.
              // (devConfirmDeposits skips assets mid-admission, so the
              // written-ahead pending cannot have been confirmed under us.)
              Map.add(admittedUnits, Text.compare, k, admitted);
              l.pending := if (l.pending >= amount) { l.pending - amount } else { 0 };
              ignore Map.delete(admitting, Text.compare, k);
              // H-26 (F40): rows the write-ahead CREATED for this call go
              // too — a refusal leaves the maps exactly as it found them.
              pruneZeroRows(k);
              return #err(e);
            };
            case (#ok) {};
          };
        } catch (e) {
          // SYSTEM-LEVEL rejection (#55 "phantom pending"): the DEX did not
          // run — a stopped canister (every DEX upgrade goes through a stop),
          // an absent target, a full queue — so nothing was reserved and
          // nothing debited, and the write-aheads roll back exactly as on an
          // explicit #err. KEEPING them here was the hole: devConfirmDeposits
          // moved the orphan pending to confirmed, the claim then died in
          // creditAndRegister's excess branch with reserved == 0 — identically
          // on retry — and, claim being all-or-nothing, took every later
          // deposit on the asset with it. A rejected call never committed on
          // the callee (a trap rolls the DEX back; a system reject never
          // reached it), so the rollback cannot strand a live reservation.
          // The one strand this arm cannot see — the DEX answered, but OUR
          // continuation trapped before its arm could run (W3-04 told it as
          // an upgrade in the await window; #55 (d): an upgrade cannot land
          // there) — is what the reservation check in devConfirmDeposits is for.
          Map.add(admittedUnits, Text.compare, k, admitted);
          l.pending := if (l.pending >= amount) { l.pending - amount } else { 0 };
          ignore Map.delete(admitting, Text.compare, k);
          pruneZeroRows(k);   // H-26 (F40): same row discipline as the #err arm
          return #err("Deposit admission failed — the DEX did not accept the call (nothing was created; retry once it is reachable): " # Error.message(e));
        };
        ignore Map.delete(admitting, Text.compare, k);
        return #ok;
      };
      case null {};   // unwired stub → pure dev sandbox, no allowance to enforce
    };
    let l = ledgerOf(msg.caller, asset);
    l.pending += amount;
    #ok;
  };
  public shared (msg) func devConfirmDeposits() : async () {
    requireAuth(msg.caller);
    // No Result channel in this signature, so the posture refusal is a TRAP —
    // loud, per the rule above. (It iterates ASSETS, so it needs no asset
    // validation of its own: it can only ever touch supported keys.)
    if (IS_PRODUCTION) {
      Runtime.trap("devConfirmDeposits is disabled on #production: this Bridge is a STUB with no custody behind it. Deploy the real chain-key Bridge before flipping the posture.");
    };
    // H-26 fence: nothing moves pending to confirmed while a season wipe is
    // pending (the same posture rule: no Result channel, so a trap).
    if (wipePending) { Runtime.trap(WIPE_PENDING_MSG) };
    let dex : ?DexActor = switch (effectiveDex<system>()) {
      case (?p) { ?(actor (Principal.toText(p)) : DexActor) };
      case null { null };   // unwired stub → pure dev sandbox, nothing to reconcile against
    };
    for (asset in ASSETS.vals()) {
      let k = key(msg.caller, asset);
      // Skip an asset whose admission is mid-flight (W3-04): its pending was
      // written AHEAD of the DEX's verdict, and confirming it here would
      // strand the explicit-#err rollback (the refused amount would already
      // have moved to `confirmed`). The next confirm call picks it up.
      if (Map.get(admitting, Text.compare, k) != null) { continue };
      // Read-only: an absent row has nothing pending and must not be created
      // by a confirm sweep (the same get-or-create discipline as claim).
      let l = switch (Map.get(ledgers, Text.compare, k)) { case (?x) { x }; case null { continue } };
      if (l.pending == 0) { continue };
      switch (dex) {
        case null {};
        case (?d) {
          // #55 "phantom pending": a pending is written AHEAD of the DEX's
          // verdict, and the one strand the catch arm cannot undo — our
          // continuation never running its rollback while the DEX reserved
          // nothing (W3-04 told it as an upgrade in the await window; #55 (d)
          // measured that an upgrade cannot land inside an await, so a
          // trapped continuation is the real shape) — leaves a pending with
          // NO reservation behind it.
          // Confirming it blind minted a claimable the claim then refused
          // forever. So before a pending becomes claimable, ask the DEX
          // whether the admission landed. The test is the SEQ, not the
          // reservation size: the DEX's applied admission seq lagging our
          // counter names exactly the units it never reserved (an allowance
          // re-arm can zero the reservation under a perfectly legitimate
          // pending, and must not drop it; a claim's excess branch fences
          // our pending since 3088472021, but the seq test never relied on it).
          // The drop fires ONLY when the DEX is reachable and answers: a
          // stopped DEX or a wiring refusal leaves the pending where it is
          // — visible, retryable, never confirmed unverified.
          let admitted = Option.get(Map.get(admittedUnits, Text.compare, k), 0);
          let verdict : ?{ capActive : Bool; reservedUnits : Nat; admitSeq : Nat } = try {
            switch (await d.playDepositReservation(msg.caller, asset)) {
              case (#ok(v)) { ?v };
              case (#err(_)) { null };
            };
          } catch (_) { null };
          // Re-read AFTER the yield. An admission that STARTED meanwhile must
          // find its pending intact for its own rollback; one that LANDED
          // moved the counter past the verdict we hold — either way, leave
          // this asset for the next confirm rather than act on stale state.
          if (Map.get(admitting, Text.compare, k) != null) { continue };
          if (Option.get(Map.get(admittedUnits, Text.compare, k), 0) != admitted) { continue };
          switch (verdict) {
            case null { continue };   // unverifiable — never confirm blind
            case (?v) {
              if (v.capActive and v.admitSeq < admitted) {
                let phantom : Nat = admitted - v.admitSeq;
                let drop = if (phantom < l.pending) { phantom } else { l.pending };
                l.pending -= drop;
                // Re-sync the counter to what the DEX applied, so the next
                // admission's seq is strictly greater and gets reserved
                // instead of being no-op'd as a replay of units it never saw.
                Map.add(admittedUnits, Text.compare, k, v.admitSeq);
              };
            };
          };
        };
      };
      if (l.pending > 0) { l.confirmed += l.pending; l.pending := 0 };
      // H-26 (F40): a phantom drop can leave the row all-zero and the counter
      // re-synced to 0 — the third way a zero row is born; prune it here too.
      pruneZeroRows(k);
    };
  };

  // ── Dev-only test hook (#55) ─────────────────────────────────
  // Reproduce the W3-04 "phantom pending" strand ON DEMAND: a pending row and
  // an advanced admission counter with NO DEX reservation behind them — the
  // state devSimulateDeposit's write-ahead leaves when its continuation never
  // runs its rollback over a DEX that reserved nothing, which the write-ahead
  // deliberately makes durable. W3-04 told that as an upgrade landing in the
  // await window; #55 (d) measured that an upgrade cannot land inside an
  // await on this toolchain (the upgrade lands only once the message is
  // done), so the shape that is real is a continuation that traps. Nothing
  // else can manufacture it: the catch arm rolls back on a throw, and a trap
  // inside the continuation is not stageable from a test. Controller + #dev
  // only; a typed #err elsewhere (the posture rule above).
  public shared (msg) func devTestStrandAdmission(user : Principal, asset : Text, amount : Nat) : async { #ok; #err : Text } {
    requireController(msg.caller);
    if (not IS_DEV) { return #err("devTestStrandAdmission is a dev-only hook (posture: play/production)") };
    if (not isSupportedAsset(asset)) { return #err("Unsupported asset: " # asset) };
    if (amount == 0) { return #err("Amount must be positive") };
    // H-27: the strand hook writes the same pending/admittedUnits the real
    // path does, and a later claim relays them into creditAndRegister's
    // toText — so it wears the same ceiling, ahead of its writes.
    if (amount > AMOUNT_CEILING) { return #err(AMOUNT_CEILING_MSG) };
    if (wipePending) { return #err(WIPE_PENDING_MSG) };
    let k = key(user, asset);
    if (Map.get(admitting, Text.compare, k) != null) { return #err("A deposit for " # asset # " is already in progress") };
    Map.add(admittedUnits, Text.compare, k, Option.get(Map.get(admittedUnits, Text.compare, k), 0) + amount);
    let l = ledgerOf(user, asset);
    l.pending += amount;
    #ok;
  };

  // ── Dev-only test hook (H-26 / F41) ──────────────────────────
  // Park an admission in its DEX round trip ON DEMAND: `hold = true` takes the
  // in-flight guard for (user, asset) exactly as devSimulateDeposit does —
  // through the SAME pre-guard eligibility path (asset, fence, not already in
  // progress) and with NO other write — and `hold = false` releases it, as the
  // continuation would. A real hold lasts one round trip and cannot be timed
  // from a test; this is the deterministic stand-in for "a stream of
  // ineligible callers keeps re-taking the interlock between the operator's
  // reset attempts". Controller + #dev only; a typed #err elsewhere.
  public shared (msg) func devTestHoldAdmission(user : Principal, asset : Text, hold : Bool) : async { #ok; #err : Text } {
    requireController(msg.caller);
    if (not IS_DEV) { return #err("devTestHoldAdmission is a dev-only hook (posture: play/production)") };
    if (not isSupportedAsset(asset)) { return #err("Unsupported asset: " # asset) };
    let k = key(user, asset);
    if (not hold) { ignore Map.delete(admitting, Text.compare, k); return #ok };
    if (wipePending) { return #err(WIPE_PENDING_MSG) };
    if (Map.get(admitting, Text.compare, k) != null) { return #err("A deposit for " # asset # " is already in progress") };
    Map.add(admitting, Text.compare, k, true);
    #ok;
  };

  // W4-12: the DEX-driven half of the season boundary. A reset wipes the
  // DEX's reservation ledger; without this hook the Bridge kept every
  // unclaimed claimable and its admission counters, and the surviving claim
  // took a second allowance debit on the other side. Caller must be the
  // wired DEX (or a controller, for ops repair). Refuses while any claim or
  // admission is mid-flight — the reset aborts rather than wiping under an
  // in-flight continuation.
  public shared (msg) func adminSeasonWipe() : async { #ok; #err : Text } {
    let dexOk = switch (effectiveDex<system>()) {
      case (?p) { Principal.equal(msg.caller, p) };
      case null { false };
    };
    if (not dexOk and not Principal.isController(msg.caller)) {
      return #err("adminSeasonWipe: caller is neither the wired DEX nor a controller");
    };
    if (Map.size(claiming) > 0 or Map.size(admitting) > 0) {
      // H-26 (F41): ARM the fence before refusing. Nothing new can take the
      // interlock from here on, so the in-flight ones settle within one DEX
      // round trip and the caller's retry completes — a sustained stream of
      // admissions can delay the wipe by exactly one attempt, never hold it.
      wipePending := true;
      return #err("adminSeasonWipe: a claim or admission is in flight — the wipe is now ARMED (new claims and admissions are refused until it completes); retry when the in-flight ones settle");
    };
    Map.clear(ledgers);
    Map.clear(admittedUnits);
    wipePending := false;
    #ok;
  };

  // H-26: disarm a wipe the operator abandoned (a reset attempt that armed
  // the fence and was never retried would otherwise pause the on-ramp
  // forever — the fence is stable by design, so an upgrade does not clear
  // it either). Same callers as the wipe itself.
  public shared (msg) func adminCancelSeasonWipe() : async { #ok; #err : Text } {
    let dexOk = switch (effectiveDex<system>()) {
      case (?p) { Principal.equal(msg.caller, p) };
      case null { false };
    };
    if (not dexOk and not Principal.isController(msg.caller)) {
      return #err("adminCancelSeasonWipe: caller is neither the wired DEX nor a controller");
    };
    wipePending := false;
    #ok;
  };

  // H-26 (F40): controller purge for rows the pre-fix rollback leaked — a
  // zero-valued admission counter, an all-zero Ledger. Both read identically
  // to an absent row (see pruneZeroRows), so this changes no balance and no
  // seq; it reclaims memory that only the season wipe could before. Keys
  // mid-flight are skipped (they cannot be zero, but the guard is cheap).
  public shared (msg) func adminPurgeZeroRows() : async { #ok : { admittedUnits : Nat; ledgers : Nat }; #err : Text } {
    if (not Principal.isController(msg.caller)) { return #err("adminPurgeZeroRows: caller is not a controller") };
    let deadCounters = List.empty<Text>();
    for ((k, v) in Map.entries(admittedUnits)) {
      if (v == 0 and Map.get(admitting, Text.compare, k) == null) { List.add(deadCounters, k) };
    };
    let deadLedgers = List.empty<Text>();
    for ((k, l) in Map.entries(ledgers)) {
      if (l.confirmed == 0 and l.pending == 0 and l.claimed == 0
          and Map.get(admitting, Text.compare, k) == null
          and Map.get(claiming, Text.compare, k) == null) { List.add(deadLedgers, k) };
    };
    for (k in List.values(deadCounters)) { ignore Map.delete(admittedUnits, Text.compare, k) };
    for (k in List.values(deadLedgers))  { ignore Map.delete(ledgers, Text.compare, k) };
    #ok({ admittedUnits = List.size(deadCounters); ledgers = List.size(deadLedgers) });
  };

  // H-26: the Bridge's state-growth telemetry — map sizes and the fence.
  // Counts only, no principals: what a test asserts "unchanged" across a
  // refused admission and what an operator reads before a season reset.
  public query func getBridgeStats() : async {
    ledgers : Nat; admittedUnits : Nat; admitting : Nat; claiming : Nat; onboarded : Nat; wipePending : Bool;
    dexAdmitCalls : Nat;   // H-27: playDepositReserve calls SENT since the last upgrade (transient)
  } {
    {
      ledgers = Map.size(ledgers); admittedUnits = Map.size(admittedUnits);
      admitting = Map.size(admitting); claiming = Map.size(claiming);
      onboarded = Map.size(onboarded); wipePending; dexAdmitCalls;
    };
  };

  // ── Admission control ───────────────────────────────────────
  // The Bridge is the ONBOARDING surface, so it must accept unregistered users
  // (claiming a first deposit is how they register on the DEX). Caller-only:
  // controllers (admin) and any authenticated principal pass; anonymous is shed.
  // ── Upgrade: release the in-flight guards ───────────────────
  //
  // `claiming` and `admitting` are each set BEFORE an `await` and cleared only
  // in the continuation. In a `persistent actor` a plain `let` is implicitly
  // STABLE, so a flag whose continuation never ran its clear stays `true`
  // FOREVER, and that (user, asset) could never claim or deposit again, with
  // no cure short of a code change. The strand was told as an upgrade landing
  // between a call and its reply — a routine deploy; #55 (d) measured that an
  // upgrade cannot land inside an await on this toolchain (the Motoko runtime
  // refuses it while a message is outstanding — the upgrade lands only once
  // the message is done), so the shape that strands a flag is a continuation
  // that traps after the set (the catch arms clear on a throw, not on a trap).
  //
  // Clearing them here is exactly right rather than merely convenient: no
  // continuation is outstanding across an upgrade, so after one there is by
  // construction nothing left to guard against — a surviving flag can only
  // be a stale latch, a lie.
  //
  // Why not mark them `transient`, which expresses the same idea? Because
  // dropping a stable variable is a one-way door: `moc --stable-compatible`
  // rejects it with M0169 ("cannot be implicitly discarded"), so the change
  // would need an explicit migration function and would block the upgrade on
  // any already-deployed Bridge. This achieves the same semantics with no
  // change to the stable signature at all — and it makes an upgrade the
  // RECOVERY for a stranded flag: the redeploy clears what a trap left behind
  // (#55 (d)). (`admittedUnits` is untouched: that is the admission seq the
  // DEX de-dups against, real bookkeeping rather than a latch.)
  system func postupgrade() {
    Map.clear(claiming);
    Map.clear(admitting);
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
