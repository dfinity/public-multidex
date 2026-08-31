# Pre-mainnet hardening checklist

Deploy gate for any **value-bearing / mainnet** deployment. The local demo/sim
intentionally runs with everything in the DEV position (the sim and the
frontend faucet mint via dev endpoints); none of the code guards below change
sim behaviour while `DEPLOY_MODE = #dev`.

> Posture switch: the old boolean is now a three-way
> `DEPLOY_MODE : {#dev; #play; #production}` (`IS_PRODUCTION`/`IS_DEV` are
> derived from it) — **docs/deployment-modes.md** has the full kill matrix and
> the play-target (cloud-engine competition) checklist. This file remains the
> `#production` gate.

## One-time hardening (security review C1 / H3) — landed in code 2026-06-10

- [x] **C1 — `addTestTokens` faucet** is a hard no-op in production builds
      (`src/backend/mixins/UserAccount.mo`, `if (isProduction) { return }`).
      Before this, flipping `IS_PRODUCTION` did **not** close the faucet.
- [x] **C1 audit — `seedAmmPool`** confirmed *not* a mint vector: `requireAuth`
      + transfers the caller's own pre-existing, balance-checked funds into the
      vault. Its remaining issue is C2 (no initial-margin gate) — see blockers.
- [x] **H3a — `IS_PRODUCTION` marked `transient`** (`src/backend/main.mo`).
      A plain `let` in a `persistent actor` is implicitly stable, so flipping
      the literal + `--mode upgrade` would have silently kept the OLD `false`.
- [x] **H3b — `debugInspectByUsername` is controller-only** even in dev builds
      (was: ANY caller, incl. anonymous, could read any user's balances/debts/
      orders by public username while the flag was false). Still a production
      no-op on top.
- [x] Lock-in test: `tests/test_authorization.sh` §4 — asserts the controller
      gate. The hardened build was deployed to the local sim canister on
      2026-06-10 (same upgrade that added the memory stats endpoint; the
      legacy stable `IS_PRODUCTION` field was dropped via a one-shot EOP
      migration, applied then retired — see the note atop main.mo).

## At deploy time (mainnet / any value-bearing target)

- [ ] Flip `DEPLOY_MODE = #production` in `src/backend/main.mo`
      (`transient`, so the literal in the new wasm wins — no stable capture).
