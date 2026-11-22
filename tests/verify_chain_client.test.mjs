// verify_chain_client — the PAGE verifier (src/frontend/src/ledger.js
// verifyChainClient) executed OFFLINE against the same hostile-host shapes
// tests/test_verify_ledger_gate.sh pins for the CLI twin.
//
// Why a second harness: the gate exercises scripts/verify_ledger.mjs through
// the vendored stub SDK, but the browser twin was covered only by SOURCE pins
// (frontend_security.test.mjs) — its behaviour on a multi-archive tape was
// never run anywhere. verifyChainClient takes its actors by dependency
// injection and ledger.js is side-effect-free at module top level (see
// eventchain_equivalence.test.mjs), so it runs in node as-is: WebCrypto is
// global, and a stubbed `window.location.hostname = "localhost"` makes the
// locality predicate answer "local replica" — under which an uncertified
// sealed segment is tolerated (a development replica's certificates are
// synthetic), which is exactly what lets the structural logic be tested
// without any certificate machinery. Certificates are NOT what these
// scenarios probe; test_verify_ledger_gate.sh covers that axis.
//
// Scenarios (the #55.4 set plus the W2-04 fabricated-tuple control):
//   honest        one archive [0..2]                              → verifies
//   double-shed   sealed [0..1]; two back-to-back sheds under a blocked
//                 spawn — [2..3) then [3..4) — and the fresh archive anchors
//                 at 4. The archive between the sheds acked nothing and was
//                 ABANDONED (no sealed-list entry), so getArchives carries
//                 ONE jump [2..4) while the chain carries TWO contiguous
//                 #gap declarations                              → verifies
//   holed-shed    jump [2..5), declarations [2..3),[4..5)         → refused
//   over-shed     jump [2..4), declarations [2..3),[3..5)         → refused
//   dropped-first-gap (1788469743) jump [2..5), chain declares a surviving
//                 later half [3..4) plus the COALESCED [2..5) the backend
//                 now emits on every shed (a later shed drops the earlier
//                 declarations off the queue front)            → verifies
//   overlap-first-gap (1788469743) jump [2..5), [2..3) + [2..5) → verifies
//   fabricated    continuous coverage [0..1],[2..], one getLedgerGaps
//                 tuple [0..2) and NO #gap event on the chain     → refused
// Plus mergeContiguousGaps itself (sort, contiguous merge, holes and
// overlaps kept apart) and a drift lock holding its body byte-identical in
// both verifiers — the CLI cannot be imported (it talks to a host at top
// level), so its copy is compared as SOURCE.
//
// #55.6 — WINDOW mode (opts.lastN), the page twin of the gate's `--last`
// scenarios: the window is planned against the routing list's serve bounds
// through planWindow, never against the head's uncertified chainStartSeq; a
// clip nothing bridges must be a chain-declared #gap run; zero links at a
// start other than the chain origin is refused.
// 1788472713 — the window is a CLIPPED FULL WALK: planWindow routes the
// request newest-backwards across the list, every archive holding tape
// inside the window is visited (hash carried across each boundary, every
// visited sealed head compared and certificate-checked), coverage jumps
// INSIDE the window are justified exactly as list jumps, and only the tape
// below the window is skipped. Before: the window clipped at the active
// archive's firstSeq and reported "not visited".
//   window-liar        chainStartSeq = headSeq, firstSeq 0        → 2 links
//   window-clip-liar   firstSeq = headSeq in the list, no predecessor → refused
//   genesis-only       one event, headSeq 0                       → 0 links, ok
//   double-shed        lastN spanning the re-anchor: the sealed segment is
//                      VISITED, the inner jump chain-declared      → 3 links, 2 heads
//                      lastN inside the segment: seeded from tape → 2 links, 1 head
//   continuous         lastN spanning a bridged boundary: both visited, the
//                      link carried across                        → 2 links, 2 heads
//                      lastN 1 at the boundary: bridged by the unvisited
//                      predecessor's last event                   → 1 link
//   three archives     the middle sealed segment visited from inside it
//                      (self-seeded) or at its edge (predecessor-seeded)
//   hollow predecessor a visited sealed segment serving nothing → refused;
//                      an unvisited one that cannot bridge         → refused
//   fabricated-gap     a tuple at a contiguous boundary INSIDE the window
//                      is refused as in the full walk (empty re-anchor range)
// planWindow itself is unit-pinned and drift-locked like mergeContiguousGaps.
//
// #55 (1788468754) — SEASON mode (opts.season), the page twin of the gate's
// `--season` scenarios: the walk routes by deps.listSeasonArchives(N) (the
// closed season's own table — getArchives serves the current season only),
// skips the successor pre-spawned before the boundary (no events, empty
// head), ignores the NEW season's getLedgerGaps tuples, and must ALSO meet
// the SeasonRecord: walked head == chainHead, last seq == finalEventSeq - 1.
//   sealed season     sealed [0..1] + tip [2], empty successor    → 2 links
//   head liar         record chainHead never reached              → refused
//   extent liar       record finalEventSeq ≠ tape end + 1         → refused
//   truncated table   sealed segment omitted                      → refused
//   hidden tip        the tip answers an empty head               → refused
//   unknown season / season + lastN                               → refused
//   wiped season      EMPTY season table, record committed a head → refused
//     as "archives deleted" (1788477403: a #dev/#play resetExchange
//     wipes every season's segments, keeps the record), NOT the
//     "no segment holds any event" wording (table present, all headless)
// 1788474114 — the boundary PRESERVES the closed season's gap tuples and shed
// re-baselines (deps.getSeasonGaps(N) / deps.getSeasonShedBaselines(N)); the
// season walk consults THOSE where the live walk consults the live pair:
//   season-shed: sealed [0..1], tip anchored at 3 with #gap[2..3) + one
//     re-attestation row at 4; preserved [2..3) + baseline [4..5)
//                                → 2 links, gapCount 1, baselineCount 1,
//                                  baselineResumeSeq 5 (the page's "healed" note)
//   the same tape on a pre-1788474114 backend (no season deps)
//                                → still verifies by list-jump inference,
//                                  gapCount 0 / baselineCount 0 (nothing to
//                                  reset at — the pre-fix shape, kept honest)
//   a PRESERVED tuple [0..2) at the continuous sealed-season boundary
//                                → refused: a preserved claim is still a claim
//
// H-18 (F21, task 1788467615) — the served routing list is validated BEFORE
// the walk (validateArchiveList, byte-identical in both mirrors): getArchives
// appends exactly one open row (the active archive) after the sealed ones, so
// a non-final row with lastSeq null, ranges not strictly ascending, or an
// inverted entry is a shape the backend cannot emit. Pre-fix the page walker
// honored a two-open-rows list with a gap tuple: the first open row was
// walked to the head and compared against its own head, the second had its
// seed nulled by the tuple with NO justification pushed (the guard keyed on
// the predecessor's lastSeq), and the ACTIVE segment verified linked to
// nothing at all.
//   unsealed predecessor  [0..] open, [2..] open, tuple [0..2)  → refused
//   overlapping list      sealed [0..1], active [1..]           → refused
//   inverted entry        sealed [3..1]                         → refused
//   honest lists          one open row; sealed + open; sealed only → accepted

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

