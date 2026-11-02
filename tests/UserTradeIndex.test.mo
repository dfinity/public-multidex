// H-31 (F48): the per-principal trade side index in src/backend/lib/OrderBook.mo
// must return EXACTLY what the legacy full-tape walks return — for every
// principal, every limit, every timestamp / id cursor — at O(own fills)
// instead of O(tape). Pins: incremental indexing (indexUserTrade per fill, the
// refreshRolling24h choke point's write) equals a rebuild from the tape;
// getUserTradesIndexed / SinceIndexed / SinceIdIndexed equal getUserTrades /
// getUserTradesSince / getUserTradesSinceId; a self-crossed fill (seed tape:
// buyer == seller) is indexed once (entries == tape parties); anonymous
// returns [] before any lookup; pruneUserTradeIndex after a simulated global
// trim equals a rebuild from the trimmed tape and drops a principal whose whole
// history aged out. Prices ×10^8; ids are the store's own monotone sequence.

import OB "../src/backend/lib/OrderBook";
import Types "../src/backend/lib/Types";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};
func sameTrades(a : [Types.Trade], b : [Types.Trade]) : Bool {
  if (a.size() != b.size()) { return false };
  var i = 0;
  while (i < a.size()) { if (a[i].id != b[i].id) { return false }; i += 1 };
  true
};
func eqT(name : Text, a : [Types.Trade], b : [Types.Trade]) {
  if (not sameTrades(a, b)) {
    Runtime.trap("FAIL: " # name # " — indexed " # debug_show (a.size()) # " rows vs walk " # debug_show (b.size()));
  };
  Debug.print("  ✓ " # name);
};

let mkt = "BTC-ICPUSD";
let anon = Principal.fromText("2vxsx-fae");
let ps : [Principal] = [
  Principal.fromBlob(Text.encodeUtf8("uti-alice")),
  Principal.fromBlob(Text.encodeUtf8("uti-bob")),
  Principal.fromBlob(Text.encodeUtf8("uti-carol")),
  Principal.fromBlob(Text.encodeUtf8("uti-dave")),
  Principal.fromBlob(Text.encodeUtf8("uti-amm")),
];
let virgin = Principal.fromBlob(Text.encodeUtf8("uti-virgin"));

Debug.print("── UserTradeIndex.test ──");

// ── a tape of 1,000 fills among five principals, one self-crossed run ──
// Party pattern cycles through every ordered pair; timestamps climb 3 ns per
// fill with a plateau every 7th so a timestamp cursor straddles same-ts fills.
let s = OB.emptyStore();
let live = OB.newUserTradeIndex();   // maintained incrementally, like the choke point
var i : Nat = 0;
var ts : Int = 1_000;
var parties : Nat = 0;
while (i < 1_000) {
  let b = ps[i % 5];
  let sl = if (i % 97 == 0) { b } else { ps[(i / 5 + 1 + i) % 5] };
  if (i % 7 != 0) { ts += 3 };
  let t = OB.recordTrade(s, mkt, 0, 0, b, sl, 10_000_000_000, 100_000_000, ts, ?#limit);
  OB.indexUserTrade(live, t);
  parties += (if (Principal.equal(b, sl)) { 1 } else { 2 });
  i += 1;
};
eqN("tape holds 1,000 fills", List.size(s.trades), 1_000);
eqN("index entries == tape parties (self-crossed fills indexed once)", OB.userTradeIndexEntries(live), parties);
eqN("tapePartyCount agrees", OB.tapePartyCount(s), parties);

// ── incremental == rebuild ──
let rebuilt = OB.newUserTradeIndex();
OB.rebuildUserTradeIndex(rebuilt, s);
eqN("rebuild entries == incremental entries", OB.userTradeIndexEntries(rebuilt), OB.userTradeIndexEntries(live));
for (p in ps.vals()) {
  eqT("rebuild == incremental for " # Principal.toText(p), OB.getUserTradesIndexed(rebuilt, p, 5_000), OB.getUserTradesIndexed(live, p, 5_000));
};

// ── indexed lookups == legacy walks, every principal, several limits/cursors ──
for (p in ps.vals()) {
  for (lim in [0, 1, 7, 200, 5_000].vals()) {
    eqT("getUserTrades(" # Nat.toText(lim) # ") " # Principal.toText(p),
        OB.getUserTradesIndexed(live, p, lim), OB.getUserTrades(s, p, lim));
  };
  for (since in [0, 1_000, 1_501, 2_000, 4_000].vals()) {
    eqT("getUserTradesSince(" # Nat.toText(since) # ") " # Principal.toText(p),
        OB.getUserTradesSinceIndexed(live, p, since, 200), OB.getUserTradesSince(s, p, since, 200));
    eqT("getUserTradesSince(" # Nat.toText(since) # ", limit 3) " # Principal.toText(p),
        OB.getUserTradesSinceIndexed(live, p, since, 3), OB.getUserTradesSince(s, p, since, 3));
  };
  for (sinceId in [0, 1, 500, 999, 1_000, 5_000].vals()) {
    eqT("getUserTradesSinceId(" # Nat.toText(sinceId) # ") " # Principal.toText(p),
        OB.getUserTradesSinceIdIndexed(live, p, sinceId, 200), OB.getUserTradesSinceId(s, p, sinceId, 200));
    eqT("getUserTradesSinceId(" # Nat.toText(sinceId) # ", limit 4) " # Principal.toText(p),
        OB.getUserTradesSinceIdIndexed(live, p, sinceId, 4), OB.getUserTradesSinceId(s, p, sinceId, 4));
  };
};
truth("a self-crossed fill appears once in its party's history",
  (func() : Bool {
    let h = OB.getUserTradesIndexed(live, ps[0], 5_000);
    var seen = 0; for (t in h.vals()) { if (t.id == 1) { seen += 1 } };   // fill #1 (i = 0) is alice/alice
    seen == 1
  })());
eqN("virgin principal: []", OB.getUserTradesIndexed(live, virgin, 200).size(), 0);
eqN("virgin principal since 0: []", OB.getUserTradesSinceIndexed(live, virgin, 0, 200).size(), 0);
eqN("virgin principal sinceId 0: []", OB.getUserTradesSinceIdIndexed(live, virgin, 0, 200).size(), 0);

// ── anonymous returns [] before any lookup, even when the tape names it ──
let anonT = OB.recordTrade(s, mkt, 0, 0, anon, ps[1], 10_000_000_000, 100_000_000, ts + 10, ?#limit);
OB.indexUserTrade(live, anonT);
eqN("anonymous getUserTradesIndexed: [] (early return)", OB.getUserTradesIndexed(live, anon, 200).size(), 0);
eqN("anonymous SinceIndexed: []", OB.getUserTradesSinceIndexed(live, anon, 0, 200).size(), 0);
eqN("anonymous SinceIdIndexed: []", OB.getUserTradesSinceIdIndexed(live, anon, 0, 200).size(), 0);
truth("…while the legacy walk would have returned the anonymous fill", OB.getUserTrades(s, anon, 200).size() == 1);

// ── prune after a simulated global trim == rebuild from the trimmed tape ──
// Trim the oldest 600 (keep ids ≥ 601), the shape main.mo's TRADES_GLOBAL_CAP
// trim produces; dave-only principal check: a principal whose every fill sits
// below the cut loses its key entirely.
let lone = Principal.fromBlob(Text.encodeUtf8("uti-lone"));
let sLone = OB.emptyStore();
let idxLone = OB.newUserTradeIndex();
let tl = OB.recordTrade(sLone, mkt, 0, 0, lone, ps[0], 1, 1, 1, null);
OB.indexUserTrade(idxLone, tl);
eqN("lone principal indexed", OB.getUserTradesIndexed(idxLone, lone, 10).size(), 1);
eqN("prune drops the lone principal's only fill (2 entries: both parties)", OB.pruneUserTradeIndex(idxLone, tl.id + 1), 2);
truth("…and its key is gone", not Map.containsKey(idxLone, Principal.compare, lone));
eqN("…entries 0", OB.userTradeIndexEntries(idxLone), 0);

let n = List.size(s.trades);
let keepFrom : Nat = 600;
let keeper = List.empty<Types.Trade>();
for (t in List.range(s.trades, keepFrom, n)) { List.add(keeper, t) };
List.clear(s.trades);
for (t in List.values(keeper)) { List.add(s.trades, t) };
let oldest = switch (List.first(s.trades)) { case (?t) { t.id }; case null { 0 } };
eqN("trimmed tape's oldest id", oldest, 601);
let dropped = OB.pruneUserTradeIndex(live, oldest);
truth("prune dropped exactly the evicted parties", dropped > 0 and OB.userTradeIndexEntries(live) == OB.tapePartyCount(s));
let after = OB.newUserTradeIndex();
OB.rebuildUserTradeIndex(after, s);
eqN("post-prune entries == rebuild-from-trimmed-tape entries", OB.userTradeIndexEntries(live), OB.userTradeIndexEntries(after));
for (p in ps.vals()) {
  eqT("post-prune == legacy walk on the trimmed tape " # Principal.toText(p), OB.getUserTradesIndexed(live, p, 5_000), OB.getUserTrades(s, p, 5_000));
  eqT("post-prune sinceId 0 == legacy " # Principal.toText(p), OB.getUserTradesSinceIdIndexed(live, p, 0, 200), OB.getUserTradesSinceId(s, p, 0, 200));
};
truth("no indexed fill predates the trimmed tape",
  (func() : Bool {
    var ok = true;
    for ((_, l) in Map.entries(live)) { for (t in List.values(l)) { if (t.id < oldest) { ok := false } } };
    ok
  })());

Debug.print("UserTradeIndex.test: all passed");
