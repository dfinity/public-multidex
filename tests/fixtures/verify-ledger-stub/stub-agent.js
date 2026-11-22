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
//   wrong-head  (#51 follow-up, 1788465046) the certificate PARSES and
//             VALIDATES — Certificate.create returns normally — but its
//             certified_data is ANOTHER canister's head (the sealed
//             segment's SEALED_HEAD, replayed against the active archive):
//             lookup_path answers { status: "Found", value: <wrong head> }.
//             bad-cert throws before lookup_path is ever reached and every
//             other scenario answers the correct head, so the verifier's
//             `eq(res.value, head)` conjunct was exercised only where it was
//             true — delete it and the gate stayed green. This scenario is
//             what makes that conjunct load-bearing at BOTH sites: the
//             per-segment validateArchiveCert (--full) and the active-head
//             check after the walk (--last on this single-archive tape
//             visits no sealed segment, so only that site can fire).
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
//   consistent-liar  (#55.1) truncated-list's honest-looking sibling: the
//             sealed archive is omitted AND the active head claims
//             chainStartSeq = its own firstSeq (2) — which is exactly what a
//             REAL second segment's per-canister anchor holds
//             (ArchiveCanister.mo: set on the first event stored in THAT
//             canister), so nothing the host answers is inconsistent with
//             itself. Certificates genuine. Pre-fix the verifier defaulted
//             its origin to that uncertified claim and coverage "reached the
//             origin" by construction: exit 0, "0 chain links verified".
//             Post-fix the origin defaults to 0 and [0..2) demands a
//             chain-committed #gap event the honest tape cannot contain.
//   double-shed  (#55.4) the HONEST back-to-back shed tape: sealed [0..1],
//             then a shed dropped [2..3) while the successor spawn was
//             blocked, the queue refilled, a second shed dropped [3..4), and
//             the fresh archive anchored at 4. The archive between the sheds
//             acked nothing, so it was ABANDONED (no sealed-list entry): the
//             list carries ONE jump [2..4) while the chain carries TWO
//             declarations #gap[2..3) then #gap[3..4) (the first survives the
//             second shed — the drop stops at shedTo, before it). Pre-fix
//             both verifiers matched a jump only against a single declaration
//             and read this honest tape as an "unjustified discontinuity";
//             now contiguous declarations merge and the run is accepted.
//   holed-shed  (#55.4 negative) same list jump shape [2..5), chain declares
//             [2..3) and [4..5) — a HOLE at 3. Must still refuse: merging is
//             for exactly-contiguous runs only.
//   over-shed   (#55.4 negative) list jump [2..4), chain declares [2..3) and
//             [3..5) — the merged run [2..5) is a SUPERSET of the jump. Must
//             still refuse: the merged range has to equal the jump exactly.
//   dropped-first-gap  (1788469743) the tape a THIRD shed leaves behind: a
//             later shed drops hardCap − shedTo events from the FRONT of the
//             queue, and with them the earlier sheds' own #gap declarations
//             (production L2: the first one is gone by shed 6). The backend
//             therefore declares the COALESCED outage on every shed. Here
//             the list jumps [2..5) and the chain holds a survived half
//             [3..4) plus the coalesced [2..5) — the exact match finds the
//             latter directly; the merge never combines them (contiguous
//             runs only), so nothing over-approximates. Exit 0.
//   overlap-first-gap  (1788469743) the sibling where the FIRST half
//             survived instead: chain declares [2..3) and [2..5) under the
//             jump [2..5). Exit 0 for the same reason.
//   window-liar  (#55.6) the WINDOW-mode sibling of consistent-liar: one
//             archive, firstSeq 0, honest tape [0..2], genuine certificate —
//             and the active head claims chainStartSeq = headSeq (2).
//             Pre-fix `--last N` clamped its start to that uncertified claim:
//             from = headSeq, ONE event walked, links = 0, the recomputed
//             hash equals the certified head trivially, exit 0 "✓ 0 chain
//             links verified" — the #37.1 zero-progress shape with no tail
//             concession involved. Post-fix the clamp is the archive's serve
//             bound (firstSeq 0) and the window walks the whole tape.
//   window-clip-liar  (#55.6) the liar moves the same claim into the routing
//             list: getArchives lists the single archive with firstSeq =
//             headSeq (2) and serves nothing below it. The window's start
//             clamps to that serve bound, so the walk covers one event with
//             zero links — and the clip is a coverage jump [0..2) no listed
//             predecessor bridges and no chain-declared #gap explains.
//             Refused, exactly as the full walk refuses consistent-liar.
//   genesis-only  (#55.6 control) an honest tape of exactly ONE event:
//             headSeq 0, zero links is the legitimate count. Window mode
//             must keep passing — the zero-progress rule keys on the walk
//             starting at the chain ORIGIN, never on the host's claim.
//   sealed-season  (#55 / 1788468754) a CLOSED season, `--season 1`: the
//             season table lists the sealed segment [0..1], the season's tip
//             [2..] (lastSeq null) and the successor pre-spawned before the
//             boundary (firstSeq 0, lastSeq null, NO events — the shape the
//             detach in performWorldWipe records); getArchives lists NONE of
//             them (the live table serves the new season). The SeasonRecord
//             commits chainHead = the tip's head and finalEventSeq 3. Honest
//             tape, genuine certificates: 2 links, the record anchor met.
//             getLedgerGaps answers a tuple [0..2) of the NEW season that a
//             season walk must not consult (it would null the boundary seed).
//   season-head-liar   the record's chainHead is 32 bytes the walk never
//             reaches → refused (the second anchor).
//   season-extent-liar the record says finalEventSeq 4 while the tape ends
//             at seq 2 → refused.
//   season-truncated   the season table omits the sealed segment → the
//             origin pin refuses it exactly as consistent-liar.
//   season-wiped  (1788477403) the SeasonRecord is intact (3 archives, a
//             committed chainHead, finalEventSeq 3) but getSeasonArchives(1)
//             answers [] — the shape a #dev/#play resetExchange leaves
//             (every season's segments deleted, the permanent record kept).
//             Refused as "archives deleted ... resetExchange", NOT as "no
//             segment holds any event" (that is a table present but headless).
//   season-shed  (1788474114) a CLOSED season that SHED: sealed [0..1], the
//             range [2..3) dropped by an L2 shed, the tip anchored at 3 with
//             the chain's own #gap[2..3) at seq 3 and one re-attestation
//             row at seq 4 (finalEventSeq 5). The boundary PRESERVED the
//             season's tuples: getSeasonGaps(1) = [[2..3)], and
//             getSeasonShedBaselines(1) = [[4..5)]. `--season 1 --fold`
//             must consult THOSE (never the live pair — getLedgerGaps still
//             answers the NEW season's [0..2)): the re-anchor claim is
//             proven by the chain's #gap event and the fold RESETS at seq 4,
//             so the folded ICP total is the re-attested 0.01, not the
//             sealed segment's 7.5 + 0.01. Pre-fix both were unread in
//             season mode: the fold never reset (7.51) and the CLI warned
//             "re-baselines are not preserved".
//   season-fabricated-gap  (1788474114 negative) the honest sealed-season
//             tape (continuous, tip at 2) under a PRESERVED tuple [0..2) —
//             a preserved tuple is still only a claim: the re-anchor it
//             asks for at seq 2 needs a #gap event for the empty [2..2),
//             which the honest chain cannot contain → refused.
//   fabricated-prefix  (H-18 / F10) the host serves a self-consistent FAKE
//             tape for seqs [0..1] (different amounts, correctly chained),
//             withholds seq 2 forever, and certifies the REAL head at seq 2
//             with a genuine certificate. Pre-fix the CLI's tail-skew
//             concession walked the fake prefix (1 link), stopped short of
//             the head, validated the genuine certificate and printed VALID,
//             exit 0 — over a window never compared to anything certified.
//             Post-fix: no fresh certified head ever lands inside the
//             readable window and the tape never catches up → INCONCLUSIVE
//             (exit 3), never VALID. With MDX_STUB_FRESH_HEAD=1 the fresh
//             head is the REAL hash at seq 1, which the fake tape's
//             recomputed hash cannot match → exit 1.
//   unsealed-predecessor  (H-18 / F21) getArchives lists TWO lastSeq-null
//             rows: [0..] and [2..], plus a getLedgerGaps tuple [0..2). The
//             backend can never produce that shape (getArchives appends
//             exactly one open row — the active archive). Pre-fix the CLI
//             walked the first row to the head, hit its tail at seq 2, took
//             the concession (keyed on lastSeq null, not on being LAST), then
//             nulled the seed at the second row with NO justification pushed
//             (the guard keyed on the predecessor's lastSeq) → exit 0 with
//             the active segment linked to nothing. Post-fix the list is
//             refused before the walk: a non-final open row is malformed.
//   overlapping-list  (H-18 / F21 adjacent) sealed [0..1] then active [1..]
//             — ranges not strictly ascending. Refused as malformed (pre-fix
//             it failed too, but as an "unjustified discontinuity" [2..1)).
//   two-archives  (1788472713) the HONEST rolled tape: sealed [0..1] and the
//             active [2..] on one continuous chain, no tuple, genuine
//             per-segment certificates. The window control: `--last 10`
//             must VISIT the sealed segment (its head compared and
//             certificate-checked, the link carried across the boundary —
//             2 links, 2/2 archives); pre-fix the window clipped at the
//             active's firstSeq, bridged the boundary from the predecessor's
//             last event and printed "not visited; run --full" (1 link).
//
// Environment knobs (the ACTIVE archive's tape):
//   MDX_STUB_TAIL=1        every getEventsRange answers [] (the #37.1 lie)
//   MDX_STUB_WITHHOLD=N    seqs >= N are not yet readable (honest replica
//                          skew — the certified head is already past them)
//   MDX_STUB_CATCHUP=1     with WITHHOLD: the withheld tape becomes readable
//                          once getCertifiedHead has been asked a SECOND
//                          time (the verifier's re-fetch) — the honest
//                          "catches up on retry" shape H-18 anchors to
//   MDX_STUB_FRESH_HEAD=N  from the second getCertifiedHead call on, the
//                          active archive certifies a LOWER head at seq N
//                          (the replica that serves the tape vouching for
//                          what it has) — the "fresh head inside the readable
//                          window" anchor. Its certificate commits to that
//                          head (a per-canister certified_data swap).
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
const ARCHIVE_ID = "ryjl3-tyaaa-aaaaa-aaaba-cai";
// #55.4 shed scenarios: the ACTIVE archive is a re-anchored segment holding
// the chain's own #gap declarations (one per shed) and a tail event. Its first
// event's prevHash points at a DROPPED event, which no verifier can check
// (they seed null at a claimed re-anchor) — any 32 bytes stand in for it.
const gapEv = (seq, from, to, prevHash) => ({
  seq: BigInt(seq), ts: BigInt(1_700_000_000 + seq), user: USER, counterparty: [],
  kind: { gap: { fromSeq: BigInt(from), toSeq: BigInt(to) } }, prevHash,
});
const SHED = {
  "double-shed": { first: 4, decl: [[2, 3], [3, 4]] },
  // 1788474114: the closed season that shed once — its tip anchors at 3.
  "season-shed": { first: 3, decl: [[2, 3]] },
  "holed-shed":  { first: 5, decl: [[2, 3], [4, 5]] },
  "over-shed":   { first: 4, decl: [[2, 3], [3, 5]] },
  // 1788469743: the coalesced declaration beside a surviving half.
  "dropped-first-gap": { first: 5, decl: [[3, 4], [2, 5]] },
  "overlap-first-gap": { first: 5, decl: [[2, 3], [2, 5]] },
}[SCENARIO];
let ACTIVE = EVENTS;
// #55.6: the genesis-only tape holds seq 0 alone.
if (SCENARIO === "genesis-only") ACTIVE = EVENTS.slice(0, 1);
if (SHED) {
  ACTIVE = [];
  let prev = [new Uint8Array(32).fill(0xab)];
  let seq = SHED.first;
  for (const [f, t] of SHED.decl) {
    const e = gapEv(seq, f, t, prev);
    ACTIVE.push(e); prev = [new Uint8Array(hashEvent(e))]; seq++;
  }
  ACTIVE.push(mk(seq, "ICP", 1_000_000, prev));
}
const HEAD_HASH = new Uint8Array(hashEvent(ACTIVE[ACTIVE.length - 1]));
// W2-04 multi-archive scenarios: a sealed segment [0..1] + the active [2..].
const ARCHIVE0_ID = "rrkah-fqaaa-aaaaa-aaaaq-cai";
const SEALED_HEAD = new Uint8Array(hashEvent(EVENTS[1]));
const MULTI = SCENARIO === "fabricated-gap" || SCENARIO === "truncated-list" || SCENARIO === "two-archives";
// #55.1: the active archive presents itself as a genuine SECOND segment — it
// holds only seq 2 onward and anchors its chain at its own first event.
const LIAR = SCENARIO === "consistent-liar";
// #55.6: the window liars. WINDOW_LIAR lies only in the head's chainStartSeq;
// CLIP_LIAR lies in the routing list's firstSeq (and serves nothing below it).
const WINDOW_LIAR = SCENARIO === "window-liar";
const CLIP_LIAR = SCENARIO === "window-clip-liar";
// #55 (1788468754): the closed-season scenarios. The tip is ARCHIVE_ID [2..],
// the sealed segment ARCHIVE0_ID [0..1], and SUCCESSOR_ID never held an event.
const SEASON_MODE = ["sealed-season", "season-head-liar", "season-extent-liar", "season-truncated",
                     "season-shed", "season-fabricated-gap", "season-wiped"].includes(SCENARIO);
