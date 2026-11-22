// VaultLock.mo — per-LP LOCKED shares + one global lock-scale index: the pure
// arithmetic that makes the vault's pro-rata instant-liquidity cap race-proof
// under REPEATED withdrawals (operator decision 2026-09-06, task 1788475756;
// the stateless cap of task 1788465539 let an LP iterate: after taking their
// share, their retained shares claimed a slice of the REMAINING cash again —
// a harmonic drain of the stayers' liquidity). No state — primitives in, Nat
// out; the actor owns the map and the two scalars.
//
// THE MODEL. Write S = LP supply, s_i = LP i's shares, H = the held basket
// (USD), NAV = H + (loan book − impairment reserve) − arrears, Lx = NAV − H
// (the value every LP's claim carries that is NOT cash). Each LP holds
// ℓ_i LOCKED shares (Λ = Σ ℓ_i); unlocked shares SHARE the cash: LP i's
// instant cash entitlement is
//     e_i = (s_i − ℓ_i) / (S − Λ) × H                       (Σ e_i = H exactly)
// and a locked share carries loan-book value only. With no locks e_i =
// s_i/S × H — the stateless cap, byte-identical.
//
// EXIT. Redeeming x shares at NAV takes V = x·NAV/S of cash (gross; the vault
// keeps the fee) and must leave every OTHER LP's e_j unchanged, so
// (S' − Λ')/H' = (S − Λ)/H  ⇒  Λ' = Λ − x + (S − Λ)·x·NAV/(S·H): the exiter's
// remaining shares are locked by Δℓ = (S − Λ)·x·NAV/(S·H) − x. At a MAX exit
// (V = e_i) that is exactly all of them — the exiter's cap is 0 until a
// repayment, however many times they call. The 40bp fee stays in the vault
// as cash and, through H', lands on the unlocked shares of everyone who
// stays: another LP's cap never FALLS on an exit; it rises by their slice of
// the fee.
//
// REPAYMENT. A net repayment R converts loan value into cash for every LP
// PRO RATA TO THEIR LOAN CLAIM λ_i = s_i·NAV/S − e_i (all loans are one
// class, so a repayment cannot tell whose loan it was): e_i' = e_i +
// R·λ_i/Lx_pre. Substituting the lock representation for both sides yields a
// COMMON factor c on every lock (one global index, no per-LP loop):
//     c = S·(H − R)·Lx_post / (H·S·Lx_pre − Λ·R·NAV)
// with H, NAV, Lx_post the POST-repayment observables and Lx_pre = Lx_post +
// R. c = 1 at R = 0, c = 0 at a full repayment. (The earlier heuristic
// "1 − R/(S·α)" in the task text did not preserve pro-rata repayment — it
// handed the unlocked LP R·s_j/S, more than their loan claim; this is the
// derived form, pinned in tests/VaultLock.test.mo against the per-LP truth.)
// ISSUANCE and interest accrual change no lock: cash leaves every unlocked
// share uniformly and the loan claim grows uniformly, which the
// representation already expresses through H and NAV. MARK MOVES likewise:
// e_i scales with H. Repayment is detected as the shrink of the per-token
// loan-book units since the last settle, priced at the current marks (a
// price move alone is R = 0) — settled by the actor AT every loan-book
// mutation (task 1788727876: borrow, repay, write-off, seize), with the LP
// touches as the belt; a repayment and a later borrow of the same token can
// therefore never net each other away between two settles.
//
// WRITE-OFF (task 1788752774). A loss written off — `absorbBadDebt`'s
// uncovered residual, the slice the insurance fund could not cover — shrinks
// the loan-book units WITHOUT cash arriving: every loan claim λ_i simply
// falls pro rata (λ_i' = λ_i·(1 − U/Lx)) and every cash entitlement e_i is
// UNCHANGED, so no lock moves. Only the actor can tell the two apart (the
// units-diff cannot), so it passes settle() the CASH-BACKED shrink only:
// `repaidUsd` = the units that left the book MINUS the USD written off.
// What IS cash keeps scaling the locks — a repayment, a seize (the
// collateral lands in the basket in kind, H rises by what the debt fell),
// the netted pair, and the insurance fund's covered slice (it pays the vault
// in the same message). A pure loss is settle(…, repaidUsd = 0): the index
// is untouched and only the post-state clamp below can move Λ. The loss
// itself lands on NAV one-share-class (NAV_i = s_i·NAV/S always — a locked
// LP's λ_i falls by U·s_i/S, not by U·λ_i/Lx: the half of the per-LP truth
// the representation cannot carry, disclosed in docs/amm-vault-design §5).
// Mixed cash C + loss U in one message: e_i' = e_i + C·λ_i'/Lx' with λ_i' =
// s_i·NAV_post/S − e_i the post-loss loan claim and Lx' = Lx_post + C the
// post-loss loan value — which is exactly the derived c on the post
// observables (its Lx_pre = Lx_post + C). Both truths are pinned in
// tests/VaultLock.test.mo against the per-LP model.
//
// CONSISTENCY. Locked shares can never claim more loan value than exists:
// Λ·NAV ≤ S·Lx, i.e. the unlocked per-share cash H/(S − Λ) never exceeds
// NAV/S — which is also what keeps every cap within the caller's unlocked
// shares. Mark drift between touches can breach it (holdings up, loans
// down), and so can a WRITE-OFF large enough that the locked shares' NAV
// (one share class: s_i·NAV/S) exceeds the loan value left — the per-LP
// truth would carry λ_i above the whole book; settle() clamps Λ down to
// S·Lx/NAV, and clears every lock when NAV ≤ H (no loan value at all —
// every share is cash-backed). The clamp is the ONE lock movement a loss can
// cause: it hands the locked LP cash out of the stayers' by at most the
// excess, bounded by the loss.
//
// ROUNDING (F5, the vault's favour at the base unit): a lock rounds UP, the
// total Λ rounds DOWN (so Σ ℓ_i ≥ Λ and Σ caps ≤ H), caps round DOWN, the
// scale index rounds DOWN (a smaller index = smaller locks = a hair more cap
// for locked LPs — Σ caps ≤ H still holds, the representation sums to H by
// construction). The scale is a 10^24 fixed point; Nat is arbitrary
// precision, so products of 10^14-scale amounts with it are exact.

