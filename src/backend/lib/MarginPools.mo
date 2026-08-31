// MarginPools.mo — first-class margin pools & positions (PURE core), in integer
// base units (10^8 — see lib/Fixed.mo). `size` and PnL are SIGNED (Int);
// prices/values are Nat. The VWAP scale cancels (qty×price/qty = price); PnL =
// priceDiff × qty / SCALE with the sign applied separately.
//
// A margin pool is a user-owned sub-account principal. The existing
// principal-scoped engine (Accounts / BorrowEngine / MarginEngine / Liquidator)
// supplies a pool's collateral, debt, and health UNCHANGED — so this module
// holds no state and does no I/O. It owns the Pool / Position TYPES, the
// deterministic pool-principal derivation, the position accounting (`applyFill`)
// and the display math. See docs/margin-pools-design.md.

import Principal "mo:core/Principal";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Types "Types";
import Fixed "Fixed";
import SafeMath "SafeMath";

module {

  // Isolated => the engine refuses a second market in the pool (one position,
  // segregated risk). Cross => many positions share the pool's collateral.
  public type Mode = { #isolated; #cross };

  public type Pool = {
    id        : Nat;
    owner     : Principal;
    name      : Text;            // user-facing label ("BTC swing", "hedge")
    mode      : Mode;
    createdAt : Int;
  };

  // A first-class position inside a pool. `size` is reconciled to the pool's
  // real net exposure; `entryPrice` and `realizedPnl` are STORED truths
  // (not derivable from balances), updated by `applyFill` at settlement.
  public type Position = {
    poolId      : Nat;
    marketId    : Types.MarketId;
    baseToken   : Types.TokenId;
    size        : Int;          // signed base units: + long, − short
    entryPrice  : Nat;          // VWAP, in quote (ICPUSD)
    realizedPnl : Int;          // cumulative, in quote (signed)
    openedAt    : Int;
  };

  // ── Pool sub-account principal (deterministic, injective on poolId) ──
  // poolId comes from a GLOBAL counter, so it is globally unique; encode it
  // (tagged) into a 9-byte principal blob. Uniqueness by construction — no
  // hash required; the tag byte avoids colliding with II / AMM / insurance
  // principals. Authorization is by the registry (pools[poolId].owner).
  let POOL_TAG : Nat8 = 0x70; // 'p'

  public func poolPrincipal(poolId : Nat) : Principal {
    // byte 0 = tag, bytes 1..8 = poolId big-endian (supports 2^64 pools).
    let bytes = Array.tabulate<Nat8>(9, func(i : Nat) : Nat8 {
      if (i == 0) { POOL_TAG } else {
        let shift : Nat = (8 - i) * 8;      // i=1 → 56 … i=8 → 0
        Nat8.fromNat((poolId / (2 ** shift)) % 256)
      }
    });
    Principal.fromBlob(Blob.fromArray(bytes));
  };

  // ── Position accounting: apply a fill (PURE) ──────────────────────
  // `fillSize` is signed: +buy base, −sell base. Returns the new (size,
  // entryPrice) and the realized PnL this fill produced (in quote).
  // Standard perp accounting: VWAP on open/increase; realize on reduce/flip;
  // entry resets to fill price on a flip, to 0 when flat.
  public type FillResult = { size : Int; entryPrice : Nat; realizedDelta : Int };

  public func applyFill(size : Int, entry : Nat, fillSize : Int, fillPrice : Nat) : FillResult {
    if (fillSize == 0) { return { size; entryPrice = entry; realizedDelta = 0 } };
    let newSize = size + fillSize;
    let sameDir = size == 0 or ((size > 0) == (fillSize > 0));
    if (sameDir) {
      // Open or increase in the same direction → VWAP the entry.
      let absS = Int.abs(size);
      let absF = Int.abs(fillSize);
      // (|S|·entry + |F|·fill) / (|S|+|F|): the qty scale cancels → a price.
      let newEntry = if (absS + absF == 0) { fillPrice }
                     else { (absS * entry + absF * fillPrice) / (absS + absF) };
      { size = newSize; entryPrice = newEntry; realizedDelta = 0 }
    } else {
      // Reduce or flip → realize PnL on the closed quantity.
      let absS = Int.abs(size);
      let absF = Int.abs(fillSize);
      let reduceQty = Nat.min(absF, absS);
      // realized = (fill − entry) · reduceQty · dir, dir = sign(closed side).
      // Magnitude via mulDiv (round DOWN), then the sign applied.
      let mag = Fixed.mulDiv(Int.abs((fillPrice : Int) - (entry : Int)), reduceQty, Fixed.SCALE, false);
      let priceUp   = fillPrice >= entry;
      let longClose = size > 0;
      let realized : Int = if (priceUp == longClose) { mag } else { -mag };
      let newEntry =
        if (newSize == 0) { 0 }                  // flat
        else if (absF <= absS) { entry }         // pure reduce — entry unchanged
        else { fillPrice };                      // flip — remainder opens at fill
      { size = newSize; entryPrice = newEntry; realizedDelta = realized }
    }
  };

  // ── Display math (PURE) ───────────────────────────────────────────
  public func notional(size : Int, mark : Nat) : Nat { Fixed.mul(Int.abs(size), mark, false) };

  // Signed: a short (size < 0) profits when mark < entry.
  public func unrealizedPnl(size : Int, entry : Nat, mark : Nat) : Int {
    let mag = Fixed.mulDiv(Int.abs((mark : Int) - (entry : Int)), Int.abs(size), Fixed.SCALE, false);
    let markUp = mark >= entry;
    let isLong = size >= 0;
    if (markUp == isLong) { mag } else { -mag };
  };

  // Pool margin usage ∈ [0,1] (at 10^8); 1.0 = at the liquidation line.
  // The UX "% to liquidation" is 1 − usage.
  public func marginUsage(collateralUsd : Nat, debtUsd : Nat, maintenance : Nat) : Nat {
    if (debtUsd == 0) { return 0 };
    if (collateralUsd == 0) { return Fixed.SCALE };
    Nat.min(Fixed.SCALE, Fixed.mulDiv(maintenance, debtUsd, collateralUsd, true))
  };

  // ── Liquidation price, debt-aware and per-leg (#15.4 + OhShii terms 2/3) ──
  //
  // DERIVATION. getHealth liquidates when coll/debt < maintenance (M). Split
  // both sides into the leg that moves with THIS market's base price p and
  // the legs that do not (they are valued at their own, unmoved, marks):
  //
  //   coll(p) = otherColl + heldBase·ltv·p     heldBase = balance + reserved,
  //                                            the SAME balance definition
  //                                            MarginEngine.valuations uses
  //   debt(p) = otherDebt + debtBase·p         debtBase = base-token loan
  //
  // Setting coll(p) = M·debt(p) and solving for the crossing:
  //
  //   p · (heldBase·ltv − M·debtBase) = M·otherDebt − otherColl
  //
  // The scalars stay ON THEIR OWN LEG: netting heldBase − debtBase first and
  // scaling the net by M alone (the pre-#15.4 short formula) mis-states the
  // denominator by heldBase·(M − ltv) > 0 whenever residual base is held —
  // the reporter's table: $289.86 shown where the true crossing is $180.18.
  //
  // The sign of A = heldBase·ltv − M·debtBase picks the liquidation
  // DIRECTION — not the sign of the net size: ltv < M, so a pool can be net
  // long in base yet still liquidate on a RISING mark.
  //   A > 0 (long-like, health falls as p FALLS):
  //       p = (M·otherDebt − otherColl) / A
  //       null when otherColl ≥ M·otherDebt — the price-independent legs
  //       alone keep health at/above M, no downward crossing exists.
  //   A < 0 (short-like, health falls as p RISES):
  //       p = (otherColl − M·otherDebt) / (−A)
  //       numerator ≤ 0 → 0: liquidatable at EVERY price; a price at/below
  //       the mark is the existing "you are already there" display signal.
  //   A = 0: health is price-insensitive → null.
  //
  // W5-03 DIRECTION, kept: these prices are the DISPLAY surface (the
  // liquidation decision itself is getHealth's ratio, rounded DOWN =
  // protocol-safe). A displayed liquidation price must be CONSERVATIVE —
  // shown as no farther than reality — so a long-like price (mark FALLS to
  // it) rounds UP and a short-like price (mark RISES to it) rounds DOWN.
  // Both are served by the same component roundings: held-base collateral
  // DOWN, maintenance-scaled debt UP — each pushes p toward the mark.
  public func liqPrice(otherCollUsd : Nat, otherDebtUsd : Nat, heldBase : Nat, debtBase : Nat, ltv : Nat, maintenance : Nat) : ?Nat {
    let heldLtv        = Fixed.mul(heldBase, ltv, false);            // DOWN
    let maintDebtBase  = Fixed.mul(maintenance, debtBase, true);     // UP
    let maintOtherDebt = Fixed.mul(maintenance, otherDebtUsd, true); // UP
    if (heldLtv > maintDebtBase) {
      // Long-like: liquidates as the mark falls to P. Round UP.
      if (maintOtherDebt <= otherCollUsd) { return null };
      ?Fixed.div(maintOtherDebt - otherCollUsd, heldLtv - maintDebtBase, true)
    } else if (maintDebtBase > heldLtv) {
      // Short-like: liquidates as the mark rises to P. Round DOWN.
      let num = SafeMath.subOrZero(otherCollUsd, maintOtherDebt);
      ?Fixed.div(num, maintDebtBase - heldLtv, false)
    } else { null };
  };

  // Distance from `mark` to a liquidation price, as a positive fraction (10^8).
  public func pctToLiq(mark : Nat, liq : ?Nat) : ?Nat {
    switch (liq) {
      case null { null };
      case (?p) { if (mark == 0) { null } else { ?Fixed.div(Int.abs((mark : Int) - (p : Int)), mark, false) } };
    }
  };
}