// 1788474114: the tuples the boundary preserved for season 1 — a real shed's
// (season-shed), or a fabricated one at a continuous boundary.
const SEASON_GAPS = SCENARIO === "season-shed" ? [[2n, 3n, 0n]]
  : SCENARIO === "season-fabricated-gap" ? [[0n, 2n, 0n]] : [];
const SEASON_BASELINES = SCENARIO === "season-shed" ? [[4n, 5n]] : [];
const SUCCESSOR_ID = "r7inp-6aaaa-aaaaa-aaabq-cai";
// Per-canister certified heads: in the W2-04 scenarios every certificate is
// GENUINE and commits to the right per-segment head — the refusal under test
// must come from the gap-justification logic, not from a broken cert.
const CERTIFIED = { [ARCHIVE_ID]: HEAD_HASH, [ARCHIVE0_ID]: SEALED_HEAD };
// 1788465046: the replayed certificate — parseable, "valid", committing to a
// head that is not this canister's. SEALED_HEAD is hashEvent(EVENTS[1]) and
// HEAD_HASH is hashEvent(EVENTS[2]); they differ by construction.
const WRONG_HEAD = SCENARIO === "wrong-head";
// H-18 (F10): the fabricated prefix — a self-consistent fake tape for [0..1];
// seq 2 is withheld for good while the certified head is the REAL seq 2.
const FAKE_PREFIX = SCENARIO === "fabricated-prefix";
const FAKE = [];
FAKE.push(mk(0, "ICP", 1, []));
FAKE.push(mk(1, "ICP", 2, [new Uint8Array(hashEvent(FAKE[0]))]));
// H-18 (F21): the malformed routing lists.
const UNSEALED_PRED = SCENARIO === "unsealed-predecessor";
const OVERLAP_LIST = SCENARIO === "overlapping-list";
// H-18 (F10) knobs — see the header.
const CATCHUP = process.env.MDX_STUB_CATCHUP === "1";
const FRESH_HEAD = process.env.MDX_STUB_FRESH_HEAD !== undefined ? Number(process.env.MDX_STUB_FRESH_HEAD) : null;
let activeHeadCalls = 0;

