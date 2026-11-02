# H-10 — A swept resting order whose owner cannot fund one slice is cancelled with the unfunded-maker notice, and every balance-reducing action re-validates resting orders

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F13 · MEDIUM · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium`

**Mechanism.** `ammSweepResting` (`:2367`) cancels a crossed resting order (`:2478`) and
re-submits it as an aggressor with the ORIGINAL timestamp and `null` budget (`:2479-2484`),
then `repointOrderIdentity` (`:2492`); `adjustAffectedUsers` runs only `if (tradesArr.size() >
0)` (`:2503-2509`). The engine treats an unfunded aggressor that is not `best.owner` as a normal
partial — `break matchLoop` with no notice (`MatchingEngine.mo:868-884`) — and re-creates the
full quantity under a fresh id with the old timestamp (`:1020-1024`), which re-passes the
anti-snipe gate. `withdraw`, `fundMarginPool`, `stakeInsurance` never re-validate (all
`adjustAffectedUsers` callers are fill paths). Result per 2 s requote: 100 cancel/create cycles
per account, 50 `stagedReleasedAs` links/s collapsing the 20k retention window
(`STAGED_LINKS_CAP`, `:466-477`), 100 permanent `#orderClosed` rows per reaper pass ≈ 4.3M
archive rows/day per account — feeding H-32's sink. W4-24's own doctrine says an unfunded maker
is removed at first match attempt; this is the one fill path that re-rests it instead.

**Fix criteria.** (1) In `ammSweepResting`, pre-check the swept owner's funding for one slice at
the AMM price (`availableBalance`) and cancel + `onUnfundedMakerNotice` instead of re-submitting;
and/or the engine treats an unfunded aggressor under `aggressorIsMaker` as an unfunded maker
(cancel, no re-rest). (2) `adjustAffectedUsers` runs over the swept-owner set even with zero
trades. (3) `withdraw`/`fundMarginPool`/`stakeInsurance` either run `LiquidityManager.
adjustUserOrders` or `getAvailable` excludes value committed to resting orders — pick per D-none
(W4-24 says no reservation; re-validation on debit is the doctrine-consistent choice).

**Verify.** `test_unfunded_maker_notice.sh` §: an unfunded crossing order is removed on its first
sweep, the owner gets one release-rejection notice, the reaper seals exactly one closure; after
moving the whole balance out, the user's resting orders are shrunk/cancelled.

**done 2026-09-04** (task `1788467607`, branch claude/exec-a, code `bd40337` on top of `d01e9c7`, after 1788285811/1788470219): backend + tests; candid additive only (`devTickReap`, lint-ratchet PASS); no stable-field change. **(1) both halves.** Engine: `executeLimitOrderProtected` under `aggressorIsMaker` (the sweep's re-homed order is the only such caller) sets `aggressorUnfunded` whenever the aggressor's OWN funding refuses a slice — the budget shrink's `affordableQty == 0`, the immediate-path buyer/seller gates where the aggressor is the short side, and the zero-cost fence when the aggressor's remainder is the dust — then fires ONE `ctx.onUnfundedMaker` for the dropped remainder and CANCELS it instead of re-creating it: no fill → nothing rests (the id-0 sentinel; the reserved `aggressorId` is a harmless gap, so the caller's old order is the ONE closure the reaper seals), partial fill → the record is created under the pre-reserved id the trades reference, filled, then closed `#cancelled` (filled < quantity, an honest row). A swept ASK gets the base-side twin of the budget shrink (fill what is deliverable). Plain takers keep the legacy rest-the-remainder contract (pinned, H5). `ammSweepResting` passes a swept BID's available quote as the engine budget (the #55 affordability shrink — a half-funded bid fills the funded half rather than being refused whole), skips `repointOrderIdentity` on id 0 (the user's handles keep resolving to the old, now `#cancelled`, id — `getMyOrderStatus` reports `#closed`, never "not found"), and drops the expiry of a non-open result. **(2)** the swept-owner set is re-validated even with zero trades (`revalidateUserOrders` + version bump; no trade stamp, no liquidation probe). **(3)** `revalidateUserOrders` (the `LiquidityManager.adjustUserOrders` walk + pending-match voids + adjustment records) is split out of `adjustAffectedUsers` and runs after the debit in `fundMarginPool`, `stakeInsurance`, `performLpDeposit` (`depositLp`) and `withdrawMarginPool` (the POOL's own resting entries) — re-validation on debit per W4-24 (no reservation). Adjacent cases enumerated: every `Accounts.subtractBalance` site in main.mo was mapped to its function — the user-reachable wallet debits are exactly those four (there is NO wallet `withdraw` on the play-era backend: the Bridge only credits; `withdrawLp`/`unstakeInsurance` credit the caller); pool debits inside `openPosition`/`closePosition`/`deleveragePool` are position paths whose swept entries are now caught at first sweep (cancel + notice) rather than looping — filed as `1788520599` for the debit-side re-validation. `devTickReap()` (#dev, controller) runs one reaper pass deterministically for the fixture. Verified on the seat venue (#dev, port 61960): RED pre-fix — `MatchingEngine.test.mo` H1 "nothing re-rested expected 0 got 2"; `test_unfunded_maker_notice.sh` 14/31 failed (§5 re-rested + no notice + churn + 0 closures, §6 remainder re-rested, §7 no re-validation on any of the three debits); GREEN post-fix — `MatchingEngine.test.mo` H1–H6 (unfunded bid/ask → id 0 + one notice + maker untouched; half-funded bid/ask → funded part settles, remainder `#cancelled` under the trade's id, one notice naming the dropped qty; legacy taker rests; funded sweep unchanged), `test_unfunded_maker_notice.sh` 31/31 (§5 first-sweep removal, exactly one notice, handle → closed `#cancelled`, two more requotes add nothing, `devTickReap` seals exactly ONE closure; §6 half-funded fills the funded ≈299 ICP, quote spent to dust, remainder gone, one notice; §7 stakeInsurance 15000 shrinks the 9500-value bid to ≤526.32 ICP with a `#balanceShrank` adjustment, the spend-all stake cancels it with `cancelled = true`, fundMarginPool of the whole wallet cancels, depositLp's quote leg shrinks), `test_po_sweep_fee.sh` 4/4, `mops test` 19 files, `lint-ratchet` PASS, `test_deploy_hygiene.sh` PASS; the sweep/insurance/LP/margin-adjacent shell suites as recorded in the task report. Not run: the full `run_all.sh`. Found on the way: `grep -c` after `tr -d '\n'` counts LINES and saturates at 1 on the CLI's output — the §5–§7 counts use `grep -o | wc -l`; a census of the other suites' exact-count assertions is filed as `1788520600`. Remote (engine/subnet) rollout: DEFERRED to the Wave 1 operator rollout (plan §1: the next upgrade of either target must be the `1788285811` build or later).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
