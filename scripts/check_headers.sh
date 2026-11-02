#!/usr/bin/env bash
# check_headers.sh — post-deploy verification that the DEPLOYED frontend
# canister actually serves the security headers the config promises
# (W4-20, #4.2). src/frontend/public/_headers (the static-site recipe's
# header file; before task 1793503326 the legacy asset canister's
# `security_policy: "standard"`) is configuration; the browser only sees
# response headers, and a recipe upgrade or config change that drops them
# would otherwise be invisible.
#
# Redirects are FOLLOWED (#55, round 18): an origin that 301/302s to its
# canonical host (apex → www, a raw canister origin → the custom domain)
# used to read as a false red, because the redirect response carries none
# of the headers. Only the FINAL response's header block is judged — a
# header on an intermediate hop vouches for nothing the browser renders.
#
# Usage: bash scripts/check_headers.sh <https://origin>
# Exit 0 = all present; non-zero lists what is missing.
set -uo pipefail
URL="${1:?usage: check_headers.sh <https://origin>}"
RAW=$(curl -s -L --max-redirs 5 -D- -o /dev/null --max-time 20 "$URL") || { echo "✗ fetch failed: $URL" >&2; exit 1; }
# -D- under -L dumps one header block per hop, blank-line separated: keep
# the LAST block (CRLF stripped first — a bare CR is not a blank line to awk).
H=$(printf '%s\n' "$RAW" | tr -d '\r' | awk 'BEGIN{RS=""} {blk=$0} END{printf "%s", blk}')
HOPS=$(printf '%s\n' "$RAW" | grep -ciE '^HTTP/[0-9.]+ +3[0-9][0-9]' || true)
[ "${HOPS:-0}" -eq 0 ] || echo "↪ followed $HOPS redirect(s); judging the final response"
fail=0
need() { # need <label> <grep-E pattern>
  if printf '%s' "$H" | grep -qiE "$2"; then echo "✓ $1"
  else echo "✗ MISSING: $1 (expected header matching: $2)" >&2; fail=1; fi
}
need "Content-Security-Policy present"        "^content-security-policy:"
need "CSP: script-src 'self'"                 "content-security-policy:.*script-src 'self'"
need "CSP: object-src 'none'"                 "content-security-policy:.*object-src 'none'"
need "CSP: frame-ancestors 'none'"            "content-security-policy:.*frame-ancestors 'none'"
need "Strict-Transport-Security"              "^strict-transport-security:.*max-age="
need "X-Content-Type-Options: nosniff"        "^x-content-type-options:.*nosniff"
need "X-Frame-Options: DENY"                  "^x-frame-options:.*deny"
need "Referrer-Policy"                        "^referrer-policy:"
# Permissions-Policy (task 1793507771): the page's own Copy buttons depend on
# clipboard-write=(self) — the legacy preset's empty allowlist denied the async
# Clipboard API to the document itself (Chrome: NotAllowedError "blocked because
# of a permissions policy"), and a rollout that re-pasted it, or a recipe/plugin
# that dropped or rewrote the header, would otherwise pass this gate with every
# Copy button dead. clipboard-read stays denied: the app never reads the clipboard.
need "Permissions-Policy: clipboard-write=(self)" "^permissions-policy:.*clipboard-write=\(self\)"
need "Permissions-Policy: clipboard-read=()"      "^permissions-policy:.*clipboard-read=\(\)"
if [ "$fail" = "0" ]; then echo "check_headers: PASS ($URL)"; else echo "check_headers: FAIL ($URL)" >&2; fi
exit $fail
