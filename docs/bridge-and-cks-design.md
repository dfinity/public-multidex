# Multi-Chain Bridge Canister + Chain-Key System (CKS) — Design

*Drafted 2026-06-30. Status: PROPOSAL (nothing implemented). Describes how asset deposit and withdrawal will be handled. To provide optimal user experience, users will not be asked to deposit chain key assets into the exchange. They will be able to directly deposit assets into the DEX from their native chains, including from CEXs.

## 1. Goal and shape

Let users deposit and withdraw **unwrapped assets on their native chains** (BTC, ETH, ERC-20s, SOL, …) and trade them on the DEX as virtual balances. This involves three IC canisters, each **controlled solely by the NNS** (see §11):

| Canister | Role | Holds |
|---|---|---|
| **DEX** | Matching, AMM, margin, the virtual ledger. Gates ingress with `inspect`. | virtual balances only |
| **Bridge** | Custody: per-user external addresses, deposit claim, sweep, withdrawal. | the real assets (via threshold keys) |
| **Archive** | Permanent user history (`docs/archive-design.md`). | tax records |

The Bridge depends on a **Chain-Key System (CKS)** — a thin, chain-agnostic abstraction over the IC's chain-integration primitives (threshold ECDSA, threshold Schnorr/Ed25519, the native Bitcoin API, the EVM-RPC canister, Solana integration, HTTPS outcalls). The CKS does **not** exist off the shelf; §6 specifies the four functions the Bridge needs, and they are implemented per chain on top of those primitives. BTC and SOL are the easy on-ramps; ETH/ERC-20 is the hardest (§9, §13).

## 2. Why a separate Bridge canister

