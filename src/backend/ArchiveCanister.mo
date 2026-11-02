// ArchiveCanister.mo — append-only archive for permanent user history.
//
// Spawned and fed by the main canister (docs/archive-design.md). Phase A′:
// a single "sidecar" instance; sealed-chain growth (spawn-ahead, routing
// fan-out) is Phase B. The main canister is the `owner`: only it may append,
// and as the controller it deletes the sidecar wholesale on a sim reset —
// that is the reset story, so this actor needs no wipe entry point.
//
// Storage: events arrive in strict global-seq order via appendBatch
// (idempotent on replays — re-shipped batches after an unknown-outcome call
// are skipped by seq) and are stored as length-delimited candid blobs in a
// stable Region, so the heap holds only the offset indexes. Candid encoding
// keeps records self-describing: fields added later (e.g. the Phase-D hash
// chain) decode against old blobs as long as they're `opt`.
//
// Queries are public by design (decision #4, 2026-06-10): getMyEvents is the
// caller's own history (tax view), getEventsRange is the public tape — fills
// are already public on the hot canister's tape, so the archive is just its
// durable continuation.

import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Order "mo:core/Order";
import Region "mo:core/Region";
import Cycles "mo:core/Cycles";
import CertifiedData "mo:core/CertifiedData";
import Blob "mo:core/Blob";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Prim "mo:⛔"; // rts_memory_size / rts_heap_size for the Stats → Archive panel
import Types "lib/Types";
import EventChain "lib/EventChain";

