#!/usr/bin/env bash
# check_headers.sh — post-deploy verification that the DEPLOYED asset
# canister actually serves the security headers the config promises
# (W4-20, #4.2). "security_policy: standard" is configuration; the browser
# only sees response headers, and a recipe upgrade or config change that
# drops them would otherwise be invisible.
#
# Usage: bash scripts/check_headers.sh <https://origin>
# Exit 0 = all present; non-zero lists what is missing.
set -uo pipefail
URL="${1:?usage: check_headers.sh <https://origin>}"
H=$(curl -sD- -o /dev/null --max-time 20 "$URL") || { echo "✗ fetch failed: $URL" >&2; exit 1; }
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
if [ "$fail" = "0" ]; then echo "check_headers: PASS ($URL)"; else echo "check_headers: FAIL ($URL)" >&2; fi
exit $fail