globalThis.window = { location: { hostname: "localhost" } };
const ledgerMod = await import("../src/frontend/src/ledger.js");
const { verifyChainClient, hashEvent, mergeContiguousGaps, planWindow, verifyScopeOpts, seasonOptionLabel } = ledgerMod;
// H-18: absent on the pre-fix tree — the checks below then report the miss
// instead of crashing the harness at import.
const validateArchiveList = ledgerMod.validateArchiveList || (() => { throw new Error("validateArchiveList is not exported by ledger.js"); });

let passed = 0, failed = 0;
const J = (x) => JSON.stringify(x);
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`✓ ${name}`); }
  else { failed++; console.log(`✗ ${name}`); if (detail) console.log(`    ${detail}`); }
}

// ── The tape ─────────────────────────────────────────────────────────
const USER = { toText: () => "2vxsx-fae" };
const delta = (seq, amount, prevHash) => ({
  seq: BigInt(seq), ts: BigInt(1_700_000_000 + seq), user: USER, counterparty: [],
  kind: { delta: { token: "ICP", amount: BigInt(amount) } }, prevHash,
});
const gapEv = (seq, from, to, prevHash) => ({
  seq: BigInt(seq), ts: BigInt(1_700_000_000 + seq), user: USER, counterparty: [],
  kind: { gap: { fromSeq: BigInt(from), toSeq: BigInt(to) } }, prevHash,
});
// Chain a list of (seq, kindFactory) into hashed events; `seed` is the first
// event's prevHash (empty at genesis; an opaque 32 bytes after a shed — it
// points at a DROPPED event, which no verifier can or does check).
async function chain(specs, seed) {
  const out = [];
  let prev = seed;
  for (const make of specs) {
    const e = make(prev);
    out.push(e);
    prev = [await hashEvent(e)];
  }
  return out;
}
const DROPPED = [new Uint8Array(32).fill(0xab)];

async function actorFor(events, chainStart) {
  const head = await hashEvent(events[events.length - 1]);
  return {
    async getEventsRange(from, count) {
      const f = Number(from), n = Number(count);
      return events.filter((e) => Number(e.seq) >= f && Number(e.seq) < f + n);
    },
    async getCertifiedHead() {
      return { headHash: [head], headSeq: [events[events.length - 1].seq],
               chainStartSeq: [BigInt(chainStart)], certificate: [] };
    },
  };
}
function deps(archives, actors, gaps) {
  return {
    listArchives: async () => archives,
    makeRawArchiveActor: async (cid) => actors[cid],
    rootKey: null,
    getLedgerGaps: async () => gaps,
    getShedBaselines: async () => [],
  };
}
async function run(d, opts) {
  try { return { ok: true, res: await verifyChainClient(d, opts || {}, () => {}) }; }
  catch (err) { return { ok: false, err: String(err && err.message || err) }; }
}

// Sealed segment [0..1], shared by every multi-archive scenario.
const sealed = await chain([
  (p) => delta(0, 500_000_000, p),
  (p) => delta(1, 250_000_000, p),
], []);
const A0 = "rrkah-fqaaa-aaaaa-aaaaq-cai";
const A1 = "ryjl3-tyaaa-aaaaa-aaaba-cai";

// ── honest single archive ────────────────────────────────────────────
{
  const ev = await chain([
    (p) => delta(0, 500_000_000, p), (p) => delta(1, 250_000_000, p), (p) => delta(2, 100_000_000, p),
  ], []);
  const r = await run(deps([{ canisterId: A1, firstSeq: 0n, lastSeq: [] }], { [A1]: await actorFor(ev, 0) }, []));
  check("honest single-archive tape verifies (2 links, no gaps)",
    r.ok && r.res.links === 2 && r.res.gapCount === 0, r.ok ? JSON.stringify(r.res) : r.err);
}

// ── #55.4 double-shed: ONE list jump, TWO contiguous declarations ────
async function shedScenario(first, decl) {
  const active = await chain([
    ...decl.map(([f, t], i) => (p) => gapEv(first + i, f, t, p)),   // one #gap per shed, in shed order
    (p) => delta(first + decl.length, 1_000_000, p),
  ], DROPPED);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: BigInt(first), lastSeq: [] },
  ];
  // The shed path coalesces contiguous outages: the ops tuple is [2..first).
  return run(deps(archives, { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, first) }, [[2n, BigInt(first), 0n]]));
}
{
  const r = await shedScenario(4, [[2, 3], [3, 4]]);
  check("double-shed: one list jump [2..4) justified by contiguous chain declarations [2..3),[3..4)",
    r.ok && r.res.chainGapCount === 2 && r.res.gapCount === 1 && r.res.links === 3,
    r.ok ? JSON.stringify(r.res) : r.err);
}
{
  const r = await shedScenario(5, [[2, 3], [4, 5]]);
  check("holed-shed: declarations [2..3),[4..5) never merge across the hole — jump [2..5) refused",
    !r.ok && /unjustified discontinuity/.test(r.err), r.ok ? "verified clean" : r.err);
}
{
  const r = await shedScenario(4, [[2, 3], [3, 5]]);
  check("over-shed: merged run [2..5) is a superset of the jump [2..4) — refused",
    !r.ok && /unjustified discontinuity/.test(r.err), r.ok ? "verified clean" : r.err);
}

// ── 1788469743: the coalesced declaration beside a surviving half ────
// A THIRD shed's drop passes the earlier #gap events; the backend declares
// the coalesced outage on every shed, so the survivor always spans the jump.
// The merge is contiguous-only: neither an overlapping first half nor a
// strictly-inside later half is fused into a superset (over-shed above).
{
  const r = await shedScenario(5, [[3, 4], [2, 5]]);
  check("dropped-first-gap: the coalesced [2..5) beside a surviving [3..4) justifies the jump [2..5) directly",
    r.ok && r.res.chainGapCount === 2 && r.res.gapCount === 1 && r.res.links === 3,
    r.ok ? JSON.stringify(r.res) : r.err);
}
{
  const r = await shedScenario(5, [[2, 3], [2, 5]]);
  check("overlap-first-gap: [2..3) beside the coalesced [2..5) is never merged into a superset — the jump [2..5) verifies",
    r.ok && r.res.chainGapCount === 2 && r.res.gapCount === 1 && r.res.links === 3,
    r.ok ? JSON.stringify(r.res) : r.err);
}
{
  // The window twin: a clip at the re-anchor under the same two shapes.
  const active = await chain([
    (p) => gapEv(5, 3, 4, p), (p) => gapEv(6, 2, 5, p), (p) => delta(7, 1_000_000, p),
  ], DROPPED);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 5n, lastSeq: [] },
  ];
  const r = await run(deps(archives, { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 5) }, [[2n, 5n, 0n]]), { lastN: 10 });
  check("dropped-first-gap lastN 10: the sealed segment is visited and the inner jump [2..5) is justified by the coalesced declaration (3 links, 2 heads)",
    r.ok && r.res.links === 3 && r.res.heads === 2 && /\[2\.\.5\) inside the window is a chain-declared/.test(r.res.windowNote),
    r.ok ? JSON.stringify(r.res) : r.err);
}