const CERT_BYTES = new Uint8Array([1, 2, 3, 4]);   // opaque; validation is stubbed

export class HttpAgent {
  static async create({ host }) { return new HttpAgent(host); }
  constructor(host) { this.host = host; this.rootKey = new Uint8Array(133); }
  async fetchRootKey() { this.rootKey = new Uint8Array(133).fill(0x7f); return this.rootKey; }
}

export const Actor = {
  createActor(_idl, { canisterId }) {
    if (canisterId === SUCCESSOR_ID) {
      // Pre-spawned before the boundary, promoted never: an empty canister.
      return {
        async getEventsRange() { return []; },
        async getCertifiedHead() { return { headHash: [], headSeq: [], chainStartSeq: [], certificate: [] }; },
      };
    }
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
          const f = Number(from), n = Number(count);
          // H-18 (F10): the fabricated prefix — [0..1] fake, seq 2 never readable.
          if (FAKE_PREFIX) return FAKE.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n);
          // MDX_STUB_TAIL: the host answers [] for every seq. verify_ledger.mjs's
          // classifyEmptyPage() then returns {kind:"tail"} and the walk breaks
          // WITHOUT throwing — the "live tape / replica skew" concession.
          if (process.env.MDX_STUB_TAIL === "1") return [];
          // MDX_STUB_WITHHOLD=N: honest replica skew — every seq >= N is not yet
          // readable on this replica, but the certified head is already at 2.
          // MDX_STUB_CATCHUP: the skew resolves once the verifier re-fetches the
          // head (H-18) — the honest replica caught up in the meantime.
          const w = process.env.MDX_STUB_WITHHOLD;
          if (w !== undefined && !(CATCHUP && activeHeadCalls >= 2)) {
            return ACTIVE.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n
                                     && Number(e.seq) < Number(w));
          }
          return ACTIVE.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n
                                   && (!(LIAR || CLIP_LIAR || UNSEALED_PRED) || Number(e.seq) >= 2));
        },
        async getCertifiedHead() {
          activeHeadCalls++;
          // H-18 (F10): from the re-fetch on, a LOWER fresh head — the replica
          // serving the (withheld / fake) tape certifies what it actually has.
          // The REAL hash at that seq, so a fake prefix cannot match it.
          if (FRESH_HEAD !== null && activeHeadCalls >= 2) {
            const at = ACTIVE.find((e) => Number(e.seq) === FRESH_HEAD);
            const h = new Uint8Array(hashEvent(at));
            CERTIFIED[ARCHIVE_ID] = h;   // its certificate commits to THIS head
            return { headHash: [h], headSeq: [BigInt(FRESH_HEAD)], chainStartSeq: [0n], certificate: [CERT_BYTES] };
          }
          return {
            headHash: [HEAD_HASH],
            headSeq: [BigInt(ACTIVE[ACTIVE.length - 1].seq)],
            // The liar's anchor is its own first stored seq — the shape every
            // honest non-first segment reports, which is why it is no tell.
            // (A re-anchored segment after a shed honestly reports the same.)
            // #55.6: the window liar's claim is headSeq itself — "verification
            // starts here", i.e. nowhere.
            chainStartSeq: [SHED ? BigInt(SHED.first) : (LIAR || WINDOW_LIAR) ? 2n : 0n],
            certificate: SCENARIO === "no-cert" ? [] : [CERT_BYTES],
          };
        },
      };
    }
    // the backend
    return {
      async getArchives() {
        // #55 (1788468754): the live table serves the NEW season only; the
        // closed season's segments are not on it (season mode never asks).
        if (SEASON_MODE) return [];
        // H-18 (F21): the malformed lists — a non-final OPEN row, and ranges
        // that are not strictly ascending. Neither is a shape the backend's
        // getArchives can emit; both must be refused before any walk.
        if (UNSEALED_PRED) {
          return [
            { canisterId: ARCHIVE0_ID, firstSeq: 0n, lastSeq: [] },
            { canisterId: ARCHIVE_ID, firstSeq: 2n, lastSeq: [] },
          ];
        }
        if (OVERLAP_LIST) {
          return [
            { canisterId: ARCHIVE0_ID, firstSeq: 0n, lastSeq: [1n] },
            { canisterId: ARCHIVE_ID, firstSeq: 1n, lastSeq: [] },
          ];
        }
        if (SCENARIO === "truncated-list" || LIAR || CLIP_LIAR) {
          // The lie: the sealed archive [0..1] is simply not mentioned.
          // (window-clip-liar: there never was one — the single archive just
          // claims to begin at the head.)
          return [{ canisterId: ARCHIVE_ID, firstSeq: 2n, lastSeq: [] }];
        }
        if (SHED) {
          // ONE jump [2..first): the archive between the sheds acked nothing
          // and was abandoned, so it never entered the sealed list.
          return [
            { canisterId: ARCHIVE0_ID, firstSeq: 0n, lastSeq: [1n] },
            { canisterId: ARCHIVE_ID, firstSeq: BigInt(SHED.first), lastSeq: [] },
          ];
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
        // #55 (1788468754): the NEW season's tuple — a season walk that
        // consulted it would null the seed at the sealed boundary (seq 2).
        if (SEASON_MODE) return [[0n, 2n, 0n]];
        // The lie: a tuple whose toSeq is the active archive's firstSeq,
        // "documenting" a shed that never happened. Coverage is continuous
        // and the tape is honest — the only purpose is to null the seed at
        // the boundary so a rewritten earlier segment would go unchecked.
        if (SCENARIO === "fabricated-gap") return [[0n, 2n, 0n]];
        // H-18 (F21): the tuple that nulls the seed at the second open row.
        if (UNSEALED_PRED) return [[0n, 2n, 0n]];
        // The shed path COALESCES contiguous outages into one tuple (main.mo
        // recordGap) — the ops surface says [2..first), never the two halves.
        if (SHED) return [[2n, BigInt(SHED.first), 0n]];
        return [];
      },
      async getShedBaselines() { return []; },
      // 1788474114: the closed season's PRESERVED tuples (season 1 only).
      async getSeasonGaps(season) { return SEASON_MODE && Number(season) === 1 ? SEASON_GAPS : []; },
      async getSeasonShedBaselines(season) { return SEASON_MODE && Number(season) === 1 ? SEASON_BASELINES : []; },
      // #55 (1788468754): the closed season's own table, and the boundary
      // record. Both answered only in the season scenarios.
      async getSeasonArchives(season) {
        if (!SEASON_MODE || Number(season) !== 1) return [];
        // 1788477403: the wiped season — the record below stays intact.
        if (SCENARIO === "season-wiped") return [];
        const rows = [
          { canisterId: ARCHIVE0_ID, firstSeq: 0n, lastSeq: [1n] },
          // season-shed: the tip re-anchored at 3 after the [2..3) shed.
          { canisterId: ARCHIVE_ID, firstSeq: SHED ? BigInt(SHED.first) : 2n, lastSeq: [] },
          { canisterId: SUCCESSOR_ID, firstSeq: 0n, lastSeq: [] },
        ];
        return SCENARIO === "season-truncated" ? rows.slice(1) : rows;
      },
      async getSeasonRecords() {
        if (!SEASON_MODE) return [];
        return [{
          season: 1n, endedNs: 0n, totalRanked: 0n, finalTop: [],
          // The tape's end + 1 (3 on the plain tape, 5 after the season-shed).
          finalEventSeq: SCENARIO === "season-extent-liar" ? 4n : BigInt(Number(ACTIVE[ACTIVE.length - 1].seq) + 1),
          archives: [new P(ARCHIVE0_ID), new P(ARCHIVE_ID), new P(SUCCESSOR_ID)],
          chainHead: [SCENARIO === "season-head-liar" ? new Uint8Array(32).fill(0xcd) : HEAD_HASH],
        }];
      },
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
    // 1788465046: wrong-head answers the OTHER canister's head — a replay.
    const value = WRONG_HEAD ? SEALED_HEAD : ((cid && CERTIFIED[cid]) || HEAD_HASH);
    return {
      lookup_path() { return { status: "Found", value }; },
    };
  },
};