- [ ] `icp build backend` + install.
- [ ] **Post-deploy verification that the flip actually landed** (catches any
      future stable-capture regression):
  - `getDeployMode()` → `"production"`.
  - `addTestTokens("BTC", <amount>)` as a normal identity → **traps**
    (`addTestTokens is a dev-only faucet (posture: play/production)`);
    balance **unchanged** (`getBalance("BTC")`). (Was a silent no-op —
    reconciled to the actor's own refuse-loudly rule, W6-02.)
  - `setAmmRefPrice` → `#err("setAmmRefPrice is a dev-only hook (posture: play/production)")`.
  - `debugInspectByUsername("<any-username>")` as a controller → **traps**
    (`debugInspectByUsername is a dev-only hook (posture: play/production)`)
    on #play and #production alike — a wrong `found=false` would claim the
    user does not exist; the refusal is the honest answer.
  - `setTestBalance` **traps** (`setTestBalance is not available on #production`);
    `getTestBalance` **traps** (`getTestBalance is not available on #production`).
    (Both were silent no-op/0 — same reconciliation. The caller-auth `0` for
    non-controllers asking about OTHERS stays: that is the anti-oracle rule,
    not a posture gate.)
  - `setTestEmailBinding` **traps** (`requireDevHook`, `#dev`-only — it used
    to be reachable on `#play`).
  - `injectHistoricalTrades` → `#err("injectHistoricalTrades is not available
    on #production")`. (On `#play` it is genesis-gated instead — accepted only
    until the venue's first `enableAmm`; see docs/deployment-modes.md, "The
    genesis window".)
  - `fundArbitrageur`, `extMarketSwap`, and `donateToVault(_, false)` all
    `#err` — the unbacked-credit interlock every sibling already had.
  - ~~`claimPlayFunds()` → `#err(…)`~~ **REMOVED: the method is retired** (it is
    absent from `main.mo` and `candid/backend.did`, `PLAY_BASKET` is gone, and
    the `tests/test_play_claim.sh` this step used to cite does not exist). The
    live on-ramp is the `PLAY_DEPOSIT_CAP_USD` reservation flow; verify that
    instead.
- [ ] **Wire the oracle fallback**: `setXrcCanister(opt principal
      "uf6dk-hyaaa-aaaaq-qaaaq-cai")` (the real XRC), then smoke:
      `adminRefreshXrcAnchors()` + `getXrcAnchors()` shows fresh anchors for
      the enabled base assets. Stable, but re-apply after any REINSTALL
      (same as `setBridge`). NEVER deploy `src/xrc-mock` to this target.
- [ ] **Wire the fuel route** (treasury → cycles, the auto-top-up):
      `setFuelRoute(opt principal "ryjl3-tyaaa-aaaaa-aaaba-cai", opt
      principal "rkp4c-7iaaa-aaaaa-aaaca-cai")` (ICP ledger + CMC; stable,
      re-apply after a REINSTALL). NEVER deploy `src/fuel-mock` here.
      PREREQ: the DEX's own ICP-ledger account must hold the chain ICP
      backing the treasury's internal ICP (Bridge/ops withdraws custody to
      it) — Stage 2 debits the internal claim in step with the chain spend.
      Smoke: `getFuelStatus()` shows the route; `burnTreasuryIcpToCycles`
      with a dust amount mints real cycles. Auto loop: `setAutoFuel(true)`
      is the default; it acts only below ~2T spendable headroom.
- [ ] **Memory + scheduling settings** (L3 survival):
      `icp canister settings update backend --wasm-memory-threshold
      <bytes>` (e.g. 4.5 GiB against the 5.25 GiB limit) so the on-canister
      `lowmemory()` hook fires an event + dashboard flag before the wall;
      consider `--compute-allocation <pct>` for guaranteed scheduling under
      subnet load (surfaced on Stats → Canister; 0 = best-effort).
- [ ] **Enable blackhole-at-seal**: `setBlackholeAtSeal(true)` — every
      archive that fills from now on becomes immutable at seal (controllers
      emptied; the fuel watermark still funds it). Irreversible per archive;
      this is the operator-proof-history half of Proof of Reserves.
- [ ] Auth + reconciliation, with eyes open about what runs WHERE (W6-02 —
      the old form named three suites as if all three run against mainnet):
      - `tests/test_authorization.sh` — runs against this target (it probes
        with a NON-controller identity by design, never anonymous); its
        admin-positive sections need `--identity <operator>`.
      - `tests/test_fuel_topup.sh` — **local/#dev only**: it drives the
        fuel-mock, which this page forbids deploying here. The mainnet fuel
        verification is the wiring smoke above + the topup cron's first run
        (cycles on Stats → Canister move).
      - Ledger-of-record reconciliation on mainnet: `node
        scripts/verify_ledger.mjs --backend <id> --host https://icp-api.io
        --full` (the standalone verifier — gate-covered by
        `tests/test_verify_ledger_gate.sh`). `tests/test_archive_replay.sh`
        signs its admin plumbing as the LOCAL controller (anonymous) and is a
        local-replica suite.
- [ ] **Ledger page certificate check**: open Stats → Ledger, run "Verify in
      my browser", confirm the result says *IC certificate VALID*. (On the
      local replica this degrades to "certificate check unavailable" —
      pocket-ic certs trap the SDK's BLS verifier; mainnet certs are the
      real thing.)
- [ ] **OrderStore layout note for FUTURE upgrades**: the order book carries
      incrementally-maintained aggregates inside the stable `OrderStore`
      record (`levelAggByMarketSide` + the three per-user exposure maps,
      2026-07-05). Adding/removing fields on that record is memory-
      incompatible under EOP — a mainnet upgrade that touches it needs an
      explicit `(with migration = …)` mapping old→new (empty maps are fine:
      call the controller-only `adminRebuildIndexes()` afterwards to
      repopulate aggregates from raw orders). On dev, reinstall+reseed.
      Post-upgrade smoke either way: `adminVerifyBookAggregates()` →
      `(vec {})`. NOTE: `ensureInit` no longer rebuilds indexes on its own
      — see "Upgrade & persistence invariants" in `docs/deployment-modes.md`
      for why that was removed (2026-07-25) and why the repair is now an
      explicit operator action.