// ── W2-04 control: a fabricated tuple with no chain declaration ──────
{
  // Continuous coverage: the active segment genuinely links to the sealed head.
  const active = await chain([(p) => delta(2, 100_000_000, p)], [await hashEvent(sealed[1])]);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 2n, lastSeq: [] },
  ];
  const actors = { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 2) };
  const honest = await run(deps(archives, actors, []));
  check("continuous two-archive tape verifies with the link carried across the boundary",
    honest.ok && honest.res.links === 2, honest.ok ? JSON.stringify(honest.res) : honest.err);
  const lied = await run(deps(archives, actors, [[0n, 2n, 0n]]));
  check("fabricated-gap: a getLedgerGaps tuple with no #gap event on the chain is refused",
    !lied.ok && /unjustified discontinuity/.test(lied.err), lied.ok ? "verified clean (the R1 attack)" : lied.err);
  // 1788472713: the same tuple under a window that spans the boundary — the
  // sealed segment is visited, the boundary is INSIDE the window, and the
  // tuple's claimed re-anchor at a contiguous boundary is the empty range
  // [2..2) no honest chain declares: refused exactly as the full walk does.
  const liedWin = await run(deps(archives, actors, [[0n, 2n, 0n]]), { lastN: 10 });
  check("fabricated-gap lastN 10: the tuple at a boundary inside the window is refused as in the full walk",
    !liedWin.ok && /unjustified discontinuity/.test(liedWin.err) && /\[2\.\.2\)/.test(liedWin.err),
    liedWin.ok ? "verified clean: " + JSON.stringify(liedWin.res) : liedWin.err);
  // At the window's EDGE (requestedFrom == the active's firstSeq) the region
  // below is unverified by definition: the tuple is neither honored nor
  // refuted, and the contiguous predecessor's own last event still bridges
  // the link — a free check, never a suppressed one.
  const liedEdge = await run(deps(archives, actors, [[0n, 2n, 0n]]), { lastN: 1 });
  check("fabricated-gap lastN 1: at the window's edge the contiguous predecessor bridges the link regardless of the tuple (1 link)",
    liedEdge.ok && liedEdge.res.links === 1 && liedEdge.res.heads === 1, liedEdge.ok ? JSON.stringify(liedEdge.res) : liedEdge.err);
}

// ── H-18 (F21): the malformed routing lists ──────────────────────────
{
  // The unsealed predecessor: the first open row serves [0..2] and certifies
  // the head at seq 2 (so its own head compare passes), the second open row
  // starts at 2 with a FABRICATED seq 2 whose hash is the active head, and
  // a gap tuple [0..2) nulls the seed at the boundary. Pre-fix: verified,
  // 2 links, the active segment linked to nothing.
  const honest3 = await chain([
    (p) => delta(0, 500_000_000, p), (p) => delta(1, 250_000_000, p), (p) => delta(2, 100_000_000, p),
  ], []);
  const fake2 = await chain([(p) => delta(2, 7, p)], DROPPED);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [] },
    { canisterId: A1, firstSeq: 2n, lastSeq: [] },
  ];
  const r = await run(deps(archives, { [A0]: await actorFor(honest3, 0), [A1]: await actorFor(fake2, 2) }, [[0n, 2n, 0n]]));
  check("unsealed predecessor: two open rows + a gap tuple are refused as a malformed routing list (the F21 attack)",
    !r.ok && /routing list malformed/.test(r.err), r.ok ? "verified clean: " + JSON.stringify(r.res) : r.err);
  // The same list in window mode: the list is validated before any mode split.
  const w = await run(deps(archives, { [A0]: await actorFor(honest3, 0), [A1]: await actorFor(fake2, 2) }, [[0n, 2n, 0n]]), { lastN: 3 });
  check("unsealed predecessor (lastN 3): refused before the window is planned",
    !w.ok && /routing list malformed/.test(w.err), w.ok ? "verified clean: " + JSON.stringify(w.res) : w.err);
  // Not strictly ascending: sealed [0..1] then active [1..].
  const overlap = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 1n, lastSeq: [] },
  ];
  const o = await run(deps(overlap, { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(honest3.slice(1), 1) }, []));
  check("overlapping list: sealed [0..1] then active [1..] is refused as malformed (not strictly ascending)",
    !o.ok && /routing list malformed/.test(o.err), o.ok ? "verified clean" : o.err);
}
// validateArchiveList itself — the adjacent cases, enumerated.
{
  const threw = (list) => { try { validateArchiveList(list); return null; } catch (e) { return String(e.message); } };
  check("list: one open row is the honest single-archive shape", threw([{ canisterId: A1, firstSeq: 0n, lastSeq: [] }]) === null);
  check("list: sealed + open is the honest rolled shape",
    threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [1n] }, { canisterId: A1, firstSeq: 2n, lastSeq: [] }]) === null);
  check("list: sealed + open with a jump is structurally fine (the jump is for the walk to justify)",
    threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [1n] }, { canisterId: A1, firstSeq: 4n, lastSeq: [] }]) === null);
  check("list: sealed only (a hidden season tip leaves this) is accepted — the last row may be sealed",
    threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [1n] }]) === null);
  check("list: a one-event sealed row (firstSeq == lastSeq) is accepted",
    threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [0n] }, { canisterId: A1, firstSeq: 1n, lastSeq: [] }]) === null);
  check("list: a non-final open row is refused",
    /routing list malformed.*open/.test(threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [] }, { canisterId: A1, firstSeq: 2n, lastSeq: [] }]) || ""));
  check("list: an overlap (firstSeq == predecessor's lastSeq) is refused",
    /routing list malformed.*ascending/.test(threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [1n] }, { canisterId: A1, firstSeq: 1n, lastSeq: [] }]) || ""));
  check("list: a row starting below its predecessor is refused",
    /routing list malformed.*ascending/.test(threw([{ canisterId: A0, firstSeq: 2n, lastSeq: [3n] }, { canisterId: A1, firstSeq: 0n, lastSeq: [] }]) || ""));
  check("list: an inverted entry (lastSeq < firstSeq) is refused",
    /routing list malformed.*inverted/.test(threw([{ canisterId: A0, firstSeq: 3n, lastSeq: [1n] }]) || ""));
  check("list: three rows — the middle one open — is refused",
    /routing list malformed.*open/.test(threw([{ canisterId: A0, firstSeq: 0n, lastSeq: [1n] }, { canisterId: "x", firstSeq: 2n, lastSeq: [] }, { canisterId: A1, firstSeq: 5n, lastSeq: [] }]) || ""));
}

