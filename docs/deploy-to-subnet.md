# Deploying MULTI/DEX to a dedicated ICP subnet (#play launch)

*2026-07-10. Runbook for the team standing MULTI/DEX up on a **dedicated Internet Computer
subnet** (not the OpenCloud cloud engine). Companion to [deployment-modes.md](deployment-modes.md)
(the #dev/#play/#production **posture** axis) and [play-anti-sybil-design.md](play-anti-sybil-design.md)
(the Google-verified-II gate that must be live before real users arrive).*

> **`PLACEHOLDER` markers below are yours to fill** — subnet id, cycles-wallet identity, and the
> canister ids that come back from the install.

---

## 0. Two orthogonal axes — don't conflate them

The code has **two** independent dimensions. Keep them straight:

| Axis | Values | What it controls | Where set |
|---|---|---|---|
| **Posture** (`DEPLOY_MODE`) | `#dev` · `#play` · `#production` | Which features/admin hooks are on: faucet, the $100k on-ramp cap, test overrides, production locks | `main.mo` transient constant (flip + reinstall) |
| **Runtime target** | `LOCAL` · `CLOUD_ENGINE` · `SUBNET` | **Who pays for cycles**, and therefore how many cycles a call attaches to outcalls / archive spawns | Deploy config + the canister's cycle balance |

This launch is **`DEPLOY_MODE = #play` on the `SUBNET` target.** #play stays exactly as it is on the
cloud engine (fake money, $100k on-ramp, faucet off); only the *target* changes — and with it, who
pays for compute.

### The three runtime targets

| | **LOCAL** | **CLOUD_ENGINE** | **SUBNET** ← this launch |
|---|---|---|---|
| Runs on | pocket-ic / local replica | OpenCloud engine | dedicated IC subnet |
| Who pays cycles | the local replica (free) | the engine (reimbursed externally) | **the canister itself** |
| Canister cycle balance | high (replica mints) | ~0 (engine settles) | **huge (you fund it)** |
| Outcall / spawn attach | real cost | **0** (attaching from ~0 would trap IC0406) | real cost |
| XRC exchange-rate canister | mock (unwired) | unwired | **available — but excluded at launch, see §4** |
| Archive sidecars | spawn locally | engine endows the child (0-attach) | **DEX endows each ~3T child from its own balance** |

**The important part: the cycle-attach logic is already correct for all three, driven by the
canister's balance** — `outcallCycles(cost) = if (balance ≥ cost) cost else 0`, and
`archiveSpawnCycles()` endows the full `ARCHIVE_INITIAL_CYCLES` (3T) only when the balance covers it
plus a 5T headroom. On the engine the balance reads ~0 → it attaches 0 (correct). On a well-funded
subnet the balance is enormous → it attaches the real cost (correct). **So no wasm change is needed
to run on the subnet — the whole job is funding + wiring.**

> *Optional hardening (not required, queued behind the parallel `main.mo` work):* make the target an
> explicit `RUNTIME_ENV : {#local; #cloudEngine; #subnet}` constant so `CLOUD_ENGINE`'s 0-attach is
> stated rather than inferred from a ~0 balance. Given the "fund it with a huge buffer" plan the
> balance heuristic is safe as-is; the explicit constant just removes a fragility (a transiently-low
> subnet balance silently switching to 0-attach). Design is in §7.

---

## 1. Funding — "whatever it takes, with a big buffer"

The plan is to fund with **thousands of trillions of cycles** and never think about it again. Sizing
inputs from the code:

- **Standing balance** must stay above the freezing threshold (scales with stored data, ~1.3–1.5T
  here) **plus** the archive-feeder headroom (`ARCHIVE_FEEDER_MIN_HEADROOM = 5T`) so the DEX can keep
  spawning/fuelling archives.
- **Each archive sidecar** is endowed `ARCHIVE_INITIAL_CYCLES = 3T` at spawn and then burns its own
  cycles growing stable storage (permanent history). Budget several archives over the life of the
  venue and keep them topped (see the top-up script).
- **Price feed**: `OUTCALL_PRICE_CYCLES = 3B` per source-fetch, several sources × several assets,
  every heartbeat window. Rounding error against a Pcycle buffer, but it's continuous.

**Target: fund the backend to ~`PLACEHOLDER` (suggest 5000T+) at install, and keep a low-water of
~1000T.** That is comically more than the burn rate — which is the point.

### Top-up (ongoing)
`scripts/topup.sh` — a one-shot check-and-fill an operator's funded wallet runs on a timer. It tops
the backend, each archive sidecar (`ARCHIVES=true`), **and the Bridge** (`BRIDGE_TOPUP=true`,
default — the claim path runs THROUGH the Bridge, so a frozen Bridge breaks deposits) back to
target when below low-water:

```sh
BACKEND=<PLACEHOLDER-backend-id> WALLET=<PLACEHOLDER-cycles-wallet> \
  TARGET=5000 LOW_WATER=1000 ARCHIVES=true ./scripts/topup.sh
# cron: */15 * * * *  (every 15 min)
```

The DEX also self-feeds its children from its own balance (`tickArchiveFuel` + `tickBridgeFuel`,
5-min watermarks) — the cron is the outer loop that keeps the DEX itself full.

> There is **no self-funding loop on #play**: `convertTreasuryToFuel` mints cycles from
> *chain-ICP-backed* treasury, and #play treasury is fake money. `tickAutoFuel` therefore no-ops on
> #play — the top-up script is the replenishment path. (The self-funding loop is a #production
> feature; leave `setFuelRoute` **unwired** on this launch.)

