// VaultMath.mo — pure AMM-vault LP math in integer base units (10^8). The
// ERC-4626-style donation-inflation guard on the mint ratio, and the over-weight
// deposit-fee curve. No state — primitives in, Nat out. Mint rounds DOWN (LP to
// the depositor — protect existing LPs); fee rounds UP (charged to the depositor).

import Nat "mo:core/Nat";
import Fixed "Fixed";
import Types "Types";

module {
  // Max over-weight deposit fee (0.10 at 10^8).
  public let LP_FEE_MAX : Nat = 10_000_000;
  // Virtual share/asset offset (OpenZeppelin pattern), 1.0 at 10^8.
  public let LP_VIRTUAL_LP    : Nat = 100_000_000;
  public let LP_VIRTUAL_VALUE : Nat = 100_000_000;

  // LP minted for a deposit worth `effectiveValue` (already fee-scaled), given
  // the PRE-deposit supply + vault value. First deposit (supply 0) anchors
  // valuePerLP = 1.0; thereafter the virtual offsets bound donation-inflation.
  // Rounds DOWN — the depositor receives no more than their fair share.
  public func mintAmount(effectiveValue : Nat, lpSupply : Nat, vaultTotalQuoteValue : Nat) : Nat {
    if (lpSupply == 0) {
      effectiveValue
    } else {
      Fixed.mulDiv(effectiveValue, lpSupply + LP_VIRTUAL_LP, vaultTotalQuoteValue + LP_VIRTUAL_VALUE, false)
    };
  };

  // ── Redemption at NAV with a pro-rata instant-liquidity cap (task 1788465539) ──
  // Every share redeems at valuePerLP = navUsd / lpSupply — the SAME figure a
  // deposit is minted at (held basket + loan book − insurance arrears, per
  // share) — net of the exit fee (keepBps / 10_000), paid IN KIND from the held
  // basket. The loan book cannot be handed out, so an LP's INSTANT cap is their
  // pro-rata share of what the vault physically HOLDS; the rest of their claim
  // stays as shares (which keep earning) and becomes redeemable as repayments
  // raise holdings. Every rounding below is DOWN — in the vault's favour at the
  // base unit, never a leak to exiters or stayers.

  // Gross NAV value of `lpAmount` shares, before the exit fee.
  public func navValue(lpAmount : Nat, lpSupply : Nat, navUsd : Nat) : Nat {
    if (lpSupply == 0) { return 0 };
    Fixed.mulDiv(lpAmount, navUsd, lpSupply, false)
  };

  // Net payout (USD) for redeeming `lpAmount`: one mulDiv chain so the fee is
  // applied to the exact gross value, not to an already-floored figure.
  public func redeemValue(lpAmount : Nat, lpSupply : Nat, navUsd : Nat, keepBps : Nat) : Nat {
    if (lpSupply == 0) { return 0 };
    Fixed.mulDiv(lpAmount * navUsd, keepBps, lpSupply * 10_000, false)
  };

  // The pro-rata instant cap, EXACT (no rounding): a redemption of `lpAmount`
  // is within the caller's instant liquidity iff its gross NAV value does not
  // exceed the caller's pro-rata share of the held basket —
  //   lpAmount × navUsd / supply  ≤  lpBal × holdingsUsd / supply.
  // Supply cancels, so the comparison is on integers. A caller can therefore
  // never take more than their own share of held assets (F1), and when the
  // vault's liabilities exceed its loan book (navUsd < holdingsUsd) every share
  // is instantly redeemable.
  public func withinInstantCap(lpAmount : Nat, lpBal : Nat, holdingsUsd : Nat, navUsd : Nat) : Bool {
    lpAmount * navUsd <= lpBal * holdingsUsd
  };

  // Max shares redeemable now: the largest lpAmount ≤ lpBal that satisfies
  // withinInstantCap. navUsd == 0 means every share is worth 0 — all of them
  // pass the cap (the caller's zero-basket guard is what refuses the burn).
  public func instantCapLp(lpBal : Nat, holdingsUsd : Nat, navUsd : Nat) : Nat {
    if (navUsd == 0) { return lpBal };
    Nat.min(lpBal, Fixed.mulDiv(lpBal, holdingsUsd, navUsd, false))
  };

  // Max instant payout (USD, net of the exit fee): the caller's share of the
  // held basket, fee-scaled. Rounds DOWN.
  public func instantCapUsd(lpBal : Nat, lpSupply : Nat, holdingsUsd : Nat, keepBps : Nat) : Nat {
    if (lpSupply == 0) { return 0 };
    Fixed.mulDiv(lpBal * holdingsUsd, keepBps, lpSupply * 10_000, false)
  };

  // One in-kind basket leg for redeeming `lpAmount`: the held quantity scaled
  // by payout / holdings — held × lpAmount × navUsd × keepBps
  //                       / (supply × holdingsUsd × 10_000) — in ONE mulDiv so
  // the legs sum to the payout up to a single base unit per leg. With zero
  // utilisation and no arrears (navUsd == holdingsUsd) this is exactly the
  // classic pro-rata basket × keepBps.
  public func redeemLeg(held : Nat, lpAmount : Nat, lpSupply : Nat, navUsd : Nat, holdingsUsd : Nat, keepBps : Nat) : Nat {
    if (lpSupply == 0 or holdingsUsd == 0) { return 0 };
    Fixed.mulDiv(held * lpAmount, navUsd * keepBps, lpSupply * holdingsUsd * 10_000, false)
  };

  // ── Per-loan impairment reserve (task 1788475754) ──────────────────────────
  // NAV marks the loan book net of EXPECTED loss, not at face value. Per pool,
  // expected loss = PD × LGD, read through the same health figures the
  // liquidator acts on (BorrowEngine.getHealth: debt rounded UP, LTV-weighted
  // collateral rounded DOWN — the LTV IS the liquidation haircut):
  //   LGD = max(0, D − C × (1 − IMPAIRMENT_STRESS))  — the shortfall if the
  //         haircut collateral gaps by a further 15% (the maintenance cushion's
  //         own size) before the seizure completes;
  //   PD  = 0 at/above MAINTENANCE_HEALTH_RATIO (performing — no provision, a
  //         tax on utilisation otherwise); ramps linearly 0 → 1 across the
  //         liquidatable band [1.0, 1.15) ("distance to maintenance"); 1 below
  //         1.0 (under water on the haircut basis).
  // Continuous at both band edges, monotone (falls as h rises, rises as C
  // falls), D at C = 0, 0 at D = 0. Rounded UP — the vault's favour: a
  // provision overstated by a base unit protects stayers, never exiters.
  // The full derivation and the no-double-count argument against the
  // insurance fund's first-loss live in docs/amm-vault-design.md §5.
  public let IMPAIRMENT_STRESS : Nat = 15_000_000;   // 0.15 at 10^8

  public func expectedLoss(debtUsd : Nat, collUsd : Nat) : Nat {
    if (debtUsd == 0) { return 0 };
    let maint = Types.MAINTENANCE_HEALTH_RATIO;
    // Health rounded DOWN: a lower reading is the riskier (conservative) one.
    let h = Fixed.div(collUsd, debtUsd, false);
    if (h >= maint) { return 0 };
    // Stressed recovery rounded DOWN → LGD rounded UP.
    let recovery = Fixed.mul(collUsd, Fixed.SCALE - IMPAIRMENT_STRESS, false);
    if (recovery >= debtUsd) { return 0 };
    let lgd : Nat = debtUsd - recovery;
    if (h < Fixed.SCALE) { return lgd };
    // 1.0 ≤ h < maint: PD = (maint − h) / (maint − 1.0), applied in ONE mulDiv
    // so the ramp is exact to the base unit; rounds UP.
    Fixed.mulDiv(lgd, (maint - h) : Nat, (maint - Fixed.SCALE) : Nat, true)
  };

  // The vault-level reserve: the EXCESS of the book's gross expected loss over
  // the insurance fund's cash (the junior tranche absorbBadDebt draws on
  // first — provisioning gross would double-count it), netted in AGGREGATE
  // (one fund balance covers realised losses in order; per-loan netting would
  // hide N provisions behind the same dollar), and never more than the loan
  // book it impairs (EL ≤ D per pool, but D rounds up where L rounds down).
  public func impairmentReserve(grossExpectedLossUsd : Nat, insuranceUsd : Nat, loanBookUsd : Nat) : Nat {
    let excess : Nat = grossExpectedLossUsd - Nat.min(grossExpectedLossUsd, insuranceUsd);
    Nat.min(excess, loanBookUsd)
  };

  // Deposit-fee multiplier ∈ [1 − LP_FEE_MAX, 1.0] (10^8-scaled) for an asset at
  // `curWeight` vs `targetWeight`. At/under-weight → 1.0; over-weight → a
  // quadratically-ramping fee, rounded UP (against the depositor), capped at MAX.
  public func feeMultiplier(curWeight : Nat, targetWeight : Nat) : Nat {
    if (targetWeight == 0 or curWeight <= targetWeight) { return Fixed.SCALE };
    let over : Nat = curWeight - targetWeight;           // > 0
    let gap  = Fixed.div(over, targetWeight, true);       // fractional over-weight
    let gap2 = Fixed.mul(gap, gap, true);
    let capped = Nat.min(Fixed.SCALE, gap2);              // clamp gap² to 1.0
    let fee = Fixed.mul(LP_FEE_MAX, capped, true);
    Fixed.SCALE - fee
  };
};
