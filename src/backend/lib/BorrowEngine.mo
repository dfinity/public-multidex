// BorrowEngine.mo — borrow/repay primitives + health, in integer base units
// (10^8 — see lib/Fixed.mo).
//
// Interest: lazy + linear, principal × apr × elapsed / YEAR, rounded DOWN with
// carry-forward — deliberately: the clock (lastAccrualNs) only advances when at
// least one whole unit books, so the un-booked fraction keeps accruing and
// nothing is lost, it just books later (accrueLoan below; the earlier round-UP
// minted a phantom minimum unit per touch and made dust shorts unclosable).
// Debt is still VALUED up and collateral valued DOWN everywhere a health
// decision is made — both push toward "more likely to be stopped/liquidated",
// the protocol-safe direction.

import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Principal "mo:core/Principal";
import Types "Types";
import Accounts "Accounts";
import MarginEngine "MarginEngine";
import Fixed "Fixed";

module {

  public type LoanState = Map.Map<Text, Map.Map<Types.TokenId, Types.Loan>>;
  public type PriceLookup = Types.TokenId -> ?Nat;

  public func emptyState() : LoanState {
    Map.empty<Text, Map.Map<Types.TokenId, Types.Loan>>();
  };

  func userKey(p : Principal) : Text { Principal.toText(p) };

  func userLoans(state : LoanState, user : Principal) : ?Map.Map<Types.TokenId, Types.Loan> {
    Map.get(state, Text.compare, userKey(user));
  };

  func ensureUserLoans(state : LoanState, user : Principal) : Map.Map<Types.TokenId, Types.Loan> {
    let k = userKey(user);
    switch (Map.get(state, Text.compare, k)) {
      case (?m) { m };
      case null { let m = Map.empty<Types.TokenId, Types.Loan>(); Map.add(state, Text.compare, k, m); m };
    };
  };

  // ICPUSD = 1.0 (SCALE); else the integer oracle price; 0 if unknown.
  func priceOf(token : Types.TokenId, priceLookup : PriceLookup) : Nat {
    if (token == Types.QUOTE_TOKEN) { return Fixed.SCALE };
    switch (priceLookup(token)) { case (?p) { p }; case null { 0 } };
  };

  // ── Interest accrual (lazy, linear) ────────────────────────────
  // Round DOWN, and only advance the clock when ≥1 whole unit books: the
  // un-booked fraction keeps accruing (lastAccrualNs stays put) until it is
  // honestly worth a unit, so nothing is ever lost — it just books later.
  // The previous round-UP minted a phantom MINIMUM of 1 unit per accrual
  // touch, and accrueAll runs on every pool interaction INCLUDING the 30s
  // liquidation sweep — for a dust debt that is thousands of percent of
  // phantom interest, and it made dust shorts UNCLOSABLE: every close
  // bought the derived size at call time, and by settlement the debt had
  // regrown a unit (seen live: a 0.0000026 SOL short surviving repeated
  // closes). The remaining half of that shape — the interest a LARGE short
  // books between the close's call and its settlement message — is closed
  // by closePosition accruing before it sizes and deleveragePool settling
  // the in-flight base residue from quote under a cap (settleFromQuote,
  // task 1788516128).
  func accrueLoan(loan : Types.Loan, now : Int) : Types.Loan {
    if (now <= loan.lastAccrualNs) { return loan };
    let apr = switch (Types.borrowApr(loan.token)) { case (?r) { r }; case null { 0 } };
    let elapsed : Nat = Int.abs(now - loan.lastAccrualNs);
    let interest = Fixed.mulDiv(loan.principal * apr, elapsed, Fixed.SCALE * Types.YEAR_NS, false);
    if (interest == 0) { return loan };
    { token = loan.token; principal = loan.principal + interest; lastAccrualNs = now };
  };

  public func accrueAll(state : LoanState, user : Principal, now : Int) {
    switch (userLoans(state, user)) {
      case null { };
      case (?m) {
        let updates = List.empty<(Types.TokenId, Types.Loan)>();
        for ((token, loan) in Map.entries(m)) { List.add(updates, (token, accrueLoan(loan, now))) };
        for ((token, fresh) in List.values(updates)) { Map.add(m, Text.compare, token, fresh) };
      };
    };
  };

  // ── Debt views ─────────────────────────────────────────────────
  public func getDebt(state : LoanState, user : Principal, priceLookup : PriceLookup) : [Types.DebtEntry] {
    switch (userLoans(state, user)) {
      case null { [] };
      case (?m) {
        let out = List.empty<Types.DebtEntry>();
        for ((token, loan) in Map.entries(m)) {
          let apr = switch (Types.borrowApr(token)) { case (?r) { r }; case null { 0 } };
          // debtUsd rounded UP (conservative).
          List.add(out, { token; principal = loan.principal; accruedToNs = loan.lastAccrualNs; apr;
            debtUsd = Fixed.mul(loan.principal, priceOf(token, priceLookup), true) });
        };
        Iter.toArray(List.values(out));
      };
    };
  };

  public func debtUsdTotal(state : LoanState, user : Principal, priceLookup : PriceLookup) : Nat {
    var sum : Nat = 0;
    switch (userLoans(state, user)) {
      case null { };
      case (?m) { for ((token, loan) in Map.entries(m)) { sum += Fixed.mul(loan.principal, priceOf(token, priceLookup), true) } };
    };
    sum;
  };

  // Does this principal have a loan record at all (any token, any principal
  // amount — a repaid loan whose entry survived counts)? Conservative
  // emptiness input for the pool scans (H-30).
  public func hasLoanEntry(state : LoanState, user : Principal) : Bool {
    switch (userLoans(state, user)) { case null { false }; case (?_) { true } }
  };

  public func loanOf(state : LoanState, user : Principal, token : Types.TokenId) : Nat {
    switch (userLoans(state, user)) {
      case null { 0 };
      case (?m) { switch (Map.get(m, Text.compare, token)) { case null { 0 }; case (?l) { l.principal } } };
    };
  };

  public func totalOutstanding(state : LoanState, token : Types.TokenId) : Nat {
    var sum : Nat = 0;
    for ((_, m) in Map.entries(state)) {
      switch (Map.get(m, Text.compare, token)) { case null { }; case (?l) { sum += l.principal } };
    };
    sum;
  };

  // ── Health ─────────────────────────────────────────────────────
  public func getHealth(
    state       : LoanState,
    margin      : MarginEngine.MarginState,
    accounts    : Accounts.AccountState,
    reserved    : MarginEngine.ReservedLookup,
    user        : Principal,
    priceLookup : PriceLookup,
  ) : Types.MarginHealth {
    let vals    = MarginEngine.valuations(margin, accounts, reserved, user, priceLookup);
    let collUsd = MarginEngine.collateralValueUsd(vals);
    let debtUsd = debtUsdTotal(state, user, priceLookup);
    let equity : Int = (collUsd : Int) - (debtUsd : Int);
    let ratio   = if (debtUsd > 0) { Fixed.div(collUsd, debtUsd, false) } else { Types.HEALTHY_INF };
    {
      collateralUsd    = collUsd;
      debtUsd;
      equityUsd        = equity;
      healthRatio      = ratio;
      maintenanceRatio = Types.MAINTENANCE_HEALTH_RATIO;
      isLiquidatable   = debtUsd > 0 and ratio < Types.MAINTENANCE_HEALTH_RATIO;
    };
  };

  // ── Borrow ─────────────────────────────────────────────────────
  // The full pre-borrow gauntlet — APR configured, margin account open,
  // vault cap, post-borrow initial-health projection — shared VERBATIM by
  // the real borrow() below and the read-only previewOpenPosition query
  // (one source of truth: the frontend pre-flight asks the canister instead
  // of re-deriving margin math). amount = 0 is a "current health" probe.
  // Runs accrueAll exactly like borrow — in a query context that mutation
  // is discarded with the rest of the state copy. #ok carries the projected
  // health (null when the user would carry no debt).
  public func borrowCheck(
    state          : LoanState,
    margin         : MarginEngine.MarginState,
    accounts       : Accounts.AccountState,
    reserved       : MarginEngine.ReservedLookup,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    amount         : Nat,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : { #ok : ?Nat; #err : Text } {
    switch (Types.borrowApr(token)) {
      case (?_) { };
      case null { return #err(token # " cannot be borrowed (no APR configured)") };
    };
    switch (MarginEngine.get(margin, user)) {
      case (?_) { };
      case null { return #err("Open a margin account first") };
    };

    // Vault-side cap (round the cap DOWN → tighter).
    let vaultHolds = Accounts.getBalance(accounts, vaultPrincipal, token);
    let maxOnLoan  = Fixed.mul(vaultHolds, Types.VAULT_BORROW_FRACTION_CAP, false);
    let outstanding = totalOutstanding(state, token);
    if (outstanding + amount > maxOnLoan) {
      return #err("Vault borrow cap reached for " # token #
        " (outstanding " # Nat.toText(outstanding) # ", cap " # Nat.toText(maxOnLoan) # ")");
    };

    accrueAll(state, user, now);

    // Post-borrow INITIAL-margin check: borrowed funds count as collateral at
    // the token's LTV. Debt valued UP, added collateral valued DOWN, ratio DOWN.
    let price = priceOf(token, priceLookup);
    let ltv   = switch (Types.marginLTV(token)) { case (?x) { x }; case null { 0 } };
    let priorDebtUsd = debtUsdTotal(state, user, priceLookup);
    let newDebtUsd   = priorDebtUsd + Fixed.mul(amount, price, true);
    let curCollUsd   = MarginEngine.collateralValueUsd(
      MarginEngine.valuations(margin, accounts, reserved, user, priceLookup));
    let newCollUsd   = curCollUsd + Fixed.mul(Fixed.mul(amount, price, false), ltv, false);
    if (newDebtUsd == 0) { return #ok(null) };
    let projHealth = Fixed.div(newCollUsd, newDebtUsd, false);
    if (projHealth < Types.INITIAL_HEALTH_RATIO) {
      return #err("Health would fall below the initial-margin requirement. Borrow less, or add funds.");
    };
    #ok(?projHealth);
  };

  // Largest additional `token` borrow that would pass borrowCheck at current
  // marks: min(initial-health room, vault-cap room). Closed form of the same
  // inequality — health = (C + a·ltv)/(D + a) ≥ R  ⇒  a ≤ (C − R·D)/(R − ltv)
  // in USD — with conservative roundings. Advisory (the preview re-verifies
  // the requested size through borrowCheck itself).
  public func maxBorrowable(
    state          : LoanState,
    margin         : MarginEngine.MarginState,
    accounts       : Accounts.AccountState,
    reserved       : MarginEngine.ReservedLookup,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : Nat {
    switch (roomState(state, margin, accounts, reserved, vaultPrincipal, user, token, now, priceLookup)) {
      case null { 0 };
      case (?r) { Nat.min(healthRoom(r.collUsd, r.debtUsd, r.ltv, r.price), r.vaultRoom) };
    };
  };

  // 1788652744: maxBorrowable's two halves, exposed so a book-walking probe
  // can re-score a pool's room per SLICE from a carried (collateralUsd,
  // debtUsd) pair "as if settled" — the same closed form the fill-time
  // borrowCheck's inequality reduces to, evaluated on the state each settled
  // slice leaves rather than once at current marks. roomState is the
  // per-walk snapshot (accrueAll + the ≤5-token valuation, once per pool);
  // healthRoom is the pure closed form (health = (C + a·ltv)/(D + a) ≥ R ⇒
  // a ≤ (C − R·D)/(R − ltv), in `token` units) the walker re-runs per slice.
  // null = the token cannot be borrowed at all (no APR, no margin account,
  // no mark) — the caller scores cash alone.
  public type RoomState = {
    collUsd   : Nat;   // LTV-weighted collateral (reserved included), USD
    debtUsd   : Nat;   // debt valued UP, USD
    vaultRoom : Nat;   // vault cap − outstanding, in `token` units
    ltv       : Nat;   // `token`'s margin LTV
    price     : Nat;   // `token`'s mark (Fixed.SCALE for the quote)
  };
  public func roomState(
    state          : LoanState,
    margin         : MarginEngine.MarginState,
    accounts       : Accounts.AccountState,
    reserved       : MarginEngine.ReservedLookup,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : ?RoomState {
    switch (Types.borrowApr(token)) { case (?_) { }; case null { return null } };
    switch (MarginEngine.get(margin, user)) { case (?_) { }; case null { return null } };
    let price = priceOf(token, priceLookup);
    if (price == 0) { return null };
    let ltv = switch (Types.marginLTV(token)) { case (?x) { x }; case null { 0 } };
    accrueAll(state, user, now);
    let debtUsd = debtUsdTotal(state, user, priceLookup);
    let collUsd = MarginEngine.collateralValueUsd(
      MarginEngine.valuations(margin, accounts, reserved, user, priceLookup));
    let vaultHolds  = Accounts.getBalance(accounts, vaultPrincipal, token);
    let maxOnLoan   = Fixed.mul(vaultHolds, Types.VAULT_BORROW_FRACTION_CAP, false);
    let outstanding = totalOutstanding(state, token);
    let vaultRoom : Nat = if (maxOnLoan > outstanding) { maxOnLoan - outstanding } else { 0 };
    ?{ collUsd; debtUsd; vaultRoom; ltv; price };
  };
  public func healthRoom(collUsd : Nat, debtUsd : Nat, ltv : Nat, price : Nat) : Nat {
    if (Types.INITIAL_HEALTH_RATIO <= ltv or price == 0) { return 0 };
    let rd = Fixed.mul(debtUsd, Types.INITIAL_HEALTH_RATIO, true);
    if (collUsd > rd) {
      Fixed.div(Fixed.div(collUsd - rd, Types.INITIAL_HEALTH_RATIO - ltv, false), price, false)
    } else { 0 };
  };

  public func borrow(
    state          : LoanState,
    margin         : MarginEngine.MarginState,
    accounts       : Accounts.AccountState,
    reserved       : MarginEngine.ReservedLookup,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    amount         : Nat,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : { #ok : Types.DebtEntry; #err : Text } {
    if (amount == 0) { return #err("Amount must be positive") };
    switch (borrowCheck(state, margin, accounts, reserved, vaultPrincipal, user, token, amount, now, priceLookup)) {
      case (#err(e)) { return #err(e) };
      case (#ok(_)) { };
    };

    if (not Accounts.subtractBalance(accounts, vaultPrincipal, token, amount)) {
      return #err("Vault insufficient (race condition?)");
    };
    Accounts.addBalance(accounts, user, token, amount);

    let loans = ensureUserLoans(state, user);
    let priorPrincipal = switch (Map.get(loans, Text.compare, token)) { case (?l) { l.principal }; case null { 0 } };
    let merged : Types.Loan = { token; principal = priorPrincipal + amount; lastAccrualNs = now };
    Map.add(loans, Text.compare, token, merged);

    let apr = switch (Types.borrowApr(token)) { case (?r) { r }; case null { 0 } };
    #ok({ token; principal = merged.principal; accruedToNs = now; apr;
      debtUsd = Fixed.mul(merged.principal, priceOf(token, priceLookup), true) })
  };

  // ── Write-off (liquidator) ─────────────────────────────────────
  public func writeOffLoan(
    state : LoanState, user : Principal, token : Types.TokenId, amount : Nat, now : Int,
  ) : { #ok : Nat; #err : Text } {
    if (amount == 0) { return #err("Amount must be positive") };
    let loans = switch (userLoans(state, user)) { case (?m) { m }; case null { return #err("No loans") } };
    let existing = switch (Map.get(loans, Text.compare, token)) {
      case (?l) { accrueLoan(l, now) };
      case null { return #err("No " # token # " debt to repay") };
    };
    let writeOff = Nat.min(amount, existing.principal);
    let remaining : Nat = existing.principal - writeOff;
    if (remaining == 0) {
      ignore Map.delete(loans, Text.compare, token);
      if (Map.size(loans) == 0) { ignore Map.delete(state, Text.compare, userKey(user)) };
    } else {
      Map.add(loans, Text.compare, token, { token; principal = remaining; lastAccrualNs = now });
    };
    #ok(writeOff);
  };

  public func repayFromVault(
    state : LoanState, vaultPrincipal : Principal, accounts : Accounts.AccountState,
    user : Principal, token : Types.TokenId, amount : Nat, now : Int,
  ) : { #ok : Nat; #err : Text } {
    let _ = vaultPrincipal; let _ = accounts;
    writeOffLoan(state, user, token, amount, now);
  };

  // ── Repay ──────────────────────────────────────────────────────
  public func repay(
    state          : LoanState,
    accounts       : Accounts.AccountState,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    amount         : Nat,
    now            : Int,
    priceLookup    : PriceLookup,
  ) : { #ok : ?Types.DebtEntry; #err : Text } {
    if (amount == 0) { return #err("Amount must be positive") };
    let loans = switch (userLoans(state, user)) { case (?m) { m }; case null { return #err("No loans to repay") } };
    let existing = switch (Map.get(loans, Text.compare, token)) {
      case (?l) { accrueLoan(l, now) };
      case null { return #err("No " # token # " debt to repay") };
    };
    let payable = Nat.min(amount, existing.principal);
    if (Accounts.getBalance(accounts, user, token) < payable) {
      return #err("Insufficient " # token # " to repay " # Nat.toText(payable) # " base units");
    };
    if (not Accounts.subtractBalance(accounts, user, token, payable)) { return #err("Balance subtraction failed") };
    Accounts.addBalance(accounts, vaultPrincipal, token, payable);

    let remaining : Nat = existing.principal - payable;
    if (remaining == 0) {
      ignore Map.delete(loans, Text.compare, token);
      if (Map.size(loans) == 0) { ignore Map.delete(state, Text.compare, userKey(user)) };
      #ok(null)
    } else {
      Map.add(loans, Text.compare, token, { token; principal = remaining; lastAccrualNs = now });
      let apr = switch (Types.borrowApr(token)) { case (?r) { r }; case null { 0 } };
      #ok(?{ token; principal = remaining; accruedToNs = now; apr;
        debtUsd = Fixed.mul(remaining, priceOf(token, priceLookup), true) })
    };
  };

  // ── Settle ALL debt from QUOTE cash ────────────────────────────
  public func settleAllFromQuote(
    state          : LoanState,
    accounts       : Accounts.AccountState,
    vaultPrincipal : Principal,
    user           : Principal,
    now            : Int,
    priceLookup    : PriceLookup,
    maxUsd         : Nat,
  ) : { #ok : Nat; #err : Text } {
    accrueAll(state, user, now);
    let loans = switch (userLoans(state, user)) { case (?m) { m }; case null { return #ok(0) } };
    var costUsd : Nat = 0;
    for ((token, loan) in Map.entries(loans)) { costUsd += Fixed.mul(loan.principal, priceOf(token, priceLookup), true) };
    if (costUsd == 0) { return #ok(0) };
    if (costUsd > maxUsd) {
      return #err("Outstanding debt exceeds the cash-settle limit — repay it in-kind first.");
    };
    if (Accounts.getBalance(accounts, user, Types.QUOTE_TOKEN) < costUsd) {
      return #err("Insufficient " # Types.QUOTE_TOKEN # " to settle debt from cash.");
    };
    if (not Accounts.subtractBalance(accounts, user, Types.QUOTE_TOKEN, costUsd)) { return #err("Balance subtraction failed") };
    Accounts.addBalance(accounts, vaultPrincipal, Types.QUOTE_TOKEN, costUsd);
    ignore Map.delete(state, Text.compare, userKey(user));
    #ok(costUsd)
  };

  // ── Settle ONE token's debt from QUOTE cash (task 1788516128) ──
  // The per-token sibling of settleAllFromQuote: accrues `token`'s loan to
  // `now`, values it at the mark ROUNDED UP against the borrower, refuses
  // when the cost exceeds `maxUsd` (the caller's cap — the discriminator
  // between an interest residue and a real position) or when no mark is
  // known (a free write-off is never a settlement), moves the quote to the
  // vault and deletes the entry outright. Other tokens' loans are untouched.
  // Returns #ok(0) when there is nothing to settle.
  public func settleFromQuote(
    state          : LoanState,
    accounts       : Accounts.AccountState,
    vaultPrincipal : Principal,
    user           : Principal,
    token          : Types.TokenId,
    now            : Int,
    priceLookup    : PriceLookup,
    maxUsd         : Nat,
  ) : { #ok : Nat; #err : Text } {
    let loans = switch (userLoans(state, user)) { case (?m) { m }; case null { return #ok(0) } };
    let loan = switch (Map.get(loans, Text.compare, token)) {
      case (?l) { accrueLoan(l, now) };
      case null { return #ok(0) };
    };
    if (loan.principal == 0) { return #ok(0) };
    let price = priceOf(token, priceLookup);
    if (price == 0) { return #err("No mark for " # token # " — cannot value the debt.") };
    let costUsd = Fixed.mul(loan.principal, price, true);
    if (costUsd > maxUsd) {
      return #err("Outstanding " # token # " debt exceeds the cash-settle limit — repay it in-kind first.");
    };
    if (Accounts.getBalance(accounts, user, Types.QUOTE_TOKEN) < costUsd) {
      return #err("Insufficient " # Types.QUOTE_TOKEN # " to settle " # token # " debt from cash.");
    };
    if (not Accounts.subtractBalance(accounts, user, Types.QUOTE_TOKEN, costUsd)) { return #err("Balance subtraction failed") };
    Accounts.addBalance(accounts, vaultPrincipal, Types.QUOTE_TOKEN, costUsd);
    ignore Map.delete(loans, Text.compare, token);
    if (Map.size(loans) == 0) { ignore Map.delete(state, Text.compare, userKey(user)) };
    #ok(costUsd)
  };
};