// ── #55.6 window mode ────────────────────────────────────────────────
{
  const ev = await chain([
    (p) => delta(0, 500_000_000, p), (p) => delta(1, 250_000_000, p), (p) => delta(2, 100_000_000, p),
  ], []);
  const one = [{ canisterId: A1, firstSeq: 0n, lastSeq: [] }];
  // window-liar: the head claims chainStartSeq = headSeq. Pre-fix the walk
  // clamped to it — one event, 0 links, a trivially matching head, resolved.
  const liar = await run(deps(one, { [A1]: await actorFor(ev, 2) }, []), { lastN: 3 });
  check("window-liar: chainStartSeq = headSeq never clamps the window — lastN 3 walks the tape (2 links)",
    liar.ok && liar.res.links === 2 && liar.res.windowNote === null, liar.ok ? JSON.stringify(liar.res) : liar.err);
  // window-clip-liar: the claim moved into the routing list — firstSeq =
  // headSeq, nothing served below it, no predecessor listed, no #gap.
  const clipped = { async getEventsRange(f, n) { return ev.filter((e) => Number(e.seq) >= 2 && Number(e.seq) >= Number(f) && Number(e.seq) < Number(f) + Number(n)); },
                    getCertifiedHead: (await actorFor(ev, 2)).getCertifiedHead };
  const clipLiar = await run(deps([{ canisterId: A1, firstSeq: 2n, lastSeq: [] }], { [A1]: clipped }, []), { lastN: 3 });
  check("window-clip-liar: a serve-bound clip nothing bridges or declares is refused (early tape omitted)",
    !clipLiar.ok && /early tape omitted/.test(clipLiar.err), clipLiar.ok ? "verified clean: " + JSON.stringify(clipLiar.res) : clipLiar.err);
  // genesis-only: one honest event, zero links legitimately.
  const genesis = await run(deps(one, { [A1]: await actorFor(ev.slice(0, 1), 0) }, []), { lastN: 3 });
  check("genesis-only: a one-event tape has 0 links and still verifies in window mode",
    genesis.ok && genesis.res.links === 0, genesis.ok ? JSON.stringify(genesis.res) : genesis.err);
  // The window that exactly fits the tape needs no seed and reports no clip.
  const exact = await run(deps(one, { [A1]: await actorFor(ev, 0) }, []), { lastN: 2 });
  check("lastN inside the tape seeds from seq from-1 on the active archive (2 links for lastN 2)",
    exact.ok && exact.res.links === 2 && exact.res.windowNote === null, exact.ok ? JSON.stringify(exact.res) : exact.err);
}
{
  // double-shed in window mode: sealed [0..1], active anchored at 4 with
  // #gap[2..3), #gap[3..4), then a delta at 6.
  const active = await chain([
    (p) => gapEv(4, 2, 3, p), (p) => gapEv(5, 3, 4, p), (p) => delta(6, 1_000_000, p),
  ], DROPPED);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 4n, lastSeq: [] },
  ];
  const actors = { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 4) };
  const wide = await run(deps(archives, actors, [[2n, 4n, 0n]]), { lastN: 10 });
  check("double-shed lastN 10: the sealed segment is VISITED (3 links, 2 heads) and the inner jump [2..4) is justified by the chain's contiguous #gap run",
    wide.ok && wide.res.links === 3 && wide.res.heads === 2 && /\[2\.\.4\) inside the window is a chain-declared/.test(wide.res.windowNote)
      && /spans 2 of 2 archives/.test(wide.res.windowNote),
    wide.ok ? JSON.stringify(wide.res) : wide.err);
  // A window that spans the jump but not the whole sealed segment: [1..6]
  // visits the sealed tail from seq 1 (self-seeded from seq 0) — 1 link
  // there, the jump, 2 links on the active.
  const partial = await run(deps(archives, actors, [[2n, 4n, 0n]]), { lastN: 6 });
  check("double-shed lastN 6: the sealed segment is walked from inside it (seeded from its own seq 0) — 3 links, 2 heads",
    partial.ok && partial.res.links === 3 && partial.res.heads === 2, partial.ok ? JSON.stringify(partial.res) : partial.err);
  // lastN 3 starts exactly at the re-anchor (requestedFrom 4): the window's
  // edge, nothing to bridge (the predecessor ends at 1), no jump claimed —
  // the region below is unverified by definition, and the sealed archive
  // below the window is named as not visited.
  const edge = await run(deps(archives, actors, [[2n, 4n, 0n]]), { lastN: 3 });
  check("double-shed lastN 3: a window starting exactly at the re-anchor walks the segment alone (2 links, 1 head, the older archive named as not visited)",
    edge.ok && edge.res.links === 2 && edge.res.heads === 1 && /1 older sealed archive holds tape below seq 4/.test(edge.res.windowNote),
    edge.ok ? JSON.stringify(edge.res) : edge.err);
  const inside = await run(deps(archives, actors, [[2n, 4n, 0n]]), { lastN: 2 });
  check("double-shed lastN 2: the window inside the segment seeds from the tape (2 links, no clip, the older archive named as not visited)",
    inside.ok && inside.res.links === 2 && inside.res.heads === 1 && /1 older sealed archive holds tape below seq 5/.test(inside.res.windowNote)
      && !/clipped/.test(inside.res.windowNote),
    inside.ok ? JSON.stringify(inside.res) : inside.err);
  // A clipped window that would start at the shed's first declaration but
  // whose first event is the ONLY event: still the justified zero-link shape.
  const lone = await chain([(p) => gapEv(4, 2, 4, p)], DROPPED);
  const loneRun = await run(deps(archives, { [A0]: actors[A0], [A1]: await actorFor(lone, 4) }, [[2n, 4n, 0n]]), { lastN: 10 });
  check("a re-anchor whose only event is its own #gap declaration: the visited sealed segment's 1 link, the jump justified — verifies",
    loneRun.ok && loneRun.res.links === 1 && loneRun.res.heads === 2 && /\[2\.\.4\) inside the window is a chain-declared/.test(loneRun.res.windowNote),
    loneRun.ok ? JSON.stringify(loneRun.res) : loneRun.err);
  // The same lone re-anchor with the window starting AT it: zero links, no
  // jump inside the window, from ≠ origin — the zero-progress rule refuses
  // (the host chose the one event it served; nothing verifiable).
  const loneEdge = await run(deps(archives, { [A0]: actors[A0], [A1]: await actorFor(lone, 4) }, [[2n, 4n, 0n]]), { lastN: 1 });
  check("the lone re-anchor with lastN 1 (window at its start, 0 links, nothing declared inside) is refused by the zero-progress rule",
    !loneEdge.ok && /nothing verifiable/.test(loneEdge.err), loneEdge.ok ? "verified clean: " + JSON.stringify(loneEdge.res) : loneEdge.err);
}
{
  // Continuous coverage: the window reaching below the boundary is bridged by
  // the predecessor's own last event — the cross-archive link is verified.
  const active = await chain([(p) => delta(2, 100_000_000, p)], [await hashEvent(sealed[1])]);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 2n, lastSeq: [] },
  ];
  const bridged = await run(deps(archives, { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 2) }, []), { lastN: 10 });
  check("continuous lastN 10: both archives visited, the link carried across the boundary (2 links, 2 heads, no clip)",
    bridged.ok && bridged.res.links === 2 && bridged.res.heads === 2 && /spans 2 of 2 archives/.test(bridged.res.windowNote)
      && !/clipped/.test(bridged.res.windowNote),
    bridged.ok ? JSON.stringify(bridged.res) : bridged.err);
  // lastN 1: the window starts exactly at the boundary — the unvisited
  // predecessor's own last event seeds the walk (the cross-archive link is
  // verified for free, 1 link), and it is named as not visited.
  const edge = await run(deps(archives, { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 2) }, []), { lastN: 1 });
  check("continuous lastN 1: the window at the boundary is bridged by the unvisited predecessor's last event (1 link, 1 head)",
    edge.ok && edge.res.links === 1 && edge.res.heads === 1 && /1 older sealed archive holds tape below seq 2/.test(edge.res.windowNote),
    edge.ok ? JSON.stringify(edge.res) : edge.err);
  // A listed predecessor that serves nothing: visited (lastN 10) it is a
  // tape gap at its first seq; unvisited (lastN 1) it cannot bridge.
  const hollow = { async getEventsRange() { return []; }, getCertifiedHead: (await actorFor(sealed, 0)).getCertifiedHead };
  const hollowVisited = await run(deps(archives, { [A0]: hollow, [A1]: await actorFor(active, 2) }, []), { lastN: 10 });
  check("a visited sealed segment serving nothing is refused (tape gap at its first seq)",
    !hollowVisited.ok && /tape gap at seq 0/.test(hollowVisited.err), hollowVisited.ok ? "verified clean" : hollowVisited.err);
  const unbridged = await run(deps(archives, { [A0]: hollow, [A1]: await actorFor(active, 2) }, []), { lastN: 1 });
  check("an unvisited predecessor serving nothing at its lastSeq cannot bridge the window — refused",
    !unbridged.ok && /serves nothing there/.test(unbridged.err), unbridged.ok ? "verified clean" : unbridged.err);
  // The predecessor's event bridges only if it IS the real predecessor: a
  // stranger's hash at seq 1 breaks the first link.
  const stranger = await chain([(p) => delta(0, 1, p), (p) => delta(1, 2, p)], []);
  const forged = await run(deps(archives, { [A0]: await actorFor(stranger, 0), [A1]: await actorFor(active, 2) }, []), { lastN: 10 });
  check("a predecessor serving a different seq-1 breaks the bridged link (chain BREAK)",
    !forged.ok && /chain BREAK/.test(forged.err), forged.ok ? "verified clean" : forged.err);
}

