#!/usr/bin/env bash
# candid.sh — the ONE way this repo extracts the backend's Candid interface.
#
# SOURCE THIS, never execute it.
#
# There were two mechanisms doing the same job and they could disagree:
# gen-did.sh WROTE the published contract with `mops generate candid`, while
# lint-ratchet.sh VERIFIED it with `moc --idl`. Two tools that merely ought to
# produce identical bytes is a bad shape for a check whose entire purpose is
# byte-equality — and `mops generate candid` additionally needs ic-mops >= 2.19,
# which is why gen-did.sh could not run on a machine whose CLI was 2.13.2 while
# the ratchet verifying its output ran fine.
#
# Now generator and verifier both call mdx_emit_candid, so "fresh" means
# "identical to what the pinned moc emits", by construction rather than by
# coincidence.

# mdx_emit_candid <output.did> [source.mo]
#   Extracts a canister interface to <output.did>. <source.mo> defaults to
#   src/backend/main.mo (the backend); gen-did.sh also passes
#   src/backend/ArchiveCanister.mo and src/bridge/main.mo for the two sibling
#   contracts it publishes beside it (task 1788510196), and lint-ratchet.sh
#   verifies all three through this same function. Needs only the pinned moc
#   (mops.toml [toolchain]) — no ic-mops version floor.
#
#   --idl makes moc emit the interface as a side effect of codegen; the wasm is
#   a throwaway. This is the same invocation lint-ratchet.sh has always used.
#   The moc flags repeat lint-ratchet.sh's MOC_FLAGS on purpose — that copy is
#   pinned by tests/test_deploy_hygiene.sh §5 and must not be "simplified" away.
mdx_emit_candid() {
  local out="$1" src="${2:-src/backend/main.mo}"
  local root moc srcs tmp
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  moc="$(mops toolchain bin moc 2>/dev/null)"
  [ -n "$moc" ] && [ -x "$moc" ] || { echo "mdx_emit_candid: moc unavailable — run 'mops install'" >&2; return 1; }
  srcs="$(mops sources 2>/dev/null)"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2086 — $srcs is a word list of --package flags
  # moc names the .did after the -o basename, not the source file.
  if ! (cd "$root" && "$moc" $srcs --default-persistent-actors --implicit-package=core --idl \
        -o "$tmp/out.wasm" "$src") >/dev/null 2>&1 || [ ! -f "$tmp/out.did" ]; then
    rm -rf "$tmp"
    echo "mdx_emit_candid: moc --idl failed to produce an interface" >&2
    return 1
  fi
  mkdir -p "$(dirname "$out")"
  mv "$tmp/out.did" "$out"
  rm -rf "$tmp"
}

# mdx_published_body <output> [published.did]
#   A committed contract (default candid/backend.did; gen-did.sh gives
#   candid/archive.did and candid/bridge.did the same header length) with
#   gen-did.sh's fixed 12-line header stripped, so it can be compared against
#   raw moc output. Kept here rather than repeated as `tail -n +13` at each
#   call site: the header length is a coupling between the writer and every
#   reader, and it should live in one place.
MDX_CANDID_HEADER_LINES=12
mdx_published_body() {
  local out="$1" published="${2:-candid/backend.did}"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  tail -n +$((MDX_CANDID_HEADER_LINES + 1)) "$root/$published" > "$out"
}
