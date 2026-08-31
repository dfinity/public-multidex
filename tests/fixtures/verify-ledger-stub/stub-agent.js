// ── Hostile-host stub for scripts/verify_ledger.mjs ───────────────────────
//
// OFFLINE. This module never opens a socket. It impersonates the gateway that
// verify_ledger.mjs talks to, and answers every QUERY the way a hostile host
// could — which is the threat model the verifier's own header claims to defend
// against ("trust nothing, recompute everything", "does not even trust this
// website").
//
// The fabricated tape is hashed with the verifier's OWN canonical() /
// hashEvent(), sliced out of the real file at runtime (lines 132-196) and
// evaluated as a module. That is deliberate: a hand-copied mirror could drift
// from the original and would then be measuring my copy rather than the
// verifier. This way the fixture is correct by construction.
//
// Scenario is chosen by MDX_STUB_SCENARIO:
//   no-cert   the host simply OMITS the certificate (certificate = [])
//   bad-cert  the host supplies a certificate that fails validation
//   good-cert the host supplies a certificate that validates and commits
//   fabricated-gap  (W2-04) TWO archives, honest tape, VALID certificates —
//             and one getLedgerGaps tuple whose toSeq is the active
//             archive's firstSeq. Pre-fix, that self-report suppressed the
//             cross-archive link check and the run exited 0; now the claim
//             demands a #gap event hash-committed in the chain, which an
//             honest tape for a fabricated gap cannot contain.
//   truncated-list  (W2-04) getArchives OMITS the sealed archive; the
//             active head still claims chainStartSeq 0. Pre-fix the walk
//             silently clipped to the served coverage and exited 0 — the
//             same attack as the gap with no tuple needed.
//
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const REAL_VERIFIER = process.env.MDX_REAL_VERIFIER
  || join(HERE, "..", "..", "..", "verify_ledger.mjs");

// ── Mirror the verifier's own canonical form, byte-for-byte ───────────────
const SRC_LINES = readFileSync(REAL_VERIFIER, "utf8").split("\n");
// Locate `const enc = …` through `const eq = …` by marker (the original
// gist hardcoded lines 132..196 against 60f75f6; W2-02's fix shifted them).
const startIdx = SRC_LINES.findIndex((l) => /^const enc = /.test(l));
const endIdx = SRC_LINES.findIndex((l) => /^const eq = /.test(l));
const BLOCK = SRC_LINES.slice(startIdx, endIdx + 1).join("\n");
if (!/function canonical/.test(BLOCK) || !/const hashEvent/.test(BLOCK)) {
  throw new Error(
    "stub: the sliced block does not contain canonical()/hashEvent() — the "
    + "line window is wrong, so the fixture would be built by the wrong code. "
    + "Refusing to proceed rather than measuring my own copy."
  );
}
const mirror = await import(
  "data:text/javascript," + encodeURIComponent(
    'import { createHash } from "node:crypto";\n'
    + BLOCK
    + "\nexport { canonical, hashEvent, eq };\n"
  )
);
const { hashEvent } = mirror;

const SCENARIO = process.env.MDX_STUB_SCENARIO || "no-cert";

// ── The fabricated tape ───────────────────────────────────────────────────
class P {
  constructor(t) { this._t = t; }
  toText() { return this._t; }
  toUint8Array() { return new Uint8Array([0xde, 0xad, 0xbe, 0xef]); }
}
const USER = new P("2vxsx-fae");
const mk = (seq, token, amount, prevHash) => ({
  seq: BigInt(seq), ts: BigInt(1_700_000_000 + seq), user: USER,
  counterparty: [], kind: { delta: { token, amount: BigInt(amount) } },
  prevHash,
});
const EVENTS = [];
EVENTS.push(mk(0, "ICP", 500_000_000, []));
EVENTS.push(mk(1, "ICP", 250_000_000, [new Uint8Array(hashEvent(EVENTS[0]))]));
EVENTS.push(mk(2, "USDT", 100_000_000, [new Uint8Array(hashEvent(EVENTS[1]))]));
const HEAD_HASH = new Uint8Array(hashEvent(EVENTS[EVENTS.length - 1]));
const ARCHIVE_ID = "ryjl3-tyaaa-aaaaa-aaaba-cai";
// W2-04 multi-archive scenarios: a sealed segment [0..1] + the active [2..].
const ARCHIVE0_ID = "rrkah-fqaaa-aaaaa-aaaaq-cai";
const SEALED_HEAD = new Uint8Array(hashEvent(EVENTS[1]));
const MULTI = SCENARIO === "fabricated-gap" || SCENARIO === "truncated-list";
// Per-canister certified heads: in the W2-04 scenarios every certificate is
// GENUINE and commits to the right per-segment head — the refusal under test
// must come from the gap-justification logic, not from a broken cert.
const CERTIFIED = { [ARCHIVE_ID]: HEAD_HASH, [ARCHIVE0_ID]: SEALED_HEAD };

