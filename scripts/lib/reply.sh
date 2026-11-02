#!/usr/bin/env bash
# scripts/lib/reply.sh — the ONE copy of the Candid reply oracles the seeding
# and deploy scripts gate their money-moving calls on.
#
# SOURCE THIS, never execute it.
#
# WHY THIS FILE EXISTS
# `icp canister call` exits 0 whenever the method RETURNS — a Candid refusal,
# `variant { err = "..." }`, is a successful call as far as the CLI is
# concerned — so only the reply's SHAPE can gate a call that moves money or
# flips a lifecycle switch. Three scripts grew their own copy of the same
# predicates (seed.sh's seed_ok, play_start.sh's reply_ok, deploy.sh's
# mdx_call_ok / mdx_call_nat — tasks 1788501249, 1788502351, W5-22, #55), and
# drift between copies was the hazard: a regex fixed in one place stayed
# broken in the other two. Task 1788503030 factored them here. Hygiene §3d
# pins that seed.sh, play_start.sh and deploy.sh source this file and carry
# no private copy of the regexes — gate or extractor; §6af drives mdx_reply_ok
# (the named AND hash-spelled cases), mdx_reply_nat_value and mdx_vault_nat,
# sliced out of THIS file — their values AND the status contract below.
#
# PURE predicates only: no icp call, no identity, no die/exit and no output
# vocabulary — those stay per script (seed.sh signs as alice and aborts
# through its seed_fail; play_start.sh signs as anonymous and dies through its
# own; deploy.sh warns and counts). Each takes the CAPTURED reply text as $1
# and answers by exit status. The three EXTRACTORS answer on stdout instead —
# and ONLY on stdout (THE EXTRACTOR STATUS CONTRACT, below):
#   mdx_one_line         the reply as ONE whitespace-normalized, capped line;
#   mdx_vault_nat        the N of the FIRST `<field> = N` in a record reply;
#   mdx_reply_nat_value  the N of the LAST bare `(N : nat)` — LAST for the
#                        reason mdx_reply_unit gives: icp can echo its
#                        argument prompt BEFORE the reply, so the reply is the
#                        TAIL of the output (task 1793496257).
# The (N : nat) regex lives in mdx_reply_nat_value and NOWHERE else: the
# predicate mdx_reply_nat is defined as that extractor's non-emptiness, so the
# gate a script passes and the value it then reads can never drift apart.
#
# THE EXTRACTOR STATUS CONTRACT (task 1793502104 — decision A)
# An extractor's exit status is 0 on EVERY input: a bare `v=$(…)` capture of
# mdx_reply_nat_value over the raw reply is safe under `set -euo pipefail`,
# and the caller's test on v (`-z`, `case … ''|0)`, `= 0`, or the predicate
# mdx_reply_nat) IS the status. The trailing `|| true` on mdx_vault_nat and mdx_reply_nat_value
# is that contract, not a tidy-up. Why it is needed: both end in a grep that
# MISSES on every reply without the shape, a function's status is its last
# pipeline's, and while bash 3.2 does not enforce `set -e` INSIDE a function
# called in a $(…) (hygiene §6ap's premise), it DOES enforce it on the
# assignment at TOP level — so under pipefail each answered EMPTY WITH STATUS
# 1 and a `set -e` caller's bare capture died at exactly the reply its -z arm
# exists to survive. Measured live by task 1793498812 (2026-11-01):
# deploy.sh's arb_bal capture of mdx_reply_nat_value over the raw
# getTestBalance reply aborted the script silently (exit 1, nothing printed)
# on a trap, a miss and a hash-spelled variant — §6ao's bad / miss / hashed
# moods — and landed with a site-local `|| true`. Why fix the lib (A) rather
# than teach §6ap that a capture of a pipeline-ended function needs `|| true`
# at every site (B):
# every caller already judges the VALUE (seed.sh's bulk_fund and vault
# reads, play_start.sh's vault reads, deploy.sh's insurance and arb reads —
# the predicates carry the status), so a non-zero extractor status was
# information nobody read and a trap every present and future `set -e`
# caller had to remember; B would have documented it at N sites instead of
# removing it once. §6af DRIVES the contract on the sliced bodies: the
# status on an empty answer is 0 under `set -o pipefail`, the shape
# `bash -c 'set -euo pipefail; X="$(fn "")"; echo REACHED'` REACHES, and a
# negative control with the `|| true` stripped must abort; §3d pins the
# `|| true` statically. A NEW extractor whose last stage can fail ends in
# `|| true` too (mdx_one_line's `tr | cut` has no failing stage).
#
# THE HASHED SPELLING
# icp 1.2.0 decodes replies by name from the canister's candid:service
# metadata (or from a `--candid <did>` file); when neither names the method
# it prints "WARN could not fetch candid type, serializing arguments with
# inferred types." and spells a variant tag by its Candid field hash —
# idl_hash(name) = fold h*223+c over the bytes: `ok` = 24_860, `err` =
# 5_048_165 (Rust-cased `Err` would be 3_456_837, `Ok` 17_724; this backend
# emits neither). On 2026-09-04 a name-only matcher read a SUCCESSFUL
# `(variant { 24_860 })` as a refusal and aborted a half-seeded venue (task
# 1788507289), so mdx_reply_ok accepts ok/24_860 and NOTHING else — every err
# spelling, a trap's reject text, a CLI error and the unit `()` all refuse.
# Deliberately NO retry on the WARN anywhere: by the time icp prints it the
# update has executed, and seed updates are not idempotent (a second
# createAmmPool answers "already exists", a second seedAmmPool deposits twice).

