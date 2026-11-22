// EventChain — the tamper-evidence hash chain over permanent user-history
// events (archive-design.md Phase D).
//
// Each UserEvent carries prevHash = the chain hash of the PREVIOUS event;
// an event's own chain hash is SHA-256 over a CANONICAL serialization of the
// full record (prevHash included). Verifying a slice = recompute each hash
// and check the next event's prevHash equals it; the head of the chain is
// certified by the archive (certified_data), so a reader can trust the head
// via the IC certificate and then verify everything beneath it offline.
//
// The canonical form is deliberately NOT candid: it is a length-prefixed
// field list ("netstring" style: <byteLen>:<bytes> per field, fields in the
// fixed order below), so any language can re-derive it from the decoded
// event with a few lines — no candid re-encoding, no type-table pitfalls.
// Field order is FROZEN (v1); additive event kinds append new tag branches
// but never reorder existing fields. Text fields are UTF-8; principals are
// their canonical text form; ?fields serialize as "" when null (a real hash
// is always 32 bytes and a real principal is non-empty, so "" is
// unambiguous); Int as its decimal text (with '-'); variants as their tag
// name followed by their fields.
//
// Used by BOTH main.mo (computes the chain at capture) and ArchiveCanister.mo
// (re-verifies continuity on append and certifies the head).

import Types "Types";
import Sha256 "mo:sha2/Sha256";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Principal "mo:core/Principal";

module {
  // netstring-append one field (raw bytes) into the buffer
  func put(buf : List.List<Nat8>, bytes : Blob) {
    for (b in Text.encodeUtf8(Nat.toText(bytes.size()) # ":").values()) { List.add(buf, b) };
    for (b in bytes.values()) { List.add(buf, b) };
  };
  func putT(buf : List.List<Nat8>, t : Text) { put(buf, Text.encodeUtf8(t)) };
  func putN(buf : List.List<Nat8>, n : Nat) { putT(buf, Nat.toText(n)) };
  func putI(buf : List.List<Nat8>, i : Int) { putT(buf, Int.toText(i)) };
  func putP(buf : List.List<Nat8>, p : Principal) { putT(buf, Principal.toText(p)) };

  func sideTag(s : Types.Side) : Text {
    switch (s) { case (#buy) { "buy" }; case (#sell) { "sell" } };
  };

  // The canonical byte form of an event (v1). prevHash participates, so the
  // hash of event N commits to the entire history before it.
  public func canonical(e : Types.UserEvent) : Blob {
    let buf = List.empty<Nat8>();
    putT(buf, "v1");
    put(buf, switch (e.prevHash) { case (?h) { h }; case null { "" } });
    putN(buf, e.seq);
    putI(buf, e.ts);
    putP(buf, e.user);
    switch (e.counterparty) { case (?p) { putP(buf, p) }; case null { putT(buf, "") } };
    switch (e.kind) {
      case (#fill(f)) {
        putT(buf, "fill");
        putT(buf, f.marketId); putT(buf, sideTag(f.side));
        putN(buf, f.price); putN(buf, f.qty); putN(buf, f.orderId); putN(buf, f.tradeId);
      };
      case (#deposit(d)) {
        putT(buf, switch (d.kind) { case (#deposit) { "deposit" }; case (#withdrawal) { "withdrawal" } });
        putT(buf, d.token); putN(buf, d.amount); putI(buf, d.timestamp);
      };
      case (#orderClosed(o)) {
        putT(buf, "orderClosed");
        putN(buf, o.id); putT(buf, o.marketId); putT(buf, sideTag(o.side));
        putT(buf, switch (o.orderType) { case (#market) { "market" }; case (#limit) { "limit" } });
        putN(buf, o.price); putN(buf, o.quantity); putN(buf, o.filled);
        putT(buf, switch (o.status) {
          case (#filled) { "filled" }; case (#cancelled) { "cancelled" };
          case (#open) { "open" }; case (#partiallyFilled) { "partiallyFilled" };
        });
        putI(buf, o.placedAt); putI(buf, o.closedAt);
      };
      case (#liquidation(l)) {
        putT(buf, "liquidation");
        putP(buf, l.user); putT(buf, l.debtToken); putN(buf, l.debtRepaid);
        putN(buf, l.debtRepaidUsd); putT(buf, l.collateralToken); putN(buf, l.collateralSeized);
        putN(buf, l.proceedsUsd); putN(buf, l.penaltyUsd);
        putN(buf, l.healthBefore); putN(buf, l.healthAfter); putI(buf, l.timestamp);
      };
      case (#borrow(b)) { putT(buf, "borrow"); putT(buf, b.token); putN(buf, b.amount) };
      case (#repay(r))  { putT(buf, "repay");  putT(buf, r.token); putN(buf, r.amount) };
      case (#lpDeposit(d)) {
        putT(buf, "lpDeposit");
        putT(buf, d.marketId); putN(buf, d.baseAmount); putN(buf, d.quoteAmount); putN(buf, d.lpMinted);
      };
      case (#lpWithdraw(w)) {
        putT(buf, "lpWithdraw");
        putN(buf, w.lpBurned);
        putN(buf, w.basket.size());
        for ((tok, amt) in w.basket.values()) { putT(buf, tok); putN(buf, amt) };
      };
      case (#insuranceStake(s))   { putT(buf, "insuranceStake");   putN(buf, s.amountUsd); putN(buf, s.shares) };
      case (#insuranceUnstake(u)) { putT(buf, "insuranceUnstake"); putN(buf, u.shares); putN(buf, u.payoutUsd) };
      case (#delta(d)) { putT(buf, "delta"); putT(buf, d.token); putI(buf, d.amount) };
      case (#debtDelta(d)) { putT(buf, "debtDelta"); putT(buf, d.token); putI(buf, d.amount) };
      case (#lpShareDelta(d)) { putT(buf, "lpShareDelta"); putT(buf, d.marketId); putI(buf, d.amount) };
      case (#insShareDelta(d)) { putT(buf, "insShareDelta"); putI(buf, d.amount) };
      case (#gap(g)) { putT(buf, "gap"); putN(buf, g.fromSeq); putN(buf, g.toSeq) };
      case (#config(c)) { putT(buf, "config"); putT(buf, c.setter); putT(buf, c.value) };
    };
    Blob.fromArray(List.toArray(buf));
  };

  // The event's chain hash: link it as the NEXT event's prevHash.
  public func hash(e : Types.UserEvent) : Blob {
    Sha256.fromBlob(#sha256, canonical(e));
  };
};