## Still-open blockers (necessary ≠ sufficient — see docs/security-review.md)

- [x] **OQL anonymous pre-auth DoS — FIXED 2026-07-29**: `execute` /
      `archiveExecute` are public and authorization is per-entity, resolved
      only AFTER the query parses, so anyone could reach `mo:json` for free
      (a query call bills the caller nothing). Measured on the canister:
      lexing cost grows super-linearly (8 KB → 208 ms, 16 KB → 475 ms,
      **24 KB exceeded the 5e9-instruction message limit**), and ANY UTF-16
      surrogate escape in `D800`–`DFFF` **trapped** it with 'codepoint out of
      range' — a lone `\ud800` and equally a well-formed pair like
      `\ud83d\ude00`. Neither is fixed upstream (`mo:json` 1.4.0 is its
      latest release; `oql-prototype`'s `Json.mo` is byte-identical to ours),
      and neither is helped by the re-vendored planner/indexes, because both
      fire during PARSING. `main.mo` now screens the text before `mo:json`
      sees it (4,096-char cap; surrogate-escape scan; both single-pass) and
      bounds the result window (absent `limit` defaults to 1,000, absurd
      limits clamp, `offset` clamps to 100,000). Lock-in test:
      `tests/test_oql_guard.sh`.

      **Residual, stated plainly:** the executor's early stop applies only
      when there is no `orderBy`/`aggregate`/`groupBy`, and it bounds
      *survivors*, not rows examined — so an aggregate, a sort on an
      unindexed column, or a rarely-matching filter still costs one pass over
      the entity. That is inherent to the executor and cannot be capped from
      the entry point; it is bounded by the venue's own data (an attacker
      cannot cheaply grow it) and is what the re-vendored `IndexedMap` +
      planner exist to serve as stores grow. Worth re-measuring when any
      entity passes ~100k rows: at ~2,900 rows a full scan was ~140 ms, so
      the instruction ceiling is the thing to watch.

- [x] **C2 / H1 / H2 — collateral-escape class — FIXED 2026-06-10** (verified
      sound by the 2026-06-13 review): `depositLp`/`seedAmmPool` (via
      `performLpDeposit`) and `stakeInsurance` margin-gate the collateral they
      remove; `withdrawLp`/`unstakeInsurance` refuse while debt is open; H2
      soft-lock health inflation fixed (`reservedBalance` lookup subtracts
      staged soft-locks); liquidation cancels staged/resting orders + frees
      reserves before the seize (`tryLiquidate` → `cancelAllUserOrders`).
      Model 2 (pool margin) also made the class structurally moot for human
      principals — humans can no longer borrow, so the gates are now
      defense-in-depth. Lock-in tests: `tests/test_liquidation_staged_shield.sh`
      (H2) + `tests/test_margin_collateral_escape.sh` (C2+H1; recreated
      2026-07-03 for the pool era after the original was lost in the
      test-suite migrations).
- [x] **M2 — margin gate re-run at deferred release — FIXED 2026-06-10**:
      `releaseDeferred`/`releaseCrossSwap` re-gate at fill and KILL on breach
      (surfaced via release rejections, not silent).
- [x] **M1 — LP mint during an active circuit-breaker pend — FIXED
      2026-07-03**: `vaultPricesStale` now refuses mints while any HELD leg
      has an ACTIVE pending jump (on top of the existing >5-min staleness
      catch), closing the ≤5-min fresh-pend window where a mint marked at the
      frozen pre-jump price. Held legs only, so first-seeding a market (whose
      own breaker trips for a tick) is unaffected. Withdrawals need no gate —
      `withdrawLp` redeems a pro-rata basket in kind (price-neutral by
      construction). Lock-in: `tests/test_margin_collateral_escape.sh` §3
      (recreated pool-era escape test; dev hook `setTestPendingJump` makes
      the pend deterministic).
