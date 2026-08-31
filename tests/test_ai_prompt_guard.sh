#!/bin/bash
# aiComplete prompt guard — GHSA-c6g7: the byte-named ceiling is measured in
# UTF-8 BYTES, not `Text.size` chars.
#
# AI_MAX_PROMPT_BYTES (32 KiB) bounds the caller-supplied prompt because
# outcall pricing is dominated by REQUEST BYTES. `Text.size` counts Unicode
# scalars, and UTF-8 spends 1-4 bytes per scalar, so the original char-counted
# guard admitted up to 4x the named byte ceiling — a multibyte prompt of
# ~16 K chars (~48 KB) sailed through a "32 KiB" gate.
#
# AI_MAX_BODY_BYTES (2x + 4 KiB) bounds the SERIALIZED request body, because
# mo:json escaping expands the prompt past the raw cap: '"' '\' and whitespace
# controls double (2x), other control chars become \uXXXX (6x) — so a
# cap-compliant prompt of control bytes serialized to ~6x the named ceiling
# and the cycle-cost bound the raw guard exists for did not actually hold.
#
# What this pins:
#   §1 an over-the-cap ASCII prompt is rejected (the cap exists at all)
#   §2 a multibyte prompt whose CHAR count is far under the cap but whose
#      BYTE count exceeds it is rejected — the byte-measurement pin: on the
#      char-counted guard this call went on toward the provider outcall
#   §3 a prompt of JSON-escaping-hostile bytes (control chars, 6x) whose RAW
#      size is under the prompt cap but whose serialized body exceeds
#      AI_MAX_BODY_BYTES is rejected — the serialized-body pin: on the
#      raw-only guard this call went on toward the provider outcall
#   §4 a legitimate plain-text prompt just under the raw cap PASSES both size
#      guards (the serialized ceiling admits every legitimate cap-compliant
#      prompt) — it then dies at the dummy-key outcall, which is the proof
#      it got past the size refusals
#
# The size guards fire BEFORE any outcall, so the dummy key this test may
# inject is never spent by §1-§3; §4 deliberately reaches the outcall and is
# therefore SKIPPED unless the key is this test's own dummy. Exchange state
# is untouched; AI key config is touched ONLY when the assistant is
# unconfigured (dummy key set, restored to "" at the end).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_ai_prompt_guard ──"

# aiComplete short-circuits with "not configured" before the size guard when
# no provider key is set, so ensure one exists. A dummy key is safe: both
# sections below are rejected by the guard before any outcall can spend it.
CONFIGURED=$(call aiConfigured '()' --query)
DUMMY_SET=0
if ! echo "$CONFIGURED" | grep -q "true"; then
  call setGoogleApiKey '("test-dummy-ghsa-c6g7")' > /dev/null
  DUMMY_SET=1
fi

# Caller: alice — a local controller (deploy identity), so the registration
# gate and rate limiter are bypassed and ONLY the size guard is in play.
# (requireAuth rejects anonymous, so the anonymous controller cannot be used.)

# ── §1 the cap exists: 33,000 ASCII chars = 33,000 bytes > 32,768 ──
python3 -c "
import sys
sys.stdout.buffer.write(b'(\"' + b'a' * 33000 + b'\")')" > /tmp/aiguard_ascii.did
R=$(echo y | icp canister call --args-file /tmp/aiguard_ascii.did backend aiComplete --identity alice 2>&1)
assert_contains "§1 over-cap ASCII prompt rejected" "$R" "Prompt too long"

# ── §2 bytes, not chars: 16,000 x '€' (U+20AC, 3 UTF-8 bytes) ──
# 16,000 chars is HALF the 32,768 ceiling — a char-counted guard passes it —
# but 48,000 bytes is 1.5x the byte ceiling and must be refused.
python3 -c "
import sys
sys.stdout.buffer.write(('(\"' + '€' * 16000 + '\")').encode('utf-8'))" > /tmp/aiguard_mb.did
R=$(echo y | icp canister call --args-file /tmp/aiguard_mb.did backend aiComplete --identity alice 2>&1)
assert_contains "§2 multibyte prompt over the BYTE cap rejected (char count would pass)" "$R" "Prompt too long"
assert_not_contains "§2 ...and never proceeds toward the provider outcall" "$R" "outcall"

# ── §3 the serialized body is bounded: 16,000 x 0x01 (candid \01 escape) ──
# Raw size 16,000 bytes — HALF the 32,768 raw ceiling, so the prompt guard
# passes it — but each 0x01 JSON-escapes to \u0001 (6 bytes): the serialized
# body is ~96,000 bytes, 1.4x the 69,632 serialized ceiling, and must be
# refused BEFORE the outcall (on the raw-only guard this call reached the
# provider and the canister paid for ~96 KB of request bytes).
python3 -c "
import sys
sys.stdout.buffer.write(b'(\"' + b'\\\\01' * 16000 + b'\")')" > /tmp/aiguard_ctrl.did
R=$(echo y | icp canister call --args-file /tmp/aiguard_ctrl.did backend aiComplete --identity alice 2>&1)
assert_contains "§3 under-raw-cap control-char prompt refused once serialized" "$R" "too large once serialized"
assert_not_contains "§3 ...and never proceeds toward the provider outcall" "$R" "outcall"
assert_not_contains "§3 ...and never reaches the provider (no http status)" "$R" "http"

# ── §4 the serialized ceiling admits legitimate use: 32,000 plain ASCII ──
# Raw 32,000 bytes is just under the 32,768 raw cap; plain text escapes 1x,
# so the body is ~33 KB — well under the 69,632 serialized ceiling. The call
# must get PAST both size refusals; it then fails at the outcall itself
# (dummy key), which is exactly the proof we want. Run only when the key is
# our own dummy — never spend a real key.
if [ "$DUMMY_SET" = "1" ]; then
  python3 -c "
import sys
sys.stdout.buffer.write(b'(\"' + b'a' * 32000 + b'\")')" > /tmp/aiguard_legit.did
  R=$(echo y | icp canister call --args-file /tmp/aiguard_legit.did backend aiComplete --identity alice 2>&1)
  assert_not_contains "§4 legitimate near-cap prompt passes the raw guard" "$R" "Prompt too long"
  assert_not_contains "§4 legitimate near-cap prompt passes the serialized guard" "$R" "too large once serialized"
else
  echo "  (skip) §4: a real AI key is configured — not spending it on a probe"
fi

# Restore: only if this test injected the dummy key.
if [ "$DUMMY_SET" = "1" ]; then
  call setGoogleApiKey '("")' > /dev/null
  assert_contains "cleanup: assistant back to unconfigured" "$(call aiConfigured '()' --query)" "false"
fi

finish_test "ai_prompt_guard"