persistent actor class Archive(owner : Principal) {

  let data = Region.new();
  var dataEnd : Nat64 = 0;     // bytes written so far
  var firstSeq : ?Nat = null;  // seq of the first stored event
  var nextExpected : Nat = 0;  // next seq accepted (= count stored + firstSeq)

  // ── Tamper-evidence chain (Phase D) ──────────────────────────────
  // The archive re-derives the hash chain as events arrive: each stored
  // event's recomputed hash must equal the NEXT event's prevHash, or the
  // batch is refused — corruption cannot enter silently. The running head
  // is pushed into certified_data, so any reader can (a) trust the head via
  // the IC certificate and (b) verify the events beneath it offline with
  // EventChain's canonical form. chainStartSeq marks where verification
  // begins: events shipped before the chain existed (or before this archive
  // learned the code) stay stored but unverifiable.
  var chainHead : ?Blob = null;
  var chainStartSeq : ?Nat = null;

  // Offset indexes into `data`. The global index is the public tape
  // (position = seq − firstSeq); the per-user index is the tax view.
  let globalIndex = List.empty<(Nat64, Nat)>();
  let userIndex = Map.empty<Text, List.List<(Nat64, Nat)>>();

  // Deposit/withdrawal index — a kind-filtered slice of the global tape, so the
  // exchange can serve "all users' deposits & withdrawals" (a public money-flow
  // ledger) without a full per-query scan of millions of events. Built by
  // advancing `dwCursor` through globalIndex IN ORDER, so dwIndex stays
  // seq-ascending and its tail is the newest D/W. Populated incrementally on
  // append + by the self-driven index backfill (the postupgrade timer below,
  // task 1793495003) for the events that predate this index; backfillDwIndex
  // is the owner's EXPLICIT driver for the same catch-up.
  let dwIndex = List.empty<(Nat64, Nat)>();
  var dwCursor : Nat = 0;   // globalIndex positions [0, dwCursor) already scanned into dwIndex

  // Per-principal FILL index (task 1793489930) — the kind-filtered slice of
  // userIndex the history views page. Spot History / Positions History /
  // Account → Spot want a user's FILLS, and the all-kinds userIndex made a
  // fill-less segment cost ceil(total/200) hops just to learn it held none:
  // every #delta (one per balance mutation), deposit and config row paged out
  // to be dropped in the browser. Built like dwIndex — by advancing
  // `fillCursor` through globalIndex IN ORDER (live catch-up per append; the
  // self-driven backfill below after an upgrade) — so each per-principal list
  // stays seq-ascending and newest-first is a reverse walk: no gather, no
  // sort. Each entry is the SAME tuple the other indexes hold (one pointer
  // per fill, not a second copy of the offsets).
  let userFillIndex = Map.empty<Text, List.List<(Nat64, Nat)>>();
  var fillCursor : Nat = 0;   // globalIndex positions [0, fillCursor) already scanned into userFillIndex

  // ── Low-memory early warning ──────────────────────────────────────
  // Fires when this canister's wasm memory first crosses its
  // wasm_memory_threshold setting; re-arms when usage drops back below. The
  // archive needs its own hook: the events live in the stable Region, but the
  // OFFSET INDEXES (globalIndex, userIndex, dwIndex) are heap-resident and grow
  // with the tape forever, so this canister approaches a heap wall the exchange
  // canister's hook knows nothing about — and the exchange's hook cannot fire
  // for a sidecar in any case.
  //
  // ⚠️ OPS: a SPAWNED canister inherits the IC default wasm_memory_threshold of
  // 0, which means "never warn". Until an operator sets a non-zero threshold on
  // each archive (or the exchange sets one at spawn time), this hook cannot
  // fire and these fields stay at their zero values — a zero here means "never
  // fired OR never armed", and the two are indistinguishable from inside.
  //
  // Mirrors main.mo's hook: a stable stamp, readable after an upgrade or while
  // updates are wedged. main.mo also writes its event log; the archive has no
  // log, so `stats()` is the surfacing channel — plus a count, because an
  // archive that keeps re-crossing the threshold is a different (and worse)
  // story than one that crossed it once.
  var lowMemoryAtNs : Int = 0;    // Time.now() of the last crossing (0 = never)
  var lowMemoryCount : Nat = 0;   // how many times it has fired
  system func lowmemory() : async* () {
    lowMemoryAtNs := Time.now();
    lowMemoryCount += 1;
  };

  // True iff `data` can hold `needed` bytes. Region.grow signals failure by
  // RETURNING 0xFFFF_FFFF_FFFF_FFFF — the build's --max-stable-pages cap, or
  // the IC refusing this canister more memory — it does not trap. That result
  // must be checked: ignoring it lets the next storeBlob trap "range out of
  // bounds" and wedge the shipper (July 2026 subnet incident at 4 GiB).
  func ensureCapacity(needed : Nat64) : Bool {
    let have = Region.size(data) * 65536;
    if (needed > have) {
      let before = Region.grow(data, (needed - have + 65535) / 65536);
      if (before == 0xFFFF_FFFF_FFFF_FFFF) { return false };
    };
    true
  };

  // False = at capacity; nothing (region bytes, indexes, cursor) is mutated.
  func store(e : Types.UserEvent) : Bool {
    let blob = to_candid (e);
    let len = blob.size();
    if (not ensureCapacity(dataEnd + Nat64.fromNat(len))) { return false };
    Region.storeBlob(data, dataEnd, blob);
    let entry = (dataEnd, len);
    List.add(globalIndex, entry);
    let key = Principal.toText(e.user);
    let lst = switch (Map.get(userIndex, Text.compare, key)) {
      case (?l) { l };
      case null {
        let l = List.empty<(Nat64, Nat)>();
        Map.add(userIndex, Text.compare, key, l);
        l
      };
    };
    List.add(lst, entry);
    dataEnd += Nat64.fromNat(len);
    true
  };

  func load(entry : (Nat64, Nat)) : ?Types.UserEvent {
    from_candid (Region.loadBlob(data, entry.0, entry.1));
  };

  func loadAt(lst : List.List<(Nat64, Nat)>, i : Nat) : ?Types.UserEvent {
    switch (List.get(lst, i)) {
      case (?entry) { load(entry) };
      case null { null };
    };
  };

  // Advance the deposit/withdrawal index by up to `maxScan` more globalIndex
  // positions (in seq order), appending the offset of every #deposit-kind event
  // (covers both deposits and withdrawals). Returns positions scanned this call.
  // Used both for live catch-up (small, per append) and the controller backfill
  // (large chunks over the pre-index backlog).
  func dwScan(maxScan : Nat) : Nat {
    let n = List.size(globalIndex);
    let stop = Nat.min(dwCursor + maxScan, n);
    var i = dwCursor;
    while (i < stop) {
      switch (List.get(globalIndex, i)) {
        case (?entry) {
          switch (load(entry)) {
            case (?e) { switch (e.kind) { case (#deposit _) { List.add(dwIndex, entry) }; case _ {} } };
            case null {};
          };
        };
        case null {};
      };
      i += 1;
    };
    let scanned : Nat = stop - dwCursor;
    dwCursor := stop;
    scanned
  };

  // Advance the fill index by up to `maxScan` more globalIndex positions (in
  // seq order), filing every #fill's offset under its principal. Returns the
  // positions scanned this call. Live catch-up per append + the backfill timer.
  func fillScan(maxScan : Nat) : Nat {
    let n = List.size(globalIndex);
    let stop = Nat.min(fillCursor + maxScan, n);
    var i = fillCursor;
    while (i < stop) {
      switch (List.get(globalIndex, i)) {
        case (?entry) {
          switch (load(entry)) {
            case (?e) {
              switch (e.kind) {
                case (#fill _) {
                  let key = Principal.toText(e.user);
                  let lst = switch (Map.get(userFillIndex, Text.compare, key)) {
                    case (?l) { l };
                    case null {
                      let l = List.empty<(Nat64, Nat)>();
                      Map.add(userFillIndex, Text.compare, key, l);
                      l
                    };
                  };
                  List.add(lst, entry);
                };
                case _ {};
              };
            };
            case null {};
          };
        };
        case null {};
      };
      i += 1;
    };
    let scanned : Nat = stop - fillCursor;
    fillCursor := stop;
    scanned
  };
  func fillIndexComplete() : Bool { fillCursor >= List.size(globalIndex) };
  func dwIndexComplete()   : Bool { dwCursor >= List.size(globalIndex) };
  func indexesComplete()   : Bool { fillIndexComplete() and dwIndexComplete() };

  // ── Index backfill (self-driven; the FILL and the D/W cursor) ──────
  // A segment upgraded onto this code holds events stored before an index
  // existed (that cursor = 0 on first arrival here: fillCursor since task
  // 1793489930; dwCursor on a segment that predates the D/W index, or was
  // upgraded with a backlog), and a SEALED segment never sees another
  // appendBatch to catch it up — so postupgrade arms a one-shot timer that
  // scans a chunk of EVERY lagging cursor and re-arms itself while either is
  // behind, then goes quiet: no heartbeat, nothing once complete.
  // Operator-free by design (adminUpgradeArchives walks a chain of dozens of
  // segments; each heals itself). Task 1793495003 folded the D/W cursor in:
  // before it the exchange's adminBackfillArchiveDw drove backfillDwIndex on
  // the active tip ONLY, so a sealed segment's getDepositWithdrawals silently
  // under-reported for good. 50k decodes per tick ≈ a few seconds, far inside
  // the update budget (backfillDwIndex's owner-driven chunk is 200k) — SPLIT
  // between the two cursors while both are behind, so a tick never decodes
  // more than the single-index tick did. While a backlog remains the filtered
  // pager answers by gather-time filtering — correct, slower
  // (getEventsForPrincipalsFiltered) — and getDepositWithdrawals serves the
  // D/W rows indexed so far (stats.dwIndexCursor < eventCount says so).
  transient let INDEX_BACKFILL_CHUNK : Nat = 50_000;
  func indexBackfillTick() : async () {
    let fillBehind = not fillIndexComplete();
    let dwBehind   = not dwIndexComplete();
    let chunk = if (fillBehind and dwBehind) { INDEX_BACKFILL_CHUNK / 2 } else { INDEX_BACKFILL_CHUNK };
    if (fillBehind) { ignore fillScan(chunk) };
    if (dwBehind)   { ignore dwScan(chunk) };
    if (not indexesComplete()) { ignore Timer.setTimer<system>(#seconds 1, indexBackfillTick) };
  };
  system func postupgrade() {
    if (not indexesComplete()) { ignore Timer.setTimer<system>(#seconds 1, indexBackfillTick) };
  };

  // Append a strictly-ordered batch. Replays of already-stored seqs are
  // skipped (the shipper re-sends on unknown outcomes); a gap is an error —
  // the shipper never skips ahead, so a gap means a bug, and storing around
  // it would corrupt the position arithmetic.
  //
  // Chain enforcement: once this archive holds a chain head, every stored
  // event's prevHash must equal it (and the head advances to the event's
  // recomputed hash) — a batch that breaks the link is REFUSED before any of
  // its remainder is stored. The first event ever seen anchors the chain
  // whatever its prevHash (pre-chain deployments / an archive upgraded after
  // main started chaining): links before the anchor are simply unverifiable.
  //
  // Capacity: #full(n) means "stored through n−1 and can take NO more" — the
  // stable region hit its cap mid-batch. The prefix is acked exactly like #ok
  // (the shipper must not re-send it); the shipper's response is to seal this
  // archive and roll to a fresh successor.
  public shared (msg) func appendBatch(events : [Types.UserEvent]) : async { #ok : Nat; #full : Nat; #err : Text } {
    if (msg.caller != owner) { return #err("not the owning canister") };
    var full = false;
    label ship for (e in events.vals()) {
      // A SUCCESSOR archive in the Phase-B chain starts mid-tape: the very
      // first event it ever sees defines its base seq (archive_0 gets 0; the
      // second archive gets wherever the previous one sealed).
      if (firstSeq == null) { nextExpected := e.seq };
      if (e.seq < nextExpected) {
        // replay of an acked event — already stored, skip
      } else if (e.seq > nextExpected) {
        return #err("seq gap: got " # Nat.toText(e.seq) # ", expected " # Nat.toText(nextExpected));
      } else {
        switch (chainHead) {
          case (?h) {
            if (e.prevHash != ?h) {
              return #err("chain break at seq " # Nat.toText(e.seq) # " — prevHash does not match the stored head");
            };
          };
          case null {};
        };
        if (not store(e)) {
          // Region at capacity — none of THIS event was written (store checks
          // before mutating). Ack the stored prefix as #full below; the chain
          // head/anchor state only ever reflects fully-stored events.
          full := true;
          break ship;
        };
        if (chainHead == null) { chainStartSeq := ?e.seq };   // anchor point
        if (firstSeq == null) { firstSeq := ?e.seq };
        chainHead := ?EventChain.hash(e);
        nextExpected += 1;
      };
    };
    // Publish the head into the system certificate so readers can trust it
    // (32 bytes — exactly what certified_data holds).
    switch (chainHead) { case (?h) { CertifiedData.set(h) }; case null {} };
    // Keep the D/W index current. Once the backfill has caught the cursor up to
    // the tape end, this scans exactly the batch just stored; while a backlog
    // remains it chips away (the controller backfill does the bulk).
    ignore dwScan(events.size() + 16);
    ignore fillScan(events.size() + 16);
    if (full) { return #full(nextExpected) };
    #ok(nextExpected);
  };

  // The certified chain head: `certificate` (in a query call) proves the
  // subnet vouches for `headHash` as this canister's certified data. A
  // reader verifies the certificate, then re-derives the chain over fetched
  // events (EventChain canonical form) up to the head. headSeq = the last
  // chained event; links verify from chainStartSeq forward.
  public query func getCertifiedHead() : async {
    headHash      : ?Blob;
    headSeq       : ?Nat;    // seq of the event the head hash covers
    chainStartSeq : ?Nat;
    certificate   : ?Blob;
  } {
    {
      headHash = chainHead;
      headSeq = if (nextExpected == 0) { null } else { ?(nextExpected - 1) };
      chainStartSeq;
      certificate = CertifiedData.getCertificate();
    };
  };

  // Recompute + verify the chain over a stored range (bounded per call —
  // page a full audit). Two kinds of check: every INTERNAL link (each
  // event's recomputed hash equals its successor's stored prevHash), and —
  // when the walk reaches the tape end — the OUTBOUND ANCHOR: the last
  // event's own recomputed hash must equal the certified chainHead
  // (W2-01, #18 F50). Without the anchor, the newest event's hash was
  // never compared against anything (no successor reads it), so
  // corrupting it — or consistently rewriting any tail suffix — verified
  // clean; on a sealed season archive nothing would ever surface that.
  // `ok=false` pinpoints the first broken seq. Anyone may call; the
  // stronger, trustless variant is the same computation done client-side
  // under the certified head (src/frontend/src/ledger.js anchors the same
  // way).
  //
  // SCOPE (W2-04/R11): this verifies links WITHIN this archive only. The
  // anchor below starts at whatever event arrived first — the canister is
  // never told its predecessor's head, so the inbound cross-archive join
  // is not checked here and cannot be. That is not a security hole to fix
  // with plumbing: this is an uncertified self-diagnostic (a hostile host
  // returns ok=true regardless), for honest bugs and storage corruption.
  // The cross-archive joins are verified OFF-chain, by the two verifiers,
  // under per-segment IC certificates.
  //
  // BOUNDARY LINKS: `prev` starts empty on every call, so the first event of a
  // page has nothing to check its inbound prevHash against. Left that way, a
  // paged audit — the usage this docstring recommends — would verify only the
  // links INSIDE each page and silently skip the one joining it to the page
  // before, ceil(N/P)−1 of them across a run, while still returning ok=true.
  // An event whose prevHash was rewritten to point somewhere else would sit
  // exactly on such a boundary in the majority of pagings. So when the window
  // opens ABOVE the chain anchor, seed `prev` from the preceding stored event
  // and re-check that link here. (The client-side verifier in
  // src/frontend/src/ledger.js already seeds its slices the same way.) If the
  // predecessor cannot be loaded, the link is unverifiable — that is reported
  // as ok=false, never passed over: silence is what made this a bug.
  //
  // `linksChecked` reports how many hash comparisons this call actually made,
  // so the COVERAGE of an audit is itself auditable — "ok = true" alone cannot
  // distinguish a thorough pass from a vacuous one. A page of k events verifies
  // k links when its inbound link was seeded and k−1 when it starts at the
  // anchor (whose own prevHash points before this chain); a page that reaches
  // the TAPE END verifies one more — the head anchor. So a paged walk sums to
  // exactly the single-call total: N−1 for a window strictly inside the tape,
  // N when the walk reaches the end. That identity is the regression test.
  // tests/test_archive_chain_paged.sh asserts the interior case (its window
  // deliberately stops short of the tail, so live appends cannot flake it);
  // tests/test_archive_chain.sh asserts the anchored case on a SEALED
  // archive, where the count is deterministic forever.
  public query func verifyChain(fromSeq : Nat, limit : Nat) : async {
    checked : Nat; linksChecked : Nat; ok : Bool; brokenAt : ?Nat; nextSeq : ?Nat;
  } {
    let empty = { checked = 0; linksChecked = 0; ok = true; brokenAt = null; nextSeq = null };
    let base = switch (firstSeq) { case (?f) { f }; case null { return empty } };
    let anchor = switch (chainStartSeq) { case (?s) { s }; case null { return empty } };
    let start = Nat.max(fromSeq, anchor);
    if (start >= nextExpected) { return empty };
    let capped = Nat.min(limit, 10_000);
    var s = start;
    var prev : ?Types.UserEvent = null;
    // Seed the inbound link unless the window starts AT the anchor, whose own
    // prevHash points before this chain and is unverifiable by definition.
    // start > anchor ≥ base, so start-1-base is in range and never underflows.
    if (start > anchor) {
      switch (loadAt(globalIndex, start - 1 - base)) {
        case (?p) { prev := ?p };
        case null {
          // The predecessor is unreadable, so this page's inbound link cannot
          // be verified. Report it — reporting ok=true here is precisely the
          // silent hole being fixed.
          return { checked = 0; linksChecked = 0; ok = false; brokenAt = ?(start - 1); nextSeq = null };
        };
      };
    };
    var checked = 0;
    var links = 0;
    while (s < nextExpected and checked < capped) {
      switch (loadAt(globalIndex, s - base)) {
        case (?e) {
          switch (prev) {
            case (?p) {
              if (e.prevHash != ?EventChain.hash(p)) {
                return { checked; linksChecked = links; ok = false; brokenAt = ?e.seq; nextSeq = null };
              };
              links += 1;
            };
            case null {};
          };
          prev := ?e;
        };
        case null { return { checked; linksChecked = links; ok = false; brokenAt = ?s; nextSeq = null } };
      };
      checked += 1;
      s += 1;
    };
    // OUTBOUND ANCHOR (W2-01, #18 F50). The loop above only ever compares an
    // event's stored prevHash against its predecessor's recomputed hash —
    // every comparison is INTERNAL to the range. When the walk reaches the
    // tape end there is no successor to read the last event's hash, so
    // without this block the newest event was never checked against
    // anything and the function returned ok = true unconditionally:
    // corrupting the newest stored event, or consistently rewriting a whole
    // tail suffix, verified clean — permanently so on a sealed archive. The
    // certified chainHead is the one value a tamperer cannot forge; anchor
    // the recomputed tail to it. A range that stops short of the end makes
    // no claim about the head (nextSeq tells the caller to keep paging).
    if (s >= nextExpected) {
      switch (prev, chainHead) {
        case (?p, ?h) {
          if (EventChain.hash(p) != h) {
            return { checked; linksChecked = links; ok = false; brokenAt = ?p.seq; nextSeq = null };
          };
          links += 1;
        };
        case (?p, null) {
          // Events were walked but no head is recorded — structurally
          // impossible (the head advances on every store); refuse to vouch.
          return { checked; linksChecked = links; ok = false; brokenAt = ?p.seq; nextSeq = null };
        };
        case (null, _) {};   // zero-length walk (limit 0): nothing to anchor
      };
    };
    { checked; linksChecked = links; ok = true; brokenAt = null; nextSeq = if (s < nextExpected) { ?s } else { null } };
  };

  // The caller's own events, newest-first. `offset` counts back from the
  // newest (0 = most recent page); pages cap at 200.
  public query (msg) func getMyEvents(offset : Nat, limit : Nat) : async {
    events : [Types.UserEvent];
    total  : Nat;
  } {
    let lst = switch (Map.get(userIndex, Text.compare, Principal.toText(msg.caller))) {
      case (?l) { l };
      case null { return { events = []; total = 0 } };
    };
    let total = List.size(lst);
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    // Int arithmetic — Nat subtraction would trap when offset ≥ total.
    var idx : Int = (total : Int) - 1 - (offset : Int);
    while (idx >= 0 and List.size(result) < capped) {
      switch (loadAt(lst, Int.abs(idx))) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      idx -= 1;
    };
    { events = Iter.toArray(List.values(result)); total };
  };

  // Events across a SET of principals, newest-first, paged. Lets a user see
  // their full margin history: spot fills archive under the human principal,
  // but margin fills archive under the POOL principals — the caller passes
  // their human + pool principals and gets the merged, paginated timeline.
  //
  // OWNER-GATED: only the exchange canister (the archive owner) may call this
  // directly. A user reaches their OWN history through the exchange's
  // getMyArchivedEvents composite query, which resolves the caller's principals
  // and federates here AS the owner. This closes the targeted vector — arbitrary
  // by-principal lookups (leaderboard → rival's principal → position → liq
  // price). The public whole-tape reads (getEventsRange, getDepositWithdrawals)
  // stay open: the chain verifier + PoR need them, and they carry no easy
  // per-human attribution INDEX — but not zero attribution (W6-10.1/R6): a
  // fundMarginPool debits the human and credits the pool in one awaitless
  // message, and the journal drains in insertion order, so the raw tape
  // carries the two #delta rows at CONSECUTIVE seqs with matched magnitude —
  // a derivable owner↔pool join for anyone willing to scan linearly
  // (getEventsRange pages ≤200/call; there is no by-principal shortcut, that
  // is what the gate below closes). Derivable-by-scan is the accepted cost
  // of the replay invariant: #delta rows must fold per REAL principal
  // (main.mo's drainLedgerJournal cites this note), so remapping them is not
  // an option. Region offset is monotonic with global seq, so sorting the
  // gathered index entries by offset descending = newest-first.
  public query (msg) func getEventsForPrincipals(principals : [Principal], offset : Nat, limit : Nat) : async {
    events : [Types.UserEvent];
    total  : Nat;
  } {
    if (not Principal.equal(msg.caller, owner)) { return { events = []; total = 0 } };
    let entries = List.empty<(Nat64, Nat)>();
    for (p in principals.vals()) {
      switch (Map.get(userIndex, Text.compare, Principal.toText(p))) {
        case (?l) { for (e in List.values(l)) { List.add(entries, e) } };
        case null {};
      };
    };
    let arr = Iter.toArray(List.values(entries));
    let sorted = Array.sort(arr, func(a : (Nat64, Nat), b : (Nat64, Nat)) : Order.Order { Nat64.compare(b.0, a.0) });
    let total = sorted.size();
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var i = offset;
    while (i < total and List.size(result) < capped) {
      switch (load(sorted[i])) { case (?e) { List.add(result, e) }; case null {} };
      i += 1;
    };
    { events = Iter.toArray(List.values(result)); total };
  };

  // UserEvent.kind → the tag vocabulary the exchange's OQL `kind` column
  // speaks (main.mo oqlEvKind — kept in step by hand; #deposit splits by its
  // record's kind). No catch-all BY DESIGN: a new kind must be named here.
  func kindTag(k : Types.UserEventKind) : Text = switch k {
    case (#fill _)             { "fill" };
    case (#deposit r)          { switch (r.kind) { case (#deposit) { "deposit" }; case (#withdrawal) { "withdrawal" } } };
    case (#orderClosed _)      { "orderClosed" };
    case (#liquidation _)      { "liquidation" };
    case (#borrow _)           { "borrow" };
    case (#repay _)            { "repay" };
    case (#lpDeposit _)        { "lpDeposit" };
    case (#lpWithdraw _)       { "lpWithdraw" };
    case (#insuranceStake _)   { "insuranceStake" };
    case (#insuranceUnstake _) { "insuranceUnstake" };
    case (#delta _)            { "delta" };
    case (#debtDelta _)        { "debtDelta" };
    case (#lpShareDelta _)     { "lpShareDelta" };
    case (#insShareDelta _)    { "insShareDelta" };
    case (#config _)           { "config" };
    case (#gap _)              { "gap" };
  };
  func kindIn(k : Types.UserEventKind, kinds : [Text]) : Bool {
    let t = kindTag(k);
    for (w in kinds.vals()) { if (w == t) { return true } };
    false
  };

  // Kind-filtered form of getEventsForPrincipals (task 1793489930): `total`
  // and the pages count only events whose kind tag is in `kinds` (the OQL
  // `kind` vocabulary — "fill", "deposit", "withdrawal", …; [] = every kind),
  // so a segment holding none of the caller's fills answers total = 0 in ONE
  // hop, and a heavy user's non-fill rows (a #delta per balance mutation,
  // deposits, config) never page out just to be dropped client-side. Same
  // owner gate, same newest-first order, same 200 cap; `offset` counts in
  // the FILTERED sequence — the same sequence whichever path below serves
  // it, so a caller's paging stays consistent across a backfill completing.
  //
  // Two paths, both sort-free (each per-principal list is seq-ascending, so
  // the merge across principals is a k-way reverse walk — the unfiltered
  // pager re-gathers and re-sorts the whole per-principal index per page):
  //   • kinds = ["fill"] with the fill index complete → userFillIndex,
  //     O(k × (offset + limit)) index steps, decoding only the page;
  //   • anything else → userIndex with a decode-and-test predicate, O(own
  //     events in this segment) decodes: the general form for other kinds,
  //     and the fallback while an upgraded segment's backfill still runs.
  public query (msg) func getEventsForPrincipalsFiltered(principals : [Principal], kinds : [Text], offset : Nat, limit : Nat) : async {
    events : [Types.UserEvent];
    total  : Nat;
  } {
    if (not Principal.equal(msg.caller, owner)) { return { events = []; total = 0 } };
    let fillsOnly = kinds.size() == 1 and kinds[0] == "fill";
    let indexed = fillsOnly and fillIndexComplete();
    let everyEntry = indexed or kinds.size() == 0;   // no predicate: each index entry is a hit
    let source = if (indexed) { userFillIndex } else { userIndex };
    // Distinct principals only — a repeated principal would double its rows.
    let lists = List.empty<List.List<(Nat64, Nat)>>();
    let seen = List.empty<Text>();
    for (p in principals.vals()) {
      let key = Principal.toText(p);
      if (not List.contains(seen, Text.equal, key)) {
        List.add(seen, key);
        switch (Map.get(source, Text.compare, key)) { case (?l) { List.add(lists, l) }; case null {} };
      };
    };
    let ls = Iter.toArray(List.values(lists));
    let k = ls.size();
    var sizes : Nat = 0;
    for (l in ls.vals()) { sizes += List.size(l) };
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    // k-way reverse merge: a cursor per list starts at its tail; each step
    // takes the entry with the greatest Region offset (= greatest seq).
    let cur = VarArray.repeat<Int>(-1, k);
    var i = 0;
    while (i < k) { cur[i] := (List.size(ls[i]) : Int) - 1; i += 1 };
    var matched = 0;   // hits seen so far = the next hit's position in the filtered sequence
    label walk loop {
      if (everyEntry and List.size(result) >= capped) { break walk };
      var best : Int = -1;
      var bestOff : Nat64 = 0;
      var j = 0;
      while (j < k) {
        if (cur[j] >= 0) {
          switch (List.get(ls[j], Int.abs(cur[j]))) {
            case (?e) { if (best < 0 or e.0 > bestOff) { best := j; bestOff := e.0 } };
            case null {};
          };
        };
        j += 1;
      };
      if (best < 0) { break walk };
      let bi = Int.abs(best);
      switch (List.get(ls[bi], Int.abs(cur[bi]))) {
        case (?entry) {
          if (everyEntry) {
            if (matched >= offset) {
              switch (load(entry)) { case (?e) { List.add(result, e) }; case null {} };
            };
            matched += 1;
          } else {
            switch (load(entry)) {
              case (?e) {
                if (kindIn(e.kind, kinds)) {
                  if (matched >= offset and List.size(result) < capped) { List.add(result, e) };
                  matched += 1;
                };
              };
              case null {};
            };
          };
        };
        case null {};
      };
      cur[bi] -= 1;
    };
    { events = Iter.toArray(List.values(result)); total = if (everyEntry) { sizes } else { matched } };
  };

  // Public tape: events by global seq, ascending from `startSeq`.
  public query func getEventsRange(startSeq : Nat, limit : Nat) : async [Types.UserEvent] {
    let base = switch (firstSeq) { case (?f) { f }; case null { return [] } };
    if (startSeq < base or startSeq >= nextExpected) { return [] };
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var s = startSeq;
    while (s < nextExpected and List.size(result) < capped) {
      switch (loadAt(globalIndex, s - base)) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      s += 1;
    };
    Iter.toArray(List.values(result));
  };

  // Self-reported metrics — powers the dashboard's archive card and the
  // Phase-B cycle top-up watermarks (cheaper than management-canister
  // status calls, and callable by anyone).
  public query func stats() : async {
    firstSeq   : ?Nat;
    nextSeq    : Nat;
    eventCount : Nat;
    bytes      : Nat64;   // durable event data in the stable Region
    users      : Nat;
    cycles     : Nat;
    memorySizeBytes : Nat; // total wasm memory (heap + code + stable pages)
    heapLiveBytes   : Nat; // live heap (the offset indexes; the events live in the Region)
    chainStartSeq : ?Nat;  // links verify from here forward (null = no chain yet)
    chainHead     : ?Blob; // running chain hash (also in certified_data)
    // When the lowmemory() threshold hook last fired (0 = never fired, OR the
    // canister's wasm_memory_threshold is still the spawn default of 0 and the
    // hook is unarmed — see the hook), and how many times.
    lowMemoryAtNs  : Int;
    lowMemoryCount : Nat;
    // Fill-index progress (task 1793489930): globalIndex positions scanned
    // into userFillIndex; == eventCount means complete (the filtered pager
    // serves fills off the index), less means the self-driven backfill is
    // still running (it serves them by gather-time filtering meanwhile).
    // opt so a reader's IDL listing it still decodes a pre-index segment.
    fillIndexCursor : ?Nat;
    // D/W-index progress (task 1793495003): globalIndex positions scanned
    // into dwIndex; == eventCount means getDepositWithdrawals covers the
    // whole tape, less means the same self-driven backfill is still catching
    // it up (the sealed segments adminBackfillArchiveDw never used to reach).
    // opt for the same decode-safety reason.
    dwIndexCursor : ?Nat;
  } {
    {
      firstSeq;
      nextSeq    = nextExpected;
      eventCount = List.size(globalIndex);
      bytes      = dataEnd;
      users      = Map.size(userIndex);
      cycles     = Cycles.balance();
      memorySizeBytes = Prim.rts_memory_size();
      heapLiveBytes   = Prim.rts_heap_size();
      chainStartSeq;
      chainHead;
      lowMemoryAtNs;
      lowMemoryCount;
      fillIndexCursor = ?fillCursor;
      dwIndexCursor   = ?dwCursor;
    };
  };

  // Recent deposits & withdrawals across ALL users, newest-first. Public by
  // design (the money-flow ledger — funds in/out of the exchange are auditable).
  // Reads the kind-filtered dwIndex, so it's bounded regardless of tape size.
  // Coverage grows as the self-driven backfill (or the owner's backfillDwIndex)
  // catches the index up over the backlog; stats.dwIndexCursor vs eventCount
  // says how far along a segment is.
  public query func getDepositWithdrawals(offset : Nat, limit : Nat) : async [Types.UserEvent] {
    let total = List.size(dwIndex);
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var idx : Int = (total : Int) - 1 - (offset : Int);   // newest-first
    while (idx >= 0 and List.size(result) < capped) {
      switch (loadAt(dwIndex, Int.abs(idx))) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      idx -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Owner-only (the controlling exchange canister): advance the D/W index over
  // the pre-index backlog. Call repeatedly until `done`; each call scans up to
  // `maxScan` tape positions (0 = report the cursor, scan nothing). Idempotent
  // and monotonic (the cursor only moves forward), so re-runs are safe. The
  // EXPLICIT driver — adminBackfillArchiveDw walks every segment with it; the
  // postupgrade timer above does the same catch-up unprompted, so this is for
  // an operator who wants the backlog gone now, or the cursor reported.
  public shared (msg) func backfillDwIndex(maxScan : Nat) : async {
    scanned : Nat; cursor : Nat; total : Nat; dwCount : Nat; done : Bool;
  } {
    if (msg.caller != owner) {
      return { scanned = 0; cursor = dwCursor; total = List.size(globalIndex); dwCount = List.size(dwIndex); done = dwCursor >= List.size(globalIndex) };
    };
    let scanned = dwScan(maxScan);
    { scanned; cursor = dwCursor; total = List.size(globalIndex); dwCount = List.size(dwIndex); done = dwCursor >= List.size(globalIndex) };
  };
};