import Nat "mo:core/Nat";
import Fixed "Fixed";

module {
  // 1.0 for the lock-scale index. Effective lock ℓ_i = raw_i × scale / SCALE.
  public let SCALE : Nat = 1_000_000_000_000_000_000_000_000;   // 10^24
  // Below this the actor folds the index into the raw locks (renormalise):
  // still 10^12 of headroom, so a raw written at the floor is exact.
  public let RENORM_FLOOR : Nat = 1_000_000_000_000;              // 10^12

  func subOrZero(a : Nat, b : Nat) : Nat { if (a > b) { (a - b) : Nat } else { 0 } };

  // ℓ_i: one LP's effective lock, rounded UP, never above their balance.
  public func lockOf(raw : Nat, scale : Nat, lpBal : Nat) : Nat {
    if (raw == 0 or scale == 0) { return 0 };
    Nat.min(lpBal, Fixed.mulDiv(raw, scale, SCALE, true))
  };

  // Λ: the total lock, rounded DOWN, never above the supply.
  public func totalLock(rawSum : Nat, scale : Nat, lpSupply : Nat) : Nat {
    if (rawSum == 0 or scale == 0) { return 0 };
    Nat.min(lpSupply, Fixed.mulDiv(rawSum, scale, SCALE, false))
  };

  // The raw units that express an effective lock of `lock` at `scale`,
  // rounded UP (the lock never under-states).
  public func rawFor(lock : Nat, scale : Nat) : Nat {
    if (lock == 0 or scale == 0) { return 0 };
    Fixed.mulDiv(lock, SCALE, scale, true)
  };

  // A redemption of `lpAmount` is within the caller's instant liquidity iff
  //   lpAmount ≤ unlocked  and  lpAmount × NAV × (S − Λ) ≤ unlocked × H × S
  // (exact integers). With Λ = 0 this is the stateless cap of task 1788465539.
  public func withinCap(lpAmount : Nat, lpBal : Nat, lock : Nat, lpSupply : Nat, totalLocked : Nat, holdingsUsd : Nat, navUsd : Nat) : Bool {
    let unlocked = subOrZero(lpBal, lock);
    if (lpAmount > unlocked) { return false };
    let free = subOrZero(lpSupply, totalLocked);
    lpAmount * navUsd * free <= unlocked * holdingsUsd * lpSupply
  };

  // The largest lpAmount withinCap accepts. navUsd == 0: every unlocked share
  // is worth 0 and passes (the actor's zero-basket guard refuses the burn).
  public func capLp(lpBal : Nat, lock : Nat, lpSupply : Nat, totalLocked : Nat, holdingsUsd : Nat, navUsd : Nat) : Nat {
    let unlocked = subOrZero(lpBal, lock);
    if (unlocked == 0) { return 0 };
    if (navUsd == 0) { return unlocked };
    let free = subOrZero(lpSupply, totalLocked);
    if (free == 0) { return 0 };
    Nat.min(unlocked, Fixed.mulDiv(unlocked * holdingsUsd, lpSupply, free * navUsd, false))
  };

  // The caller's instant cash entitlement e_i, net of the exit fee (USD,
  // rounded DOWN): unlocked / (S − Λ) × H × keepBps / 10_000.
  public func capUsd(lpBal : Nat, lock : Nat, lpSupply : Nat, totalLocked : Nat, holdingsUsd : Nat, keepBps : Nat) : Nat {
    let unlocked = subOrZero(lpBal, lock);
    let free = subOrZero(lpSupply, totalLocked);
    if (unlocked == 0 or free == 0) { return 0 };
    Fixed.mulDiv(unlocked * holdingsUsd, keepBps, free * 10_000, false)
  };

  // The NAV carried by locked shares, Λ × NAV / S (rounded DOWN) — what a
  // prospective depositor subtracts from NAV to predict their own instant
  // fraction: (H + V) / (NAV − lockedNav + V) × keep.
  public func lockedNavUsd(totalLocked : Nat, lpSupply : Nat, navUsd : Nat) : Nat {
    if (totalLocked == 0 or lpSupply == 0) { return 0 };
    Fixed.mulDiv(totalLocked, navUsd, lpSupply, false)
  };

  // The exiter's lock AFTER redeeming `lpAmount` of `lpBal` (pre-exit S, Λ,
  // H, NAV): ℓ + Δℓ with Δℓ = (S − Λ)·x·NAV/(S·H) − x rounded UP, clamped to
  // the remaining balance. Δℓ ≤ 0 (the exiter burned more NAV than the cash
  // they took — a vault at ~zero utilisation, where the fee exceeds the loan
  // slice) locks nothing.
  public func lockAfterExit(lpBal : Nat, lock : Nat, lpAmount : Nat, lpSupply : Nat, totalLocked : Nat, holdingsUsd : Nat, navUsd : Nat) : Nat {
    let bal2 = subOrZero(lpBal, lpAmount);
    if (bal2 == 0 or holdingsUsd == 0 or lpSupply == 0) { return 0 };
    let free = subOrZero(lpSupply, totalLocked);
    let claim = Fixed.mulDiv(free * lpAmount, navUsd, lpSupply * holdingsUsd, true);
    let delta = subOrZero(claim, lpAmount);
    Nat.min(bal2, lock + delta)
  };

  // The settlement at a touch or a mutation. Inputs are the CURRENT
  // observables plus `repaidUsd` = the CASH-BACKED loan-book units that LEFT
  // the book since the last settle, at current marks — the actor nets the
  // written-off USD out first (a pure loss is repaidUsd = 0; header,
  // WRITE-OFF). Returns the new scale, or `clear` when every lock is dead
  // (drop the map, reset the index): no loan value (NAV ≤ H), Λ rounds to
  // 0, or a full repayment (c = 0).
  public type Settled = { scale : Nat; clear : Bool };

  public func settle(scale : Nat, rawSum : Nat, lpSupply : Nat, holdingsUsd : Nat, navUsd : Nat, repaidUsd : Nat) : Settled {
    if (rawSum == 0) { return { scale = SCALE; clear = false } };
    if (lpSupply == 0 or navUsd <= holdingsUsd) { return { scale = 0; clear = true } };
    var sc = scale;
    var lam = totalLock(rawSum, sc, lpSupply);
    if (lam == 0) { return { scale = 0; clear = true } };
    let lxPost : Nat = navUsd - holdingsUsd;
    let lxPre = lxPost + repaidUsd;
    // Pre-repayment consistency: Λ·NAV ≤ S·Lx_pre (mark drift can breach it).
    if (lam * navUsd > lpSupply * lxPre) {
      sc := Fixed.mulDiv(sc, lpSupply * lxPre, lam * navUsd, false);
      lam := totalLock(rawSum, sc, lpSupply);
      if (lam == 0) { return { scale = 0; clear = true } };
    };
    if (repaidUsd > 0) {
      // c = S·(H − R)·Lx_post / (H·S·Lx_pre − Λ·R·NAV); H ≤ R means the cash
      // the repayment brought is already gone — nothing left to apportion,
      // every claim is equally cash-backed now: clear.
      if (holdingsUsd <= repaidUsd or lxPost == 0) { return { scale = 0; clear = true } };
      let hPre : Nat = holdingsUsd - repaidUsd;
      let num = lpSupply * hPre * lxPost;
      let den = subOrZero(holdingsUsd * lpSupply * lxPre, lam * repaidUsd * navUsd);
      if (den == 0 or num == 0) { return { scale = 0; clear = true } };
      sc := Fixed.mulDiv(sc, num, den, false);
      lam := totalLock(rawSum, sc, lpSupply);
      if (lam == 0) { return { scale = 0; clear = true } };
    };
    // Post-state consistency (belt): Λ·NAV ≤ S·Lx_post.
    if (lam * navUsd > lpSupply * lxPost) {
      sc := Fixed.mulDiv(sc, lpSupply * lxPost, lam * navUsd, false);
      lam := totalLock(rawSum, sc, lpSupply);
      if (lam == 0) { return { scale = 0; clear = true } };
    };
    { scale = sc; clear = false }
  };

  public func needsRenorm(scale : Nat) : Bool { scale < RENORM_FLOOR };

  // Fold the index into one raw lock (the actor loops the map; each entry
  // rounds UP, so no lock shrinks on a renormalisation).
  public func renormRaw(raw : Nat, scale : Nat) : Nat {
    if (raw == 0 or scale == 0) { return 0 };
    Fixed.mulDiv(raw, scale, SCALE, true)
  };
};