### Monitoring (now live)
On a real subnet the cycle introspection that was blind on the engine works: the in-app fuel banner,
`getCanisterInfo` cycles/freezing fields, and per-archive `canister_status`. Wire these to alerting;
the meaningful number is **liquid headroom = balance − freezing limit**, not raw balance.

---

## 2. Controllers & identity

- **Controller: a single operator principal for now** (`PLACEHOLDER`). This is fake money and not
  yet decentralized; putting it under the NNS/an SNS would only add proposal latency to every
  update. Revisit for #production.
- Same identity is the deploy identity, the archive owner (the DEX spawns them, so it controls
  them), the AMM LP, and the insurance holder.
- **Do NOT enable blackhole-at-seal** (`setBlackholeAtSeal(true)`) on #play — season resets need to
  delete archives, and a blackholed archive can't be deleted. That's a #production-only switch.

---

## 3. Deploy runbook (skeleton — the deploying team fills the `PLACEHOLDER`s)

`main.mo` stays `DEPLOY_MODE = #play`. **The scripted path is `./scripts/deploy.sh subnet`** — it
remembers the wallet identity + subnet id (`scripts/.subnet.conf`), keeps cycles checking ON
(`VITE_CLOUD_ENGINE=false`), endows the backend CREATE with `SUBNET_CYCLES` (default `5000t`) on a
FIRST install, deploys backend→bridge→frontend, wires `setBridge`/`setDex` (never
`setFuelRoute`/`setXrcCanister`), injects the AI keys, applies the anti-sybil env vars when
`TRUSTED_ATTRIBUTE_SIGNERS`/`FRONTEND_ORIGINS` are exported, and seeds (idempotent — history + $1M
AMM vault + $50k insurance fund). **Re-running the same command is the UPDATE path**: upgrade
install, state preserved, seeding self-skips because the pools exist. The skeleton below is the
manual reference for what the script does; the domain (§3.5), the topup cron (§1) and the bots
(§3.6) remain manual steps.

**After any update that WIDENS the tape's event kinds** (e.g. W2-04's `#gap`): run
`adminUpgradeArchives` (controller) right after the backend leg, so the ACTIVE archive's
`appendBatch` accepts the new variant before the first such event ships. Skipping it is
self-healing but noisy — the ship fails candid decode, the failure streak trips, and the L1 roll
seals the old archive and spawns a fresh one (new wasm) on its own. Sealed archives never receive
new events and can be upgraded at leisure.

