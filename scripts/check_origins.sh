#!/usr/bin/env bash
# check_origins.sh — post-deploy verification that the DEPLOYED backend's
# anti-sybil frontend_origins env var matches the frontend's pinned origin
# list (W6-09; lockstep policy from W6-03). apply_anti_sybil_settings
# warns-and-continues when its settings update fails, and a warn in a long
# deploy scroll is how sign-in stayed down on 2026-07-11 — so this gate
# reads the value BACK from the canister instead of trusting that the
# update ran.
#
# Usage:
#   check_origins.sh --env <icp-env> --identity <name> [--expect <csv>]
#   check_origins.sh --from-file <settings-show-dump> [--expect <csv>]
#
# The expected set is --expect's CSV when given (the cloud engine's origins
# live in its conf, not in main.js), else II_PINNED_ORIGINS parsed from
# src/frontend/src/main.js — the subnet's source of truth. Comparison is
# SET equality: an origin users reach the app from that the verifier does
# not pin fails Verify-with-Google closed (#FrontendOriginMismatch); an
# origin the verifier pins but the frontend never serves is drift waiting
# to hide a real mismatch. Exit 0 = lockstep; non-zero names which side is
# missing what.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV=""; IDENTITY=""; EXPECT=""; FROM_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)       ENV="${2:?--env needs a value}"; shift 2 ;;
    --identity)  IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
    --expect)    EXPECT="${2:?--expect needs a value}"; shift 2 ;;
    --from-file) FROM_FILE="${2:?--from-file needs a value}"; shift 2 ;;
    *) echo "check_origins: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$FROM_FILE" ]; then
  SETTINGS="$(cat "$FROM_FILE")" || { echo "✗ check_origins: cannot read $FROM_FILE" >&2; exit 1; }
else
  if [ -z "$ENV" ] || [ -z "$IDENTITY" ]; then
    echo "usage: check_origins.sh --env <env> --identity <name> [--expect <csv>]" >&2
    echo "       check_origins.sh --from-file <settings-show-dump> [--expect <csv>]" >&2
    exit 2
  fi
  # --identity is mandatory by construction: the CLI's default identity is
  # machine-global mutable state that other workstreams move mid-run.
  if ! SETTINGS="$(icp canister settings show backend -e "$ENV" --identity "$IDENTITY" 2>&1)"; then
    echo "✗ check_origins: settings show failed (env=$ENV, identity=$IDENTITY):" >&2
    printf '%s\n' "$SETTINGS" | head -5 | sed 's/^/    /' >&2
    exit 1
  fi
fi

LIVE_CSV="$(printf '%s\n' "$SETTINGS" | sed -n 's/^[[:space:]]*frontend_origins:[[:space:]]*//p' | head -1 | tr -d '[:space:]')"
if [ -z "$LIVE_CSV" ]; then
  echo "✗ check_origins: no frontend_origins in settings output — either the env var is unset" >&2
  echo "  (Verify-with-Google fails closed everywhere) or the settings-show format changed" >&2
  echo "  (then fix THIS parser; a parse miss must never read as a pass)." >&2
  exit 1
fi

if [ -n "$EXPECT" ]; then
  EXPECTED="$(printf '%s' "$EXPECT" | tr ',' '\n' | sed '/^$/d')"
  SRC_LABEL="the recorded conf origins (--expect)"
else
  MAIN_JS="$SCRIPT_DIR/../src/frontend/src/main.js"
  EXPECTED="$(sed -n '/II_PINNED_ORIGINS = \[/,/\];/p' "$MAIN_JS" 2>/dev/null | grep -o '"https://[^"]*"' | tr -d '"')"
  SRC_LABEL="II_PINNED_ORIGINS (src/frontend/src/main.js)"
fi
if [ -z "$EXPECTED" ]; then
  echo "✗ check_origins: the expected origin set is EMPTY ($SRC_LABEL) — refusing to vouch for anything" >&2
  exit 1
fi

LIVE="$(printf '%s' "$LIVE_CSV" | tr ',' '\n' | sed '/^$/d')"
MISSING="$(comm -23 <(printf '%s\n' "$EXPECTED" | sort -u) <(printf '%s\n' "$LIVE" | sort -u))"
EXTRA="$(comm -13 <(printf '%s\n' "$EXPECTED" | sort -u) <(printf '%s\n' "$LIVE" | sort -u))"

fail=0
if [ -n "$MISSING" ]; then
  echo "✗ deployed frontend_origins is MISSING (users arriving there fail closed with #FrontendOriginMismatch):" >&2
  printf '%s\n' "$MISSING" | sed 's/^/    /' >&2
  fail=1
fi
if [ -n "$EXTRA" ]; then
  echo "✗ deployed frontend_origins lists origins $SRC_LABEL does not (drift — realign or de-pin deliberately):" >&2
  printf '%s\n' "$EXTRA" | sed 's/^/    /' >&2
  fail=1
fi
if [ "$fail" = "0" ]; then
  N="$(printf '%s\n' "$LIVE" | grep -c . || true)"
  echo "check_origins: PASS — deployed frontend_origins == $SRC_LABEL ($N origins)"
fi
exit $fail