- [x] **M3 — source floor on EVERY price-accept path — FIXED 2026-07-03**
      (docs/oracle-xrc-fallback-design.md): GEPTOR / periodic tick / admin
      fetch now share one gate (`applyFreshAggregate`: ≥ `PRICE_MIN_SOURCES`
      of the three primary providers, stddev bound, jump breaker). When the
      floor fails, a fresh **XRC fallback anchor** (background-refreshed from
      the principal wired via `setXrcCanister` — locally the `xrc-mock`
      canister, on mainnet the real XRC; minute-granular by XRC's design,
      verified −30s offset + minute truncation in xrc/utils.rs) is applied
      through the same breaker instead of stalling; divergence vs the anchor
      is warn-logged on healthy accepts. Lock-in:
      `tests/test_oracle_xrc_fallback.sh` (§5 exercises the REAL call path
      through the mock). The `setAmmRefPrice` override is now dev-only
      (dead on #play/#production — docs/deployment-modes.md).
- [x] **Unbounded heap growth — FIXED 2026-06-10** (found the same day when
      the canister bricked at its 3 GiB wasm-memory limit; ~6.4M retained
      orders, ~95% the AMM requoter's cancelled ladder quotes). Shipped:
      closed-order reaper (`reapClosedOrders`, 10s sweeps, 20k/sweep cap,
      pending-match guard, one-sweep grace for user orders), capped per-user
      closed-order history + `getMyClosedOrders` + Account-page "Recently
      Closed Orders" box, storage caps on `userAdjustments`/`userDeposits`,
      memory stats on Stats → Canister. Wasm-memory limit raised to
      5.25 GiB (wasm64 wall is 6 GiB; limit stays an early-warning brake).
      Remaining (below): the durable archive tier.
- [ ] Optional hardening: `system func lowmemory()` hook + a wasm-memory
      threshold setting that logs an event / pauses the requoter before the
      limit is hit.
- [x] **Durable user history (tax-grade records) — ALL PHASES SHIPPED**
      (A′ capture+ship, C browsing/CSV, B chain growth with spawn-ahead /
      sealing / routing / watermark funding, D tamper-evidence hash chain +
      certified head — 2026-07-04, lock-in `tests/test_archive_chain.sh`).
      Design + the two deliberately-deferred items (blackholing awaits
      governance; Region spill awaits evidence): **docs/archive-design.md**.
      Deploy-time note: the hash chain STARTS at first deploy
      (`chainStartSeq` 0) — ship the chain code before mainnet so no
      unverifiable prefix ever exists; smoke with `getCertifiedHead()` +
      `verifyChain(0, 10000)` on the archive after launch.
- [x] **Fixed-point ledger (L4) — DONE 2026-06-28**: full Float→Nat/Int @10^8
      migration (backend + frontend boundary + seeds/tests), rounding always
      against the user / toward solvency, reconciliation exact.
- [x] **2026-06-13 review financial tail — FIXED 2026-07-03 (3de29fe)**:
      netted liquidation slices book realized PnL (exact qty via
      `settleNettedPair`, booked through `bookPoolSide` at mid); isolated-pool
      guard covers PENDING entries; `openPosition` unwinds its borrow when
      staging fails (test: `tests/test_borrow_unwind.sh`);
      `finalise`/`voidPendingMatch` fail CLOSED on reservation desync;
      cross-swap leg 2 spends AVAILABLE balance; FOK-expiry + episodeAcc
      leaks plugged. No known open financial-accounting bugs remain from the
      June reviews — the open surface is oracle-integrity (M1 residual + M3
      above).

## Security headers — VERIFIED LIVE 2026-08-15 (W4-20)

`curl -sD- https://multidex.ai` returned the full strict set (recorded verbatim):

    content-security-policy: default-src 'self';script-src 'self';connect-src 'self'
      http://localhost:* https://icp0.io https://*.icp0.io https://icp-api.io;
      img-src 'self' data:;style-src * 'unsafe-inline';style-src-elem * 'unsafe-inline';
      font-src *;object-src 'none';base-uri 'self';frame-ancestors 'none';
      form-action 'self';upgrade-insecure-requests;
    strict-transport-security: max-age=31536000; includeSubDomains
    x-content-type-options: nosniff
    x-frame-options: DENY
    referrer-policy: same-origin
    (+ permissions-policy denying every capability, x-xss-protection)

Kept verified: `scripts/check_headers.sh <origin>` asserts CSP presence + the key directives
(script-src 'self', object-src 'none', frame-ancestors 'none') + HSTS/nosniff/DENY/referrer, and
`deploy.sh` runs it automatically after every subnet/engine deploy against the first recorded
https origin — a recipe upgrade or config change that drops a header now fails the deploy, loudly.