```sh
# 1. Build. gen-did.sh first: mops.toml declares src/backend/backend.did
#    as a compat-check INPUT and it is gitignored — a clean checkout does
#    not build without generating it.
mops install && bash scripts/gen-did.sh && icp build

# 2. Create + install on the dedicated subnet from the funded wallet.
#    (Create with a big cycle endowment; --subnet pins placement.)
icp deploy backend  -e subnet --subnet <PLACEHOLDER-subnet-id> --identity <PLACEHOLDER-wallet> --with-cycles <PLACEHOLDER≈5000T>
icp deploy bridge   -e subnet --subnet <PLACEHOLDER-subnet-id> --identity <PLACEHOLDER-wallet>
icp deploy frontend -e subnet --subnet <PLACEHOLDER-subnet-id> --identity <PLACEHOLDER-wallet>

# 3. Wire (re-apply after ANY reinstall — these live in stable vars):
icp canister call backend setBridge "(principal \"<bridge-id>\")" ...
icp canister call bridge  setDex    "(principal \"<backend-id>\")" ...
#   setFuelRoute:  LEAVE UNWIRED on #play (no chain-ICP treasury to burn)
#   setXrcCanister: LEAVE UNWIRED at launch — see §4

# 3b. Canister ENV VARS (the anti-sybil verifier reads these; they do NOT
#     apply to an existing canister on redeploy — use settings update):
icp canister settings update backend -e subnet --identity <wallet> \
  --add-environment-variable "trusted_attribute_signers=rdmx6-jaaaa-aaaaa-aaadq-cai" \
  --add-environment-variable "frontend_origins=https://<frontend-id>.icp.net,https://<frontend-id>.icp0.io,https://<PLACEHOLDER-domain>"
#   EVERY origin the app is served from must be listed, or Verify-with-Google
#   fails closed there. Keep this list in lockstep with II_PINNED_ORIGINS in
#   src/frontend/src/main.js (the II derivation list) — the canonical icp.net
#   origin was missing from this template while being the app's PRIMARY origin
#   (W6-03 question B: verification would fail closed exactly there).
#   fails closed with #FrontendOriginMismatch (the error names the expected list).

# 3c. AI key (can be done or ROTATED post-launch, any time — see scripts/set_ai_key.sh):
bash scripts/set_ai_key.sh --provider anthropic -e subnet --identity <wallet>   # reads scripts/.anthropic-api-key,
#   $AI_API_KEY, --key-file, or hidden prompt; verifies aiConfigured()=true after.
#   LAST provider set WINS (anthropic switches the assistant off Gemini). Use a
#   HIGH-LIMIT key: aiComplete already rate-limits per principal (20/min · 200/h
#   · 500/24h), but launch traffic is many principals.

# 4. Seed (#play): the real routine is scripts/deploy.sh cloud_seed — identical
#    calls work on the subnet with CE_IDENTITY = the controller wallet. It is
#    IDEMPOTENT (bails if AMM pools exist) and does, in order: posture check →
#    fund the LP/insurance identity → inject N days of CoinGecko price history →
#    create+configure AMM pools, price them via fetchAndSetRefPrice (multi-source
#    HTTPS feed = the only price authority) → $1M AMM vault deposits (halves per
#    market) → seed the insurance fund. Knobs: AMM_TVL_TOTAL=1000000 HISTORY_DAYS=9.
#    The $100k creditAndRegister on-ramp cap binds for real users regardless.

# 5. Fund + start monitoring
BACKEND=<backend-id> WALLET=<wallet> ./scripts/topup.sh

# 6. Bots (run from an operator box with the icp CLI + this repo; keep alive in
#    tmux/systemd — the loops are plain bash):
#    scripts/.cloud-engine.conf must hold CE_IDENTITY=<controller wallet> (the
#    funder); then:
IC_ENV=subnet bash scripts/sim_trading.sh 12 2
#    The runner now SELF-HEALS and BREATHES (2026-07-10): a background
#    replenisher polls every bot each 60s (public getTestBalance) and resets any
#    wallet leg below floor back to seed (cash <$10k→$40k, asset <$4k→$15k-at-mid)
#    — refills log as "⛽ simbot_N refilled…" and raise the bot's leaderboard
#    baseline (no fake profit). Volume follows a shared activity model (5-min
#    calm/normal/busy/frenzy regimes × slow tides, ~0.15×–8×, mean ~1.4×) so the
#    tape has sessions and bursts instead of a flat line; the monitor prints
#    "mood ×N". If you edit the script, RESTART the bots (bash reads lazily).
```

**Pre-flight gate before real users:** the Google-verified-II anti-sybil gate
([play-anti-sybil-design.md](play-anti-sybil-design.md)) must be live — note its checklist item:
appending the play frontend origin to `frontend_origins`, and that on an *existing* canister the env
vars need `icp canister settings update … --add-environment-variable` (yaml settings apply on
create/sync, not plain redeploys).

---

## 3.5 Custom domain — do this BEFORE announcing, and pick ONE canonical origin

Registering `<PLACEHOLDER-domain>` with the IC HTTP gateways:

1. **Serve the claim file from the frontend**: add `src/frontend/public/.well-known/ic-domains`
   containing exactly the domain name (one per line), make sure the asset sync doesn't ignore
   dotfiles (`.ic-assets.json5` needs `.well-known` allowed), and redeploy the frontend.