{
  // 1788472713: three archives — sealed [0..1], sealed [2..3], active [4..5]
  // on one continuous chain. The window routes backwards across the list:
  // lastN 3 (requestedFrom 3) visits the MIDDLE sealed segment from inside
  // it (self-seeded from its own seq 2) and carries the hash into the
  // active; lastN 4 (requestedFrom 2) starts at its boundary and is bridged
  // by the unvisited first segment's last event; lastN 6 walks everything
  // from the origin. Every visited head is compared (heads counts them).
  const A2 = "r7inp-6aaaa-aaaaa-aaabq-cai";
  const six = await chain([
    (p) => delta(0, 1, p), (p) => delta(1, 2, p), (p) => delta(2, 3, p),
    (p) => delta(3, 4, p), (p) => delta(4, 5, p), (p) => delta(5, 6, p),
  ], []);
  const archives = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 2n, lastSeq: [3n] },
    { canisterId: A2, firstSeq: 4n, lastSeq: [] },
  ];
  const actors = { [A0]: await actorFor(six.slice(0, 2), 0), [A1]: await actorFor(six.slice(2, 4), 2), [A2]: await actorFor(six.slice(4), 4) };
  const inMiddle = await run(deps(archives, actors, []), { lastN: 3 });
  check("three archives lastN 3: the middle sealed segment is walked from inside it (self-seeded) and carried into the active — 3 links, 2 heads",
    inMiddle.ok && inMiddle.res.links === 3 && inMiddle.res.heads === 2 && /spans 2 of 3 archives/.test(inMiddle.res.windowNote)
      && /1 older sealed archive holds tape below seq 3/.test(inMiddle.res.windowNote),
    inMiddle.ok ? JSON.stringify(inMiddle.res) : inMiddle.err);
  const atMiddle = await run(deps(archives, actors, []), { lastN: 4 });
  check("three archives lastN 4: the window starts at the middle segment's boundary, bridged by the first segment's last event — 4 links, 2 heads",
    atMiddle.ok && atMiddle.res.links === 4 && atMiddle.res.heads === 2, atMiddle.ok ? JSON.stringify(atMiddle.res) : atMiddle.err);
  const all = await run(deps(archives, actors, []), { lastN: 6 });
  check("three archives lastN 6: the window reaches the origin — every archive visited, 5 links, 3 heads, nothing unvisited",
    all.ok && all.res.links === 5 && all.res.heads === 3 && /spans 3 of 3 archives/.test(all.res.windowNote) && !/not visited/.test(all.res.windowNote),
    all.ok ? JSON.stringify(all.res) : all.err);
  // Omitting the middle segment from the list: the boundary [2..4) inside
  // the window is a jump no #gap event declares — refused (the full walk's
  // "unjustified discontinuity", now inside a window).
  const omitted = await run(deps([archives[0], archives[2]], actors, []), { lastN: 6 });
  check("three archives, middle omitted, lastN 6: the jump [2..4) inside the window is an unjustified discontinuity",
    !omitted.ok && /unjustified discontinuity/.test(omitted.err) && /\[2\.\.4\)/.test(omitted.err),
    omitted.ok ? "verified clean: " + JSON.stringify(omitted.res) : omitted.err);
  // ...and the same omission BELOW the window (lastN 2, requestedFrom 4 =
  // the active's firstSeq) is out of scope: the window's edge, nothing to
  // bridge (the listed predecessor ends at 1), 1 link, the region below
  // unverified by definition.
  const below = await run(deps([archives[0], archives[2]], actors, []), { lastN: 2 });
  check("three archives, middle omitted, lastN 2: the omission lies below the window and is not judged (1 link, edge unbridged)",
    below.ok && below.res.links === 1 && below.res.heads === 1, below.ok ? JSON.stringify(below.res) : below.err);
}

