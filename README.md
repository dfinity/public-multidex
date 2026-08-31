# MULTI/DEX

A complete crypto exchange — order books, market-making AMM, leveraged margin, yield
vaults, deposit custody, a hash-chained public ledger, analytics, and even its AI
assistant — running **entirely on the Internet Computer** as smart-contract code.
No company servers, no off-chain matching engine, no operations team with a database
console. In production the exchange is upgraded by network governance, not by secret
admin keys.

**Live #play deployment:** https://seapz-kiaaa-aaaa6-qaamq-cai.icp0.io/ — a cloud
competition posture where every sign-on starts with nothing and on-ramps through a
capped play allowance. Balances there are valueless by construction.

> **Status: research prototype under active development.** Not audited. Do not use
> with real funds. See [SECURITY.md](SECURITY.md).

## What's inside

- **Order-book trading** with GEPTOR, a sealed matching engine: orders are staged,
  then released in batched passes around a fresh oracle price — there is no public
  mempool to front-run, and release priority is earned, not bought.
- **Market-making AMM** quoting every book from a shared inventory vault, with the
  protocol's own quotes yielding to resting user orders on release.
- **Margin trading** in segregated pools (per-pool principals): real borrows against
  LTV-weighted collateral, partial liquidations to a restore target, penalties
  accruing to a staked insurance fund. Loss stops at the pool wall.
- **Earn**: provide AMM vault liquidity (LP shares) or stake the insurance backstop.
- **Deposits & withdrawals** through a Bridge canister (currently a stub — the
  production chain-key custody design lives in `docs/bridge-and-cks-design.md`).
- **A public, verifiable ledger**: every balance-changing event is hash-chained into
  an append-only archive with an IC-certified head; the Ledger page re-verifies the
  chain in your browser. Per-user history is permanent (tax-grade), shipped to a
  dedicated archive canister.
- **Earned economics**: fee levels L0–L4 computed on-chain from rolling contribution
  (maker-weighted), access priority under load, and permanent lifetime badges.
- **Intelli**: a generic data explorer and AI assistant over the exchange's live
  state via OQL (row-level, per-caller scoped queries) — the same surface external
  agents can drive.
- **In-app Docs**: the full product story, served by the exchange itself.

## Architecture

| Canister | Source | Role |
| --- | --- | --- |
| `backend` | `src/backend/main.mo` (+ `lib/`, `mixins/`, vendored `oql/`) | The exchange: books, AMM, margin, ledger, OQL, AI proxy |
| `bridge` | `src/bridge/main.mo` | Deposit/withdraw custody **stub**; gates registration |
| `arb` | `src/arb/main.mo` | Simulated cross-venue arbitrageur — pins venue prices to the oracle mark (synthetic assets have no real arbs); see `docs/amm-vault-design.md` |
| `frontend` | `src/frontend/` (Vite, vanilla ES modules) | Asset canister serving the app |
| archive | spawned by `backend` | Append-only, hash-chained event history (spawn-ahead chain) |
| `xrc-mock`, `fuel-mock` | `src/xrc-mock/`, `src/fuel-mock/` | **Dev-only** stand-ins for the exchange-rate canister and ledger/CMC fuel loop — never deploy to value-bearing targets |

Deployment posture is a single flag (`DEPLOY_MODE`: `#dev` / `#play` / `#production`)
with a kill-matrix for test hooks — see `docs/deployment-modes.md`.

## Getting started (local)

Prerequisites: [Node.js](https://nodejs.org) 18+, [mops](https://mops.one)
CLI 2.19.2 (Motoko package manager — it pins the `moc` toolchain, and
`scripts/lint-ratchet.sh` pins *it*, since its defaults decide whether
lockfile integrity is checked), the
[`icp` CLI](https://github.com/dfinity/icp-cli), and
[`ic-wasm`](https://github.com/dfinity/ic-wasm) 0.11.0 on `PATH` (the
`@dfinity/motoko` build recipe in `icp.yaml` shells out to it for the
metadata passes — the installed wasm is its output, not `moc`'s).

```bash
npm install
mops install

# generate the backend candid interface — mops.toml declares it as a
# compat-check INPUT (src/backend/backend.did), it is gitignored, and
# nothing builds without it on a fresh checkout
bash scripts/gen-did.sh

# start a local network and stand the whole exchange up in the repo's
# default posture, #play: deploys all canisters, wires bridge + fuel,
# injects price history, seeds a $1M AMM vault + a $50k insurance fund
# and a maker ladder, and starts the sim bots (the players' standing
# counterparties)
icp network start --background
bash scripts/cold_start.sh

# open the app
open http://frontend.local.localhost:8000/
```

Frontend iteration is build-and-deploy (the app is served by the asset canister,
not a dev server): `npm run build && icp deploy frontend --identity anonymous`,
then hard-refresh. The `#play` seeding itself lives in `scripts/play_start.sh`
(cold_start's default mode runs it); the `#dev` fixture modes
(`cold_start.sh --mode full|matching|amm|pending|load`) refuse to run until
`DEPLOY_MODE` in `src/backend/main.mo` is flipped to `#dev`.

Every deploy target shares one entry point: `./scripts/deploy.sh local|cloud|subnet`.
A first install deploys **and seeds** (the $1M AMM vault + $50k insurance fund);
re-running the same command updates the wasm in place, state preserved. The
dedicated-subnet runbook is `docs/deploy-to-subnet.md`.

## Testing & linting

```bash
mops test                      # Motoko unit tests (engine, books, margin, math)
bash tests/<suite>.sh          # integration suites against a local network
bash scripts/lint-ratchet.sh   # moc type-check + lintoko + M0155 hard-zero gate
```

The lint gate runs as a pre-push hook (`.githooks/pre-push`). What it actually
enforces, so this sentence stays checkable (W6-04): all four program roots
(backend, ArchiveCanister, bridge, arb) must **type-check** with the real build
flags; `lintoko` style lints are **zero** on hand-written code; the `M0155`
(unguarded `Nat` subtraction) count is **ratcheted at a hard zero** across
`src/backend`, `src/bridge` and `src/arb`; the `.mops/` tree must match
`mops.lock`'s per-file SHA-256s; and the published candid must be fresh and
backward-compatible. Remaining non-`M0155` compiler warnings are surfaced as
information, not errors — the gate prints their count on every run.

## Repository layout

```
src/backend/     exchange canister (main.mo, lib/, mixins/, vendored oql/)
src/bridge/      deposit-custody stub canister
src/arb/         arbitrage canister (simulated external market for synthetic assets)
src/frontend/    the app (Vite; src/styles/ split per surface)
src/xrc-mock/    dev-only exchange-rate canister mock
src/fuel-mock/   dev-only ledger/CMC mock for the treasury→cycles loop
scripts/         cold start, seeding, simulators, deploy, lint gate
tests/           Motoko unit tests + shell integration suites
docs/            design documents (AMM/vault, bridge/CKS, deployment modes…)
```

## License

MIT — see [LICENSE](LICENSE). The vendored OQL library
(`src/backend/oql/`, DFINITY's `mo:oql`) is Apache-2.0 — see
[`src/backend/oql/LICENSE`](src/backend/oql/LICENSE) and its
[README](src/backend/oql/README.md) for provenance.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).