2. **DNS** (at the registrar):
   - `CNAME <domain> → <frontend-id>.icp1.io` (apex domains need ALIAS/ANAME/CNAME-flattening),
   - `TXT _canister-id.<domain> → <frontend-canister-id>`,
   - `CNAME _acme-challenge.<domain> → _acme-challenge.<domain>.icp2.io`.
3. **Register with the boundary infrastructure**: `POST https://icp0.io/registrations`
   `{"name":"<domain>"}`, then poll `GET /registrations/<id>` until `Available` (TLS certs are
   provisioned automatically). Full API: internetcomputer.org docs → custom domains.

**Two identity consequences — the part that bites if skipped:**

- **Internet Identity principals are derived PER ORIGIN.** A user who signs in at
  `https://<domain>` and one who signs in at `https://<frontend-id>.icp0.io` get **different
  principals — different accounts, different balances**. Decide the canonical origin NOW,
  advertise ONLY it, and treat the raw canister URL as internal. (II's alternative-origins
  mechanism could merge them later; do not add that moving part on launch day.)
- **The anti-sybil verifier pins origins.** `frontend_origins` (§3b) must include the domain
  before anyone presses Verify with Google from it — otherwise verification fails closed with
  `#FrontendOriginMismatch`.

---

## 4. Oracle — XRC is **excluded at launch**

The real exchange-rate canister (`uf6dk-hyaaa-aaaaq-qaaaq-cai`) is reachable from a subnet and the
code can call it (`setXrcCanister`, `XRC_CALL_CYCLES = 1B`/request). **We are deliberately leaving it
unwired for this launch:**

- XRC is currently **too slow to be a primary oracle**, and it never was one — the mark comes from
  the multi-source HTTPS feed (Coinbase/OKX/KuCoin/CoinGecko), aggregated with source-agreement +
  jump-breaker gates.
- XRC's only roles in the code are a **divergence cross-check** (banner) and a **fallback** when the
  primary drops below the source floor. Both only engage when it's wired, and both introduce a second
  price authority with **unvalidated latency/behavior on a live venue** — exactly the "unintended
  side effects" we don't want on launch day.
- The failure mode XRC's fallback would cover (primary feed unavailable) is **already handled safely
  without it**: `refPrice` simply freezes, and the merged F1 staleness gate then *pauses liquidations
  and blocks new margin opens* rather than acting on a stale mark. Fail-safe, not fail-open.