// ── #55 (1788468754) season mode ─────────────────────────────────────
{
  const active = await chain([(p) => delta(2, 100_000_000, p)], [await hashEvent(sealed[1])]);
  const A2 = "r7inp-6aaaa-aaaaa-aaabq-cai";   // pre-spawned before the boundary, never written
  const table = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 2n, lastSeq: [] },
    { canisterId: A2, firstSeq: 0n, lastSeq: [] },
  ];
  const empty = { async getEventsRange() { return []; },
                  async getCertifiedHead() { return { headHash: [], headSeq: [], chainStartSeq: [], certificate: [] }; } };
  const actors = { [A0]: await actorFor(sealed, 0), [A1]: await actorFor(active, 2), [A2]: empty };
  const P = (t) => ({ toText: () => t });
  const tipHead = await hashEvent(active[0]);
  const rec = (over) => ({ season: 1n, endedNs: 0n, finalEventSeq: 3n, totalRanked: 0n, finalTop: [],
    archives: [P(A0), P(A1), P(A2)], chainHead: [tipHead], ...(over || {}) });
  // The live deps answer for the NEW season: an empty routing table and a
  // gap tuple [0..2) that a season walk must not consult (it would null the
  // seed at the sealed boundary and then demand a #gap event that is not there).
  const seasonDeps = (tbl, recs, acts) => ({ ...deps([], acts || actors, [[0n, 2n, 0n]]),
    listSeasonArchives: async (n) => (Number(n) === 1 ? tbl : []), getSeasonRecords: async () => recs });
  const okRun = await run(seasonDeps(table, [rec()]), { season: 1 });
  check("season 1: routed by the season table — 2 links across the sealed boundary, successor skipped, record anchor met, new-season tuple ignored",
    okRun.ok && okRun.res.links === 2 && okRun.res.heads === 2 && okRun.res.gapCount === 0 && /season 1 anchored/.test(okRun.res.seasonNote),
    okRun.ok ? JSON.stringify(okRun.res) : okRun.err);
  const headLiar = await run(seasonDeps(table, [rec({ chainHead: [new Uint8Array(32).fill(0xcd)] })]), { season: 1 });
  check("season head-liar: a SeasonRecord chainHead the walk never reaches is refused",
    !headLiar.ok && /SeasonRecord's chainHead/.test(headLiar.err), headLiar.ok ? "verified clean" : headLiar.err);
  const extentLiar = await run(seasonDeps(table, [rec({ finalEventSeq: 4n })]), { season: 1 });
  check("season extent-liar: finalEventSeq ≠ tape end + 1 is refused",
    !extentLiar.ok && /finalEventSeq is 4/.test(extentLiar.err), extentLiar.ok ? "verified clean" : extentLiar.err);
  const truncated = await run(seasonDeps(table.slice(1), [rec()]), { season: 1 });
  check("season-truncated: a season table missing its sealed segment is refused by the origin pin",
    !truncated.ok && /early archives omitted/.test(truncated.err), truncated.ok ? "verified clean" : truncated.err);
  const hidden = await run(seasonDeps(table, [rec()], { ...actors, [A1]: empty }), { season: 1 });
  check("hidden tip: a tip answering an empty head is not 'skipped' — the sealed head ≠ the record's chainHead",
    !hidden.ok && /SeasonRecord's chainHead/.test(hidden.err), hidden.ok ? "verified clean" : hidden.err);
  const unknown = await run(seasonDeps(table, [rec()]), { season: 2 });
  check("unknown season: no SeasonRecord → refused",
    !unknown.ok && /no SeasonRecord for season 2/.test(unknown.err), unknown.ok ? "verified clean" : unknown.err);
  // 1788477403: the record survives a #dev/#play resetExchange, its archives
  // do not — an EMPTY season table under a committed chainHead is "the tape
  // was deleted", never "no segment holds any event" (that wording is kept
  // for a table whose rows are all headless, exercised by `hidden` above).
  const wiped = await run(seasonDeps([], [rec()]), { season: 1 });
  check("season-wiped: an EMPTY season table for a record that committed a chainHead is refused as 'archives deleted' (names 3 archive(s), resetExchange named), not 'no segment holds any event'",
    !wiped.ok && /season 1: the SeasonRecord names 3 archive\(s\) but none is routed any more/.test(wiped.err)
      && /resetExchange/.test(wiped.err) && /chainHead cannot be re-walked/.test(wiped.err) && !/no segment holds any event/.test(wiped.err),
    wiped.ok ? "verified clean" : wiped.err);
  const wipedNoHead = await run(seasonDeps([], [rec({ finalEventSeq: 0n, chainHead: [] })]), { season: 1 });
  check("season-wiped + no chainHead: the no-tape verdict wins (nothing anchors a sealed chain) — the wiped wording is reserved for a committed head",
    !wipedNoHead.ok && /committed no chainHead/.test(wipedNoHead.err) && !/none is routed any more/.test(wipedNoHead.err),
    wipedNoHead.ok ? "verified clean" : wipedNoHead.err);
  const both = await run(seasonDeps(table, [rec()]), { season: 1, lastN: 3 });
  check("season + lastN are exclusive (a sealed season is walked in full)",
    !both.ok && /exclusive/.test(both.err), both.ok ? "verified clean" : both.err);
  // 1788474114: the closed season that SHED. Its tip re-anchored at 3 after
  // the [2..3) drop, opening with the chain's own #gap[2..3) and one absolute
  // re-attestation row at seq 4; the boundary preserved the tuple and the
  // baseline [4..5). The live pair still answers the NEW season's [0..2).
  const shedTip = await chain([(p) => gapEv(3, 2, 3, p), (p) => delta(4, 1_000_000, p)], DROPPED);
  const shedTable = [
    { canisterId: A0, firstSeq: 0n, lastSeq: [1n] },
    { canisterId: A1, firstSeq: 3n, lastSeq: [] },
    { canisterId: A2, firstSeq: 0n, lastSeq: [] },
  ];
  const shedActors = { ...actors, [A1]: await actorFor(shedTip, 3) };
  const shedRec = rec({ finalEventSeq: 5n, chainHead: [await hashEvent(shedTip[1])] });
  const preserved = (gapsN, baselinesN) => ({
    getSeasonGaps: async (n) => (Number(n) === 1 ? gapsN : []),
    getSeasonShedBaselines: async (n) => (Number(n) === 1 ? baselinesN : []),
  });
  const shedOk = await run({ ...seasonDeps(shedTable, [shedRec], shedActors), ...preserved([[2n, 3n, 0n]], [[4n, 5n]]) }, { season: 1 });
  check("season-shed: the PRESERVED tuple [2..3) is the re-anchor claim (proven by the tip's #gap), the preserved baseline [4..5) is the fold reset — 2 links, gapCount 1, baselineCount 1, baselineResumeSeq 5",
    shedOk.ok && shedOk.res.links === 2 && shedOk.res.heads === 2 && shedOk.res.gapCount === 1 && shedOk.res.chainGapCount === 1
      && shedOk.res.baselineCount === 1 && shedOk.res.baselineResumeSeq === 5 && shedOk.res.gapEventsMissing === 1
      && /season 1 anchored/.test(shedOk.res.seasonNote),
    shedOk.ok ? JSON.stringify(shedOk.res) : shedOk.err);
  const shedLegacy = await run(seasonDeps(shedTable, [shedRec], shedActors), { season: 1 });
  check("season-shed on a pre-1788474114 backend (no season deps): the list jump is still inferred and chain-proven — 2 links, gapCount 0, baselineCount 0 (no reset point to report)",
    shedLegacy.ok && shedLegacy.res.links === 2 && shedLegacy.res.gapCount === 0 && shedLegacy.res.baselineCount === 0 && shedLegacy.res.chainGapCount === 1,
    shedLegacy.ok ? JSON.stringify(shedLegacy.res) : shedLegacy.err);
  const shedFabricated = await run({ ...seasonDeps(table, [rec()]), ...preserved([[0n, 2n, 0n]], []) }, { season: 1 });
  check("season-fabricated-gap: a PRESERVED tuple at the continuous sealed boundary is still only a claim — the empty [2..2) has no #gap event, refused",
    !shedFabricated.ok && /unjustified discontinuity/.test(shedFabricated.err) && /\[2\.\.2\)/.test(shedFabricated.err),
    shedFabricated.ok ? "verified clean" : shedFabricated.err);
  const liveUnaffected = await run(deps([{ canisterId: A1, firstSeq: 0n, lastSeq: [] }],
    { [A1]: await actorFor(await chain([(p) => delta(0, 1, p), (p) => delta(1, 2, p)], []), 0) }, []), {});
  check("no opts.season: the live walk still routes by listArchives (season deps absent)",
    liveUnaffected.ok && liveUnaffected.res.links === 1 && liveUnaffected.res.seasonNote === null,
    liveUnaffected.ok ? JSON.stringify(liveUnaffected.res) : liveUnaffected.err);

  // 1788474115: the PAGE's picker feeds the verifier through verifyScopeOpts —
  // a `season:N` choice arrives as { season: N } and nothing else (the
  // verifier refuses season + lastN, so the page must never mint the pair),
  // and that untouched object drives the same sealed walk as above.
  check("verifyScopeOpts: \"season:1\" → exactly { season: 1 } (no lastN beside it)",
    J(verifyScopeOpts("season:1")) === J({ season: 1 }), J(verifyScopeOpts("season:1")));
  check("verifyScopeOpts: \"full\" → {} (the whole live chain)",
    J(verifyScopeOpts("full")) === J({}), J(verifyScopeOpts("full")));
  check("verifyScopeOpts: \"2000\" → { lastN: 2000 }; junk and unset fall back to the 500 window",
    J(verifyScopeOpts("2000")) === J({ lastN: 2000 }) && J(verifyScopeOpts("season:x")) === J({ lastN: 500 })
      && J(verifyScopeOpts(undefined)) === J({ lastN: 500 }) && J(verifyScopeOpts("0")) === J({ lastN: 500 }),
    `${J(verifyScopeOpts("2000"))} ${J(verifyScopeOpts("season:x"))} ${J(verifyScopeOpts(undefined))} ${J(verifyScopeOpts("0"))}`);
  const viaPicker = await run(seasonDeps(table, [rec()]), verifyScopeOpts("season:1"));
  check("the picker's season:1 value drives the sealed walk end to end (2 links, record anchor met)",
    viaPicker.ok && viaPicker.res.links === 2 && /season 1 anchored/.test(viaPicker.res.seasonNote),
    viaPicker.ok ? J(viaPicker.res) : viaPicker.err);
  // The picker LISTS an empty season (finalEventSeq 0, chainHead null) with an
  // honest label instead of hiding it; the verifier refuses it, as pinned above.
  check("seasonOptionLabel: a sealed season names its last seq (finalEventSeq - 1)",
    seasonOptionLabel(rec()) === "Verify season 1 (sealed, ends seq 2)", seasonOptionLabel(rec()));
  check("seasonOptionLabel: an empty season (finalEventSeq 0, chainHead null) is labelled unverifiable, not hidden",
    /season 7 .*no tape.*unverifiable/.test(seasonOptionLabel(rec({ season: 7n, finalEventSeq: 0n, chainHead: [] }))),
    seasonOptionLabel(rec({ season: 7n, finalEventSeq: 0n, chainHead: [] })));
  // 1788477403: the wiped flag (learned from a verify verdict, never probed
  // per record) relabels a sealed season; it needs nothing but the season no.
  check("seasonOptionLabel(rec, wiped=true): 'sealed — archives wiped', from the season number alone",
    seasonOptionLabel({ season: 3n }, true) === "Verify season 3 (sealed — archives wiped)"
      && seasonOptionLabel(rec(), false) === "Verify season 1 (sealed, ends seq 2)",
    `${seasonOptionLabel({ season: 3n }, true)} | ${seasonOptionLabel(rec(), false)}`);
}

// ── planWindow ───────────────────────────────────────────────────────
// 1788472713: planWindow(origin, headSeq, lastN, archives, reanchors) plans a
// clipped full walk: `segments` (oldest visited first) each say where the
// walk starts/ends on that archive, where its seed comes from ("carried" |
// "self" | "predecessor" | null) and the coverage `jump` the caller must find
// chain-declared. Tape below requestedFrom is never planned.
{
  const R = (list) => list.map(([id, f, l]) => ({ canisterId: id, firstSeq: BigInt(f), lastSeq: l === null ? [] : [BigInt(l)] }));
  const plan = (origin, headSeq, lastN, list, reanchors) => planWindow(origin, headSeq, lastN, R(list), new Set(reanchors || []));
  const seg = (index, first, from, to, seedOn, jump) => ({ index, first, from, to, seedOn, jump });
  const one = [[A1, 0, null]];
  check("plan: a window inside the tape seeds from the archive itself, no clip",
    J(plan(0, 100, 10, one)) === J({ requestedFrom: 91, segments: [seg(0, 0, 91, 100, "self", null)] }), J(plan(0, 100, 10, one)));
  check("plan: a window reaching the chain origin needs no seed",
    J(plan(0, 2, 3, one)) === J({ requestedFrom: 0, segments: [seg(0, 0, 0, 2, null, null)] }), J(plan(0, 2, 3, one)));
  check("plan: firstSeq clips the start; without a predecessor the clip is a jump from the origin",
    J(plan(0, 2, 3, [[A1, 2, null]])) === J({ requestedFrom: 0, segments: [seg(0, 2, 2, 2, null, [0, 2])] }), J(plan(0, 2, 3, [[A1, 2, null]])));
  const two = [[A0, 0, 1], [A1, 2, null]];
  check("plan: a contiguous predecessor inside the window is VISITED and the hash carried across (no bridge, no jump)",
    J(plan(0, 2, 10, two)) === J({ requestedFrom: 0, segments: [seg(0, 0, 0, 1, null, null), seg(1, 2, 2, 2, "carried", null)] }), J(plan(0, 2, 10, two)));
  check("plan: a window starting exactly at the boundary is bridged by the unvisited predecessor (seed on the predecessor)",
    J(plan(0, 3, 2, two)) === J({ requestedFrom: 2, segments: [seg(1, 2, 2, 3, "predecessor", null)] }), J(plan(0, 3, 2, two)));
  check("plan: a window inside the active archive visits it alone, self-seeded",
    J(plan(0, 5, 2, two)) === J({ requestedFrom: 4, segments: [seg(1, 2, 4, 5, "self", null)] }), J(plan(0, 5, 2, two)));
  const shed = [[A0, 0, 1], [A1, 4, null]];
  check("plan: a non-contiguous boundary inside the window is a jump [prevLast+1..firstSeq) — the predecessor still visited",
    J(plan(0, 6, 10, shed)) === J({ requestedFrom: 0, segments: [seg(0, 0, 0, 1, null, null), seg(1, 4, 4, 6, null, [2, 4])] }), J(plan(0, 6, 10, shed)));
  check("plan: the window that starts exactly at a re-anchor is the window's edge (no jump, no seed, nothing below planned)",
    J(plan(0, 6, 3, shed)) === J({ requestedFrom: 4, segments: [seg(1, 4, 4, 6, null, null)] }), J(plan(0, 6, 3, shed)));
  check("plan: a tuple claiming a re-anchor at a CONTIGUOUS boundary inside the window is the empty jump [2..2) (refused downstream, as in --full)",
    J(plan(0, 2, 10, two, [2])) === J({ requestedFrom: 0, segments: [seg(0, 0, 0, 1, null, null), seg(1, 2, 2, 2, null, [2, 2])] }), J(plan(0, 2, 10, two, [2])));
  check("plan: a tuple at the window's EDGE is neither honored nor refuted — the contiguous predecessor still bridges",
    J(plan(0, 3, 2, two, [2])) === J({ requestedFrom: 2, segments: [seg(1, 2, 2, 3, "predecessor", null)] }), J(plan(0, 3, 2, two, [2])));
  const three = [[A0, 0, 1], [A1, 2, 3], ["x", 4, null]];
  check("plan: three archives, lastN 3 — the middle segment from inside it (self), the active carried",
    J(plan(0, 5, 3, three)) === J({ requestedFrom: 3, segments: [seg(1, 2, 3, 3, "self", null), seg(2, 4, 4, 5, "carried", null)] }), J(plan(0, 5, 3, three)));
  check("plan: three archives, lastN 4 — the middle segment at its edge (predecessor-bridged), the active carried",
    J(plan(0, 5, 4, three)) === J({ requestedFrom: 2, segments: [seg(1, 2, 2, 3, "predecessor", null), seg(2, 4, 4, 5, "carried", null)] }), J(plan(0, 5, 4, three)));
  check("plan: expectStart raises the origin floor — the walk starts AT the origin, unseeded",
    J(plan(5, 100, 200, one)) === J({ requestedFrom: 5, segments: [seg(0, 0, 5, 100, null, null)] }), J(plan(5, 100, 200, one)));
  check("plan: does not mutate the routing list",
    (() => { const list = R(two); const S = (x) => JSON.stringify(x, (_, v) => (typeof v === "bigint" ? String(v) : v)); const before = S(list);
             planWindow(0, 2, 10, list, new Set()); return S(list) === before; })());
  {
    let threw = null;
    try { plan(0, 2, 3, [[A1, 3, null]]); } catch (e) { threw = String(e.message); }
    check("plan: a firstSeq beyond the certified head is refused", !!threw && /beyond the certified head/.test(threw), threw || "no throw");
  }
}

// ── mergeContiguousGaps ──────────────────────────────────────────────
check("merge: contiguous run collapses to one range, regardless of input order",
  J(mergeContiguousGaps([[3, 4], [0, 2], [2, 3]])) === J([[0, 4]]), J(mergeContiguousGaps([[3, 4], [0, 2], [2, 3]])));
check("merge: a hole keeps the ranges apart",
  J(mergeContiguousGaps([[0, 2], [3, 4]])) === J([[0, 2], [3, 4]]));
check("merge: an overlap is not contiguous and is kept apart",
  J(mergeContiguousGaps([[0, 2], [1, 3]])) === J([[0, 2], [1, 3]]));
check("merge: empty in, empty out", J(mergeContiguousGaps([])) === J([]));
{
  const input = [[2, 3], [3, 4]];
  mergeContiguousGaps(input);
  check("merge: does not mutate its input", J(input) === J([[2, 3], [3, 4]]));
}

// ── Drift lock: the CLI twin carries the same bodies ─────────────────
{
  const HERE = dirname(fileURLToPath(import.meta.url));
  const grab = (file, name) => {
    const re = new RegExp("^(?:export )?function " + name + "\\([^)]*\\) \\{[\\s\\S]*?\\n\\}", "m");
    const m = readFileSync(file, "utf8").match(re);
    return m ? m[0].replace(/^export /, "").replace(/\s+/g, " ") : null;
  };
  for (const name of ["mergeContiguousGaps", "planWindow", "validateArchiveList"]) {
    const page = grab(join(HERE, "..", "src", "frontend", "src", "ledger.js"), name);
    const cli = grab(join(HERE, "..", "scripts", "verify_ledger.mjs"), name);
    check(`${name} is byte-identical (modulo whitespace) in ledger.js and verify_ledger.mjs`,
      !!page && !!cli && page === cli, `page: ${page}\n    cli:  ${cli}`);
  }
}

console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: verify_chain_client (${passed} passed, ${failed} failed)`);
process.exit(failed === 0 ? 0 : 1);
