# H-36 — Pre-registration profile/preference records are bounded and purgeable

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 3 (Bridge upgrade + backend #3: season boundary & state growth) · findings F33 · LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: hygiene` — `after: D4`

**Mechanism.** `getMyProfile` creates a `UserProfile` on first hit after `requireAuth`
(`UserAccount.mo:72-89`); `setUserPreferences` bounds payload only (`:127-139`; triage 1.8 cut
the blob 1000×, not the count); `performWorldWipe` preserves both maps (`:16706`); no purge.
Profile creation must stay pre-registration by design, so H-30's choke point deliberately
allowlists it — F33 needs its own answer.

**Fix criteria (per D4).** A bounded, evictable pre-registration store (LRU by `lastSeen`) promoted
to the permanent map on registration; and/or a sharded sweep (`Shard.step`) dropping profiles
and preferences of principals absent from `registeredUsers` after a grace period, exposed as an
operator tool.

**Verify.** Drive N fresh keypairs through `getMyProfile`/`setUserPreferences`: stable heap growth
is capped; a sweep reduces `Map.size` of both maps without touching registered players.

## Done when

- [x] Every **Fix criteria** item above is implemented — as AMENDED by D4's operator answer (a′), which wins where the brief's "and/or … exposed as an operator tool" conflicts with it (below); no stable-field drops (ONE additive stable record, `preRegStore`); candid additive only (`getPreRegStoreStats` open query + two `#dev` hooks — the brief flagged none, the answer's "candid additive at most" covers it)
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (`tests/test_h36_prereg_bound.sh` RED 27/40 on the seat venue's pre-fix `9293eb7` build, `.run/seat1-h36-red.log` — the stats/bounds methods absent, so nothing could be pinned; GREEN 40/40 after; `tests/PreReg.test.mo` 44 pins); adjacent cases enumerated below per README §"Closing a task"
- [x] Full suite green on `#dev` (see the archive note for the run); posture restored to `#play` before merge; deploy hygiene PASS (new H-36 block, 35 pins)
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the code sha (the merge sha is minted by the merge itself)

**done 2026-09-05** (task 1788467633, branch claude/seat-1, on top of main `27f1d36`, code commit `371b5f5`): D4's operator
answer **(a′)** implemented as written — a HARD-CAPPED (write-time, LRU-evict unregistered), AUTONOMOUSLY expiring
(heartbeat step, no operator) pre-registration store, promoted on registration. Where the brief's Fix criteria said "and/or a
sharded sweep … exposed as an operator tool", the operator answer REJECTED (b): MULTI/DEX is NNS-run, so no correctness
property may depend on an operator-triggered tool — nothing here is operator-invoked, and hygiene pins that `tickPreReg` has
no caller but the heartbeat. Per point of the answer:

1. **Hard cap at write time** — `lib/PreReg.mo` is a recency index (`byKey`: principal → seq; `bySeq`: seq → (principal,
   lastSeenNs)); the least-recently-seen entry is always `Map.minEntry(bySeq)`, so touch / evict / expire / trim are
   O(log n) pops with no scan. Every pre-registration WRITE — `getMyProfile`, `setUserPreferences`, `regenerateUsername`
   (all four writers of the two maps; grep re-run: `Map.add(userProfiles|userPreferences` hits exactly those plus the
   `#dev` flood seeder, which uses the same primitive) — calls `preRegTouch` BEFORE it writes: an unregistered caller
   is stamped most-recently-seen and, when NEW at `PREREG_CAP` (10,000; ≈0.5 KB/entry → ≤5 MB peak), the least-recently-
   seen unregistered entry is popped and `preRegDrop` deletes its profile AND preferences (the one deleter). Peak
   `Map.size(userProfiles)` is therefore ≤ registered + 10,000 at any ingress rate. Measured (W5-19): 1,500 synthetic
   fresh principals at cap 500 → size 500, `userProfiles` +500; 10,000 at cap 5,000 → size 5,000, +5,000 total; the
   at-capacity insert (profile create + eviction) cost 227k instr @500 → 251k @5,000 — flat across a 10× cap (an O(n)
   scan would be ≥10×). Cost on the hot path for a REGISTERED caller: one `Map.get(registeredUsers)` (already paid by
   inspect) + one `Map.take` miss.
2. **Autonomous expiry** — the heartbeat's `prereg` subtask (`hbReady`/`hbRun`, breaker-isolated, BELOW the pause gate —
   maintenance, not a safety contract; 60 s cadence) pops entries older than `PREREG_GRACE_NS` (7 days) at
   `PREREG_STEP_BUDGET` (1,000) per tick, plus a `trim` to a lowered cap, plus two SHARDED adoption passes
   (`Shard.step` over `userProfiles`, then `userPreferences`, 500 keys/tick) that pull pre-H-36 residue — unregistered
   records written before this landed — into the store stamped `now`, so the fossil population is bounded and aged out
   without a migration (on the seat venue: 11 residue records adopted within the first minute, `adoptPhase = 2`).
   Live: grace 3 s / cadence 2 s → the store drains to 0 with no admin call between the bound-set and the read;
   5,000 entries drain within 90 s; `getHbHealth` shows `prereg` streak 0 throughout.
3. **Promotion on registration** — `preRegPromote` at all FOUR registration sites (grep `Map.add(registeredUsers` →
   `creditAndRegister`, the `#dev` faucet `addTestTokens`, `setTestBalance`, `bulkSetTestBalances`; the two mixins take
   the hook as a parameter; hygiene asserts a promotion within two lines of every site). Belt: `preRegDrop` re-checks
   `registeredUsers` before deleting, so a registration that skipped promotion is a promotion at drop time, never a
   deletion. Live: the faucet lifts u6 out (`promoted` +1, slot freed); a further flood, then expiry, leave u6's
   profile (same username) and preferences intact; a registered caller's `getMyProfile` never re-enters the store.
4. **Sign-in state included** — the II sign-in HANDSHAKE (nonce) store lives inside `mo:identity-attributes 0.4.1`
   and is already bounded there: `Challenges.maxTotal = 4096`, 5-minute expiry pruned on every issue/consume,
   transient. Not re-implemented — hygiene pins the version and the constants (when `.mops/` is installed). The
   sign-in FINISH side effect (`onIdentityVerified` → the salted verified-email bindings) is deliberately NOT in the
   bounded store: it needs a real Google account through II, not a free keypair, and it is the anti-Sybil key.
5. **Observability** — `getPreRegStoreStats` (open query: size, cap, grace, cadence, evicted/expired/promoted/adopted
   counters, oldest stamp, the two permanent maps' sizes) — the bound is a public measurement; `getApiDoc` §Identity
   tells bot authors pre-registration state is bounded and a deposit makes it permanent.

**Adjacent cases (README §"Closing a task").** Zero/one-unit: cap 0 stores nothing and still serves the request; cap 1
replaces on every new key (unit). A re-touch of the newest entry never evicts its own caller (touch precedes the write —
hygiene pins the order in `setUserPreferences`); an evicted principal that returns is admitted again with a fresh draft
(the accepted degradation); the age of a re-touched key is measured from its LAST stamp (unit); a lowered cap trims at once
in the `#dev` hook and re-converges per tick in production; the H-30 gate is unchanged (an unregistered `createMarginPool`
still refused; `PRE_REGISTRATION_METHOD_SET` untouched — §6d still holds); `getUserPreferences` is an UPDATE that reads
only and never stamps (probe-safe); `performWorldWipe`/`resetSeason` preserve `userProfiles`, and the store is stable, so
a season boundary changes nothing here; the plain upgrade kept state (4 pools, 17 profiles, module hash moved).
**Not done here:** the verified-email bindings stay permanent (point 4 — a doctrine call if ever revisited);
`getUserPreferences` being an update rather than a query is pre-existing and filed as a follow-up (task 1788644470, 2026-09-06: no design reason for the update mode exists, but `update → query` is not a Candid subtype — annotations must match — so the ratchet refuses it within apiVersion 5; recorded under "Queued for the next major bump" in `candid/README.md`, operator-lane follow-up 1788656273 carries the recipe). **REMOTE ROLLOUT
DEFERRED** to the operator's deploy sitting (`1788469062`, operator lane) — law 8; the next upgrade of either target must
be at/after that build anyway.

Verified: `mops check backend` clean (6 pre-existing lintoko errors in oql/mocks); `mops test` 22 files; `test_h36_prereg_bound`
RED 27/40 → GREEN 40/40; `test_h30_unregistered` 48/0; `test_leaderboard` 10/0; `test_audit_2026_08_fixes` 30/0;
`test_deploy_hygiene` PASS; `lint-ratchet` PASS (candid backward-compatible, subtype check); full `run_all` on `#dev`
(archive note); post-merge re-verification recorded in the archive note.