**Post-launch**, once XRC latency is characterized, it can be wired as a pure cross-check (it feeds
the divergence banner, doesn't move the mark unless the primary is floored). Not a launch dependency.

---

## 5. What ships as-is vs. what's still open

**Ships as-is on the subnet (no code change):** the balance-driven cycle attach, archive spawn/seal
chain (endows real 3T children when funded), the multi-source oracle over HTTPS outcalls
(IPv4 outcall support landed 2026-07-11, so v4-only hosts like Binance/Kraken are usable —
the old AAAA-only constraint is gone), the F1 liquidation-freshness gate,
the aiComplete key-injection + per-principal rate limits, positions-private (targeted archive
vector gated).

**Must be green before real users (tracked elsewhere):**
- **Anti-sybil gmail-II gate** live ([play-anti-sybil-design.md](play-anti-sybil-design.md)) — the
  $100k-per-principal on-ramp is a wash-trading faucet without it.
- **Idempotent `creditAndRegister`** (finding-1) — a lost-reply retry can double-credit a play
  deposit; land it (main.mo + bridge, breaking Candid arity → `icp canister install --mode upgrade`,
  not `icp deploy`).
- **Heartbeat sharding** — `tickLeaderboard`/`tickTier` walk *every* registered user every 60s; on a
  paid subnet that's a growing per-tick cost as sign-ups accrue. Shard the walk before the crowd.

---

## 6. Post-deploy smoke (on the subnet)

1. `getCanisterInfo` / fuel banner report a real (huge) cycle balance and healthy freezing headroom.
2. Oracle live: `fetchAndSetRefPrice` sets marks from the multi-source feed; `refPriceUpdatedNs`
   fresh; no XRC wired (getXrcCanister = null).
3. Archive: force enough events to spawn a sidecar → it's endowed ~3T, ships, and the client-side
   chain verifier (Ledger page) validates against the certified head.
4. A real liquidation fires off the oracle mark (not local price) — confirm the cascade-resistance
   the docs promise.
5. `DRY_RUN=true topup.sh` reads balances correctly for backend + archives + bridge.
6. Leave the sim bots running; watch burn over a few hours against the buffer; the monitor's
   "mood ×N" should visibly move volume between regimes, and "⛽ refilled" lines should appear
   within the first hours (bots bleed by design).
7. **The full player journey, on the CANONICAL domain, with a fresh Google account**: Sign in with
   Google → Deposit → simulate/claim → allowance decremented → trade a market order → fill appears
   in Account and the public tape. This exercises anti-sybil, bridge wiring, seq idempotency, the
   allowance bucket, and matching in one pass.
8. `getApiDoc` + `getMarketSpecs` answer (agents' first calls); version splash matches the deployed
   build; the play launch banner shows; Ask AI works if a key was set (`aiConfigured()` = true).

---

## 7. Launch-day order of operations — the handover checklist

Print this. Each row has its detail section above.

- [ ] **Build**: `mops install && icp build` on the launch commit; confirm `DEPLOY_MODE = #play` in main.mo (§0)
- [ ] **Deploy**: `./scripts/deploy.sh subnet` — covers the next four rows (create+endow → wire → AI key → seed) in one go; the rows below are the verification checklist (§3)
- [ ] **Create + install** backend/bridge/frontend on the subnet from the funded wallet, backend endowed ~5000T (§3.1–2)
- [ ] **Wire**: `setBridge` / `setDex`; leave `setFuelRoute` + `setXrcCanister` UNWIRED (§3.3, §4)
- [ ] **Env vars**: `trusted_attribute_signers` + `frontend_origins` (canister URL **and** domain) via `settings update` (§3b)
- [ ] **Domain**: `.well-known/ic-domains` in the frontend → DNS records → boundary registration → TLS `Available` (§3.5)
- [ ] **Decide the canonical origin** (the domain), advertise only it — II principals are per-origin (§3.5)
- [ ] **AI key**: `scripts/set_ai_key.sh --provider <anthropic|google>` with the high-limit key; `aiConfigured()` = true (§3c) — rotatable post-launch any time
- [ ] **Seed**: `deploy.sh cloud_seed` equivalent — history + $1M AMM + insurance; idempotent (§3.4)
- [ ] **Cycles cron**: `topup.sh` every 15 min from the funded wallet (backend + archives + bridge) (§1)
- [ ] **Bots**: `IC_ENV=subnet sim_trading.sh 12 2` under tmux/systemd with `CE_IDENTITY` in the conf; confirm mood line + first refills (§3.6)
- [ ] **Smoke**: run §6 end-to-end, ESPECIALLY the fresh-Google player journey on the canonical domain
- [ ] **Alerting**: watch liquid headroom (balance − freezing limit), archive/bridge cycles via `getCanisterInfo`, and an OFF-CHAIN uptime check on the domain (a frozen canister can't report itself)
- [ ] **Do NOT**: enable blackhole-at-seal; wire XRC; wire setFuelRoute; publish the raw canister URL as a sign-in surface

---

## 8. Appendix — the optional explicit `RUNTIME_ENV` constant (queued)

If/when `main.mo` is free (currently owned by the anti-sybil work), harden the target axis:

```motoko
public type RuntimeEnv = { #local; #cloudEngine; #subnet };
transient let RUNTIME_ENV : RuntimeEnv = #subnet;   // flip per target, like DEPLOY_MODE

func outcallCycles(cost : Nat) : Nat {
  if (RUNTIME_ENV == #cloudEngine) { 0 }                      // engine settles externally
  else if (Cycles.balance() >= cost) { cost } else { 0 };    // local/subnet pay; fail-safe if broke
};

func archiveSpawnCycles() : ?Nat {
  if (RUNTIME_ENV == #cloudEngine) { ?0 }                     // engine endows the child
  else {                                                     // local/subnet: the DEX pays
    let bal = Cycles.balance();
    if (bal >= ARCHIVE_INITIAL_CYCLES + ARCHIVE_FEEDER_MIN_HEADROOM) { ?ARCHIVE_INITIAL_CYCLES }
    else { null };   // block (never a 0-cycle child that can't run; never over-attach → uncatchable trap)
  };
};
```

This makes `CLOUD_ENGINE` explicit and drops the `ENGINE_ZERO_BALANCE` inference. Behaviorally
identical to today on a well-funded subnet; it only removes the corner where a transiently-low
subnet balance would silently flip to 0-attach.