- **DOS mitigaton**. Only users that have deposited into the exchange gain registered user accounts, and can invoke update calls. This is enforced through the definition of a `system func inspect` function, which requires that all update callers are in the `registeredUsers` map or are the controller, here, the NNS. Note that this is not enforced when the DEX is running in dev mode.
- **Custody isolation.** The Bridge is the highest-stakes code in the system (it
  holds everyone's funds). Splitting it from the DEX gives it its own audit surface, upgrade policy, and blast radius.


## 3. Identity glue: one principal across DEX and Bridge

The DEX and Bridge canisters are configured with the **same Internet Identity derivation origin** (via `.well-known/ii-alternative-origins`). Consequence: a signed-in user has the **same principal `P`** on both canisters. This is load-bearing:

- The Bridge derives the user's external addresses from `P` (§5).
- When the Bridge calls the DEX's `creditAndRegister(P, asset, amount)` it can name the exact `P` the DEX's `inspect` function and ledger will key on (no need for a cross-canister identity mapping, or linking handshake).

Authentication is the standard II flow (delegation to a browser session key, 8-hour TTL; see the sign-in path in `frontend/src/main.js`). The browser holds delegations for both canisters from one login ("simultaneously authenticated").

## 4. Deposits page (frontend, served from DEX)

First visit: explanatory text + a **"Create deposit address"** button. Clicking it
asks the Bridge to register the user (derive/reveal their addresses — §5). Initially every chain balance is 0. Thereafter the page shows, per asset:

- the **claimable** balance = `confirmed_inflow − claimed` (§7), with a one-click **Claim**;
- a **pending** line = assets seen at the address but not yet confirmed (UX only).

Display reads are **cached queries** (`ck_query_balance`, §6); they are refreshed by the user's own (rate-limited) verify call, never by the Bridge polling all addresses.

## 5. Per-user addresses — threshold-derived, never held

Each external address is derived under the **subnet's** threshold key with the user's principal `P` as the derivation path, so the private key is never materialised anywhere. Addresses are deterministic from `P`, so "Create deposit address" is really *register/reveal*, not *generate*.

**One key per curve family:**

| Curve | Threshold scheme | Chains |
|---|---|---|
| secp256k1 | threshold **ECDSA** | BTC, ETH + all EVM L1/L2 |
| ed25519 | threshold **Schnorr** | SOL (and other ed25519 chains) |

The public key is formatted into each chain's address convention (BTC: hash → P2WPKH/P2TR; ETH: keccak(pubkey)[12:]; SOL: the ed25519 pubkey itself).

## 6. The CKS interface (four functions)

The Bridge talks to the CKS through exactly three update calls. 
```
1. ck_verify_balance(chain, head_distance, address)  -> Balance         // UPDATE (live outcall; refreshes cache)
2. ck_get_current_tx_fees(chain)                     -> FeeEstimate     // UPDATE
3. ck_transfer_balances(chain, dests[], sources[], auth_data[]) -> TxId // UPDATE
```

- `head_distance` selects the confirmation depth: `0` = chain tip (unconfirmed);
  `REQUIRED_CONFIRMATIONS` = the confirmed view (balance as of `tip − REQUIRED_CONFIRMATIONS`). The user never sees the raw heights.
- `ck_transfer_balances` covers **both** directions: (a) **sweep** — many user deposit
  addresses → the Bridge's central address; (b) **withdraw** — central (± some user addresses) → one (usually) external destination.
- These functions **abstract away gas** (§9). `auth_data` is the per-source authorization the threshold signer produces; the fee is paid from single pool, not by the source. Separating gas from individual transfers, and paying for multiple transfers at once, on BTC involves PSBT, SOL does this natively, ETH with EOA 7702, etc

**Cost control:** every `ck_verify_balance` is an outcall. The Bridge **rate-limits per principal and TTL-caches** so page-refresh spam can't drain cycles. The Bridge does not have to keep scanning every deposit address waiting for tokens to arrive, since it can simply check deposit addresses when users view their Deposit page, waiting to claim them, so work is only proportional to *active claimants*, never to the number of addresses in existence.

## 7. Accounting: two orthogonal ledgers

**Credit axis** (per user, per asset) — drives the DEX virtual balance:

```
claimable = cumulative_confirmed_inflow − claimed
```

`cumulative_confirmed_inflow` is **monotonic** (total ever received at the address,
confirmed to depth `REQUIRED_CONFIRMATIONS`) — *not* the current on-chain balance.
For account chains where a balance query can't yield cumulative inflow, recover it as
`current_balance + total_swept_out` (the Bridge knows what it swept).

**Location axis** (per address) — drives withdrawal sourcing: how much sits at each
user deposit address vs the central address, mutated only by sweeps and withdrawals.

`claimed` is a high-water mark, so **claims are idempotent** (re-claiming credits the
new delta only, never double-counts).

## 8. Deposit flow

1. User signs in (same `P` on DEX + Bridge) → opens Deposit page → Create deposit address (registers, derives addresses).
2. User sends the asset on its native chain to that address — including **directly from a CEX** for chains where the address self-attributes (BTC; §9/§13). The CEX sets no memo and knows nothing about the IC.
3. The page shows pending → confirmed (cached/verified reads). At `REQUIRED_CONFIRMATIONS` the asset is claimable.
4. **Claim** → Bridge calls `ck_verify_balance` (authoritative), computes the new `claimable`, advances `claimed`, then calls the DEX `creditAndRegister(P, asset, amount)`. The DEX adds `amount` to the virtual balance **and** adds `P` to `registeredUsers` (first deposit = registration; off-ingress, bypasses `inspect`).
5. Sweeping happens **later and lazily** (§10) — the coins may still sit at the user's
   deposit address when the virtual credit is already live.

## 9. Gas: one pool, sponsored transactions

All on-chain transactions (sweeps and withdrawals) pay gas from a **single pool**, not from the source address — so a user deposit address holding only the deposited asset can still be moved. Per chain:

| Chain | Sponsorship mechanism |
|---|---|
| BTC | **PSBT** — combine the user UTXOs as inputs + a pool input that covers the fee |
| SOL | a distinct **fee payer** (first signer) pays while the user account authorizes |
| ETH/EVM | **EIP-7702** (Pectra) sponsored EOA tx + a paymaster/relayer |

`auth_data` is the threshold-signed authorization for each source; the pool covers the fee. ETH is materially harder than BTC/SOL and is phased last (§13).

## 10. Sweeping and the gas optimization

Claimed assets are **not** swept immediately. The location ledger (§7) lets the Bridge draw on **all** holdings (central + un-swept user addresses) when sourcing a withdrawal.

However, sweeping occurs at intervals in pursuit of two goals:

- **Minimal:** periodically sweep enough of each asset into the central address so the Bridge always holds enough to source withdrawals and gas. Cheap because one sweep tx can aggregate many sources into one destination.
- **Optimized:** sweep when `ck_get_current_tx_fees` reports low gas costs. The purpose here is to lower overall gas costs where possible, by cheaply creating a single pool from which withdrawals can be made using a single transaction (to prevent large withdrawals involving multiple bundled transactions drawing from multiple sources each of which will consume some minimum amount of gas, possibly when gas is expensive, and furthermore to prevent the creation of "dust," which becomes increasingly expensive to draw on).



## 11. Trust and custody — NNS-only upgradeability

> **STATUS: TARGET STATE, NOT CURRENT STATE.** This section describes the custody
> model the production posture is designed to reach. It is **not** how the live
> deployment runs today. As of 2026-08-02 the DEX, Bridge and Archive canisters
> are controlled by **a single operator principal** (`docs/deploy-to-subnet.md`
> §2), there is no governance gate in the backend, and `resetExchange` →
> `performWorldWipe` will stop and delete every archive canister on any non-
> `#production` posture — including the live `#play` one. The honest statement
> for today is that the ledger is **tamper-evident but neither immutable nor
> authentic**: you can detect alteration, but a controller can still replace the
> record. Read the rest of this section in the future tense until the NNS
> handover in §12 has actually happened.

Under the target model, the DEX, Bridge, and Archive canisters have **the NNS as their sole controller**. There is no administrator principal that can upgrade or drain them; any code change requires an on-chain NNS proposal and community vote (this is how the ckBTC/ckETH minters themselves are governed). Implications:

- No insider key can move user funds; the threshold keys are only ever exercised by the Bridge's code, which is **NNS approved**.
- Upgrades are deliberate and slow (proposal + voting period) — a feature for custody, but it means **no instant hotfix**, so the code must be right and the build **reproducible** so voters can verify the wasm matches the source.


## 12. Invariants and safety

- **Solvency (the peg).** For every asset: `Σ virtual liabilities (DEX) ≤ Σ on-chain holdings (all Bridge addresses + central)`. Every credit, sweep, and withdrawal preserves it; it is **continuously provable** from the confirmed CKS reads. This is the bridge analog of the DEX's exact-Σ-balances rule for trading.
- **Reorg / finality.** Credit happens at claim but sweep is lazy, so a deep reorg could orphan an already-credited deposit and break the peg. Mitigate with conservative per-chain `REQUIRED_CONFIRMATIONS` (treat low-finality chains carefully); the solvency check surfaces any drift.
- **Idempotent claims** (§7) and **idempotent withdrawals** (a withdrawal debits the virtual balance first; the on-chain send references that committed debit).
- **Withdrawal authorization.** The Bridge honours `ck_transfer_balances` only for withdrawal instructions from the DEX (authenticated inter-canister call), after the DEX has debited the user's virtual balance + fee.

## 13. Chain key asset deposits

The main purpose of this design is to allow people to deposit and withdraw assets on their native chains. However, chain key asset twins can be also be deposited, such as ckBTC and ckETH. 

Arguably, users should be made to claim deposits of chain key asset twins, to provide a  user experience that is consistent with native assets. 

## 14. Fees and gas-asset inventory

- **Withdrawal-only fee.** Deposits are free (frictionless onboarding). The withdrawal fee is **`fixed + small_percentage × amount`**, calibrated so it returns, on average, **slightly more than gas**. The fixed component is the key DOS defence: it ensures even a tiny withdrawal more than covers its real gas, and it makes *deposit-then-withdraw* spam net-negative for an attacker. The percentage makes large withdrawals pay proportionally and adds mild exit-stickiness. The fee is **virtual** (a debit on the DEX ledger, like a trade fee); the user receives `amount − fee` on-chain and the DEX retains `fee` in custody.
- **Gas funding loop.** Real gas is paid in each chain's native token from the gas pool, funded by the Treasury. Fees that charge the Treasury can be taken **in the asset or in ICPUSD**, per whichever strategy is best (ICPUSD → ICP → cycles). If the Treasury is short a particular gas asset, it **buys it with ICPUSD on the DEX's own markets** — so the DEX's own liquidity backs the gas inventory, and no chain can bleed its gas reserve as long as the Treasury holds value. (This also reuses the `convertTreasuryToFuel` machinery; see the fee-scheme docs.)

## 15. DOS posture (summary)

- **Address creation is free, but does nothing** until a deposit is claimed — so a flood of derived addresses costs the Bridge nothing (no global poll).
- **Reads are user-triggered, rate-limited, TTL-cached** — outcall cost is proportional to active users, not to address count.
- **Claims are O(1)** (touch one address) and idempotent.
- **The DEX's `inspect`** stays caller-only; registration arrives off-ingress from th Bridge.
- **The withdrawal fixed-fee** prices the only remaining gas-spend vector.

## 16. Build phasing

1. **Asset-agnostic core (locally testable against a mock CKS):** the two-ledger accounting (§7), claim → `creditAndRegister` into the DEX, withdrawal debit + sourcing, the solvency invariant + its continuous check, rate-limited verify.
2. **ckBTC wiring:** per-user address via the minter, `update_balance`, PSBT sweeps.
3. **SOL wiring:** ed25519 address, fee-payer sponsorship.
4. **ETH/ERC-20:** decide wallet-hop vs custom EVM custody; helper-contract or threshold-ECDSA path; 7702 sponsorship.
5. **NNS handover:** reproducible build; transfer controllers to the NNS.

## 17. Open questions

- Exact `REQUIRED_CONFIRMATIONS` per chain (finality vs UX latency).
- Whether to offer ETH/ERC-20 as wallet-hop-only at launch or invest in custom EVM custody for direct deposits.
- Gas-pool target sizing per chain and the Treasury rebalancing cadence.
- Whether large withdrawals get a time-lock / review (custodian hygiene) given NNS-only, no-hotfix upgrades.
- Concrete `auth_data` shapes per chain (PSBT blob, SOL message, 7702 authorization).

## Season boundaries (W4-12, 2026-08-15)

A season reset is TWO-PHASE with the Bridge: `resetSeason` first calls the
Bridge's `adminSeasonWipe` (caller must be the wired DEX or a controller),
which REFUSES while any claim or admission is in flight — a refusal aborts
the reset before anything is wiped. Only on `#ok` does the DEX proceed to
wipe its own half: `playReservedUnits`, `creditedSeq` AND `playAdmitSeq`
(leaving the admit high-water behind inverted the bug — post-reset deposits
up to the old high-water replayed as already-reserved and were admitted with
ZERO allowance charge). The Bridge clears `ledgers` + `admittedUnits`, so
both seq spaces restart together. Design decision recorded: the Bridge gets
a season hook rather than reservations surviving the boundary — a #play
season boundary means the venue restarts, and a claimable surviving on one
side of the pair is exactly the divergence #25.2 reported. In-flight case:
covered by the refusal above.