# mdx_reply_ok <reply> — true iff the reply is the Result success shape,
# `variant { ok }` / `variant { ok = ... }`, named or hash-spelled (the
# normalization tests/_lib.sh's mdx_ok uses, plus the hash).
mdx_reply_ok() {
  printf '%s\n' "$1" | tr -s '[:space:]' ' ' | grep -cE 'variant \{ (ok|24_860)( \}| =)' >/dev/null
}
# mdx_reply_unit <reply> — true iff the reply ENDS in the unit `()`. An
# argument-less call (`resetExchange` with no `'()'`) makes icp echo its
# "Sending the following argument: () ... [y/N]" prompt before the reply, so
# the reply is the TAIL of the output, not the whole of it. A trap — e.g.
# "Caller is not a canister controller" — carries no `()` and refuses.
mdx_reply_unit() {
  case "$(printf '%s' "$1" | tr -d '[:space:]')" in
    *"()") return 0 ;;
    *)     return 1 ;;
  esac
}
# mdx_reply_nat <reply> — true iff the reply is a bare `(N : nat)`: what an
# `async Nat` method (seedInsuranceFund, bulkSetTestBalances) answers with —
# no variant at all, so the ok-form refuses every one of its successes (#55,
# round 18). A trap ("Error: ... rejected") or a CLI failure prints no
# `(N : nat)`, so this stays a real gate, never `true`. Defined AS the
# extractor's non-emptiness: the ONE regex is mdx_reply_nat_value's, below.
mdx_reply_nat() {
  [ -n "$(mdx_reply_nat_value "$1")" ]
}
# mdx_one_line <reply> — the reply as ONE whitespace-normalized line, capped
# at 400 characters: what a ✗ / warn line carries.
mdx_one_line() { printf '%s' "$1" | tr -s '[:space:]' ' ' | cut -c1-400; }
# mdx_vault_nat <one-line reply> <field> — the digits of the FIRST
# `<field> = N` in a whitespace-normalized record reply (underscore-grouped on
# the wire; stripped here). Empty when the field is absent — with exit 0:
# the grep misses there, and the `|| true` is THE EXTRACTOR STATUS CONTRACT
# (header). The callers' `case "$lp" in ''|0)` arms are the gate.
mdx_vault_nat() {
  printf '%s' "$1" | grep -oE "$2 = [0-9_]+" | head -1 | sed 's/.* = //' | tr -d '_' || true
}
# mdx_reply_nat_value <reply> — the digits of the LAST bare `(N : nat)` in
# the reply, underscores stripped (icp groups them on the wire: `(1_234 :
# nat)` → 1234); EMPTY when the shape is absent — a trap, a CLI error, the
# unit `()`, any variant. The ONE (N : nat) regex, shared with mdx_reply_nat
# (task 1793496257): until then seed.sh's bulk_fund read its row count and
# deploy.sh's insurance block its pool value through private copies of it
# (seed.sh's minus the closing `\)`) — exactly the drift §3d′ exists to end.
# LAST, not first, for mdx_reply_unit's reason (the reply is the TAIL of
# icp's output); both callers pass argument literals and get a single
# `(N : nat)` line, where first and last coincide. It needs no gate before
# it and no `|| true` at the call site: it answers by stdout ONLY — exit 0 on
# every input, the trailing `|| true` is THE EXTRACTOR STATUS CONTRACT
# (header; task 1793502104) — so a bare `v=$(…)` capture of it is safe under
# `set -euo pipefail`, and mdx_reply_nat or the caller's own test on v is the
# gate (an EMPTY v is the miss).
mdx_reply_nat_value() {
  printf '%s' "$1" | grep -oE '\([[:space:]]*[0-9][0-9_]*[[:space:]]*:[[:space:]]*nat[[:space:]]*\)' | tail -1 | grep -oE '[0-9][0-9_]*' | tr -d '_' || true
}