const CERT_BYTES = new Uint8Array([1, 2, 3, 4]);   // opaque; validation is stubbed

export class HttpAgent {
  static async create({ host }) { return new HttpAgent(host); }
  constructor(host) { this.host = host; this.rootKey = new Uint8Array(133); }
  async fetchRootKey() { this.rootKey = new Uint8Array(133).fill(0x7f); return this.rootKey; }
}

export const Actor = {
  createActor(_idl, { canisterId }) {
    if (canisterId === ARCHIVE0_ID) {
      // The sealed segment: serves [0..1] honestly, certifies its OWN head.
      return {
        async getEventsRange(from, count) {
          const f = Number(from), n = Number(count);
          return EVENTS.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n && Number(e.seq) <= 1);
        },
        async getCertifiedHead() {
          return { headHash: [SEALED_HEAD], headSeq: [1n], chainStartSeq: [0n], certificate: [CERT_BYTES] };
        },
      };
    }
    if (canisterId === ARCHIVE_ID) {
      return {
        async getEventsRange(from, count) {
          // MDX_STUB_TAIL: the host answers [] for every seq. verify_ledger.mjs's
          // classifyEmptyPage() then returns {kind:"tail"} and the walk breaks
          // WITHOUT throwing — the "live tape / replica skew" concession.
          if (process.env.MDX_STUB_TAIL === "1") return [];
          // MDX_STUB_WITHHOLD=N: honest replica skew — every seq >= N is not yet
          // readable on this replica, but the certified head is already at 2.
          const w = process.env.MDX_STUB_WITHHOLD;
          if (w !== undefined) {
            const f0 = Number(from), n0 = Number(count);
            return EVENTS.filter((e) => Number(e.seq) >= f0 && Number(e.seq) < f0 + n0
                                     && Number(e.seq) < Number(w));
          }
          const f = Number(from), n = Number(count);
          return EVENTS.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n);
        },
        async getCertifiedHead() {
          return {
            headHash: [HEAD_HASH],
            headSeq: [BigInt(EVENTS[EVENTS.length - 1].seq)],
            chainStartSeq: [0n],
            certificate: SCENARIO === "no-cert" ? [] : [CERT_BYTES],
          };
        },
      };
    }
    // the backend
    return {
      async getArchives() {
        if (SCENARIO === "truncated-list") {
          // The lie: the sealed archive [0..1] is simply not mentioned.
          return [{ canisterId: ARCHIVE_ID, firstSeq: 2n, lastSeq: [] }];
        }
        if (MULTI) {
          return [
            { canisterId: ARCHIVE0_ID, firstSeq: 0n, lastSeq: [1n] },
            { canisterId: ARCHIVE_ID, firstSeq: 2n, lastSeq: [] },
          ];
        }
        return [{ canisterId: ARCHIVE_ID, firstSeq: 0n, lastSeq: [] }];
      },
      async getArbitrageur() { return []; },
      async getLedgerGaps() {
        // The lie: a tuple whose toSeq is the active archive's firstSeq,
        // "documenting" a shed that never happened. Coverage is continuous
        // and the tape is honest — the only purpose is to null the seed at
        // the boundary so a rewritten earlier segment would go unchecked.
        if (SCENARIO === "fabricated-gap") return [[0n, 2n, 0n]];
        return [];
      },
      async getShedBaselines() { return []; },
    };
  },
};

export const Certificate = {
  async create({ certificate, rootKey, principal, disableTimeVerification }) {
    process.stderr.write(
      `      [stub] Certificate.create reached — disableTimeVerification=${disableTimeVerification}, `
      + `rootKeyLen=${rootKey?.length}, taggedPrincipal=${!!principal?.canisterId}\n`
    );
    if (SCENARIO === "bad-cert") {
      throw new Error("stubbed BLS verification failure (forged certificate)");
    }
    // W2-04: certified_data is PER CANISTER — answer with the head of the
    // canister this certificate was created for, so per-segment validation
    // sees genuine, correctly-scoped certificates in the multi scenarios.
    const cid = principal?.canisterId?.toText ? principal.canisterId.toText() : null;
    const value = (cid && CERTIFIED[cid]) || HEAD_HASH;
    return {
      lookup_path() { return { status: "Found", value }; },
    };
  },
};
