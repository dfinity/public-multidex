// The Public Ledger (top-level Ledger tab) — the archive chain made visible, and
// the CLIENT-SIDE verifier that closes the trust loop:
//
//   1. every event's canonical bytes are re-derived HERE, in the browser
//      (mirror of src/backend/lib/EventChain.mo v1 — length-prefixed
//      netstring fields, frozen order), and SHA-256'd with WebCrypto;
//   2. each event's recomputed hash must equal its successor's prevHash —
//      one unbroken chain, including across sealed archive canisters;
//   3. the final hash must equal the archive's certified head, and the head
//      itself is validated against the IC CERTIFICATE (subnet BLS signature
//      over certified_data) — so nothing in the pipeline trusts the
//      canister's own claims.
//
// Folding the #delta rows of this same public tape per account is the
// Proof-of-Reserves liabilities computation — the explainer on the page
// says exactly that. IMPORTANT: verification needs RAW candid values
// (BigInts) — the actors used here are deliberately NOT money-normalized.

import { isLocalReplicaOrigin } from "./host.js";

const enc = new TextEncoder();

// ── Canonical form (EventChain.mo v1 mirror — field order is FROZEN) ──
function net(parts, bytes) {
  parts.push(enc.encode(String(bytes.length) + ":"));
  parts.push(bytes);
}
const putT = (p, t) => net(p, enc.encode(t));
const putN = (p, v) => putT(p, v.toString());   // Nat/Int (BigInt) → decimal text
const sideTag = (s) => ("buy" in s ? "buy" : "sell");
const optBytes = (o) => (o && o.length ? new Uint8Array(o[0]) : new Uint8Array(0));
const optPrincipalText = (o) => (o && o.length ? o[0].toText() : "");

export function canonicalEvent(e) {
  const p = [];
  putT(p, "v1");
  net(p, optBytes(e.prevHash));
  putN(p, e.seq);
  putN(p, e.ts);
  putT(p, e.user.toText());
  putT(p, optPrincipalText(e.counterparty));
  const k = e.kind;
  if ("fill" in k) {
    const f = k.fill;
    putT(p, "fill");
    putT(p, f.marketId); putT(p, sideTag(f.side));
    putN(p, f.price); putN(p, f.qty); putN(p, f.orderId); putN(p, f.tradeId);
  } else if ("deposit" in k) {
    const d = k.deposit;
    putT(p, "withdrawal" in d.kind ? "withdrawal" : "deposit");
    putT(p, d.token); putN(p, d.amount); putN(p, d.timestamp);
  } else if ("orderClosed" in k) {
    const o = k.orderClosed;
    putT(p, "orderClosed");
    putN(p, o.id); putT(p, o.marketId); putT(p, sideTag(o.side));
    putT(p, "market" in o.orderType ? "market" : "limit");
    putN(p, o.price); putN(p, o.quantity); putN(p, o.filled);
    putT(p, "filled" in o.status ? "filled" : "cancelled" in o.status ? "cancelled"
         : "open" in o.status ? "open" : "partiallyFilled");
    putN(p, o.placedAt); putN(p, o.closedAt);
  } else if ("liquidation" in k) {
    const l = k.liquidation;
    putT(p, "liquidation");
    putT(p, l.user.toText()); putT(p, l.debtToken); putN(p, l.debtRepaid);
    putN(p, l.debtRepaidUsd); putT(p, l.collateralToken); putN(p, l.collateralSeized);
    putN(p, l.proceedsUsd); putN(p, l.penaltyUsd);
    putN(p, l.healthBefore); putN(p, l.healthAfter); putN(p, l.timestamp);
  } else if ("borrow" in k) {
    putT(p, "borrow"); putT(p, k.borrow.token); putN(p, k.borrow.amount);
  } else if ("repay" in k) {
    putT(p, "repay"); putT(p, k.repay.token); putN(p, k.repay.amount);
  } else if ("lpDeposit" in k) {
    const d = k.lpDeposit;
    putT(p, "lpDeposit");
    putT(p, d.marketId); putN(p, d.baseAmount); putN(p, d.quoteAmount); putN(p, d.lpMinted);
  } else if ("lpWithdraw" in k) {
    const w = k.lpWithdraw;
    putT(p, "lpWithdraw");
    putN(p, w.lpBurned);
    putN(p, BigInt(w.basket.length));
    for (const [tok, amt] of w.basket) { putT(p, tok); putN(p, amt); }
  } else if ("insuranceStake" in k) {
    putT(p, "insuranceStake"); putN(p, k.insuranceStake.amountUsd); putN(p, k.insuranceStake.shares);
  } else if ("insuranceUnstake" in k) {
    putT(p, "insuranceUnstake"); putN(p, k.insuranceUnstake.shares); putN(p, k.insuranceUnstake.payoutUsd);
  } else if ("delta" in k) {
    putT(p, "delta"); putT(p, k.delta.token); putN(p, k.delta.amount);
  } else if ("debtDelta" in k) {
    putT(p, "debtDelta"); putT(p, k.debtDelta.token); putN(p, k.debtDelta.amount);
  } else if ("lpShareDelta" in k) {
    putT(p, "lpShareDelta"); putT(p, k.lpShareDelta.marketId); putN(p, k.lpShareDelta.amount);
  } else if ("insShareDelta" in k) {
    putT(p, "insShareDelta"); putN(p, k.insShareDelta.amount);
  } else if ("gap" in k) {
    putT(p, "gap"); putN(p, k.gap.fromSeq); putN(p, k.gap.toSeq);
  } else if ("config" in k) {
    putT(p, "config"); putT(p, k.config.setter); putT(p, k.config.value);
  } else {
    throw new Error("unknown event kind (verifier older than the canister?)");
  }
  let len = 0;
  for (const b of p) len += b.length;
  const out = new Uint8Array(len);
  let off = 0;
  for (const b of p) { out.set(b, off); off += b.length; }
  return out;
}

export async function hashEvent(e) {
  const digest = await crypto.subtle.digest("SHA-256", canonicalEvent(e));
  return new Uint8Array(digest);
}

const hex = (bytes, n) => {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const h = Array.from(n ? b.slice(0, n) : b).map((x) => x.toString(16).padStart(2, "0")).join("");
  return n && b.length > n ? h + "…" : h;
};
const bytesEq = (a, b) => {
  const x = new Uint8Array(a), y = new Uint8Array(b);
  if (x.length !== y.length) return false;
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
  return true;
};

// ── IC certificate validation (the head is only as good as its signature) ──
async function validateCertifiedHead(certBytes, canisterIdText, expectedHash, rootKey) {
  try {
    const { Certificate } = await import("@icp-sdk/core/agent");
    const { Principal } = await import("@icp-sdk/core/principal");
    const cid = Principal.fromText(canisterIdText);
    // @icp-sdk/core signature: { certificate, rootKey, principal } — create()
    // VERIFIES the BLS signature (and any subnet delegation) and throws on
    // failure, so reaching lookup_path means the certificate is genuine.
    // rootKey arrives as Uint8Array, ArrayBuffer or hex text depending on the
    // agent build — normalize to bytes (a hex STRING through Uint8Array()
    // yields zeros and traps the BLS verifier).
    let rk = rootKey;
    if (typeof rk === "string") {
      const hexStr = rk.replace(/^0x/, "");
      rk = new Uint8Array(hexStr.match(/.{2}/g).map((b) => parseInt(b, 16)));
    } else if (!(rk instanceof Uint8Array)) {
      rk = new Uint8Array(rk);
    }
    // Local replicas advance IC time per round, not per wall clock, so the
    // freshness window misfires there. It must NOT be waived anywhere else: a
    // replayed OLD certificate over an OLD head verifies perfectly, so with the
    // check off a truncated tape is indistinguishable from a current one — the
    // one failure this verifier exists to catch.
    const local = isLocalReplicaOrigin();
    const cert = await Certificate.create({
      certificate: new Uint8Array(certBytes),
      rootKey: rk,
      // TAGGED principal — the SDK dispatches on `canisterId`/`subnetId` being
      // present and throws its internal UNREACHABLE_ERROR for a bare Principal.
      // Passing one bare made every certificate check fail with "unreachable",
      // which the catch below reported as an environment limitation — so this
      // check, the one the root key exists to anchor, never actually ran, in
      // any environment. Same fix, same reasoning, as
      // scripts/verify_ledger.mjs:430-435.
      principal: { canisterId: cid },
      ...(local ? { disableTimeVerification: true } : {}),
    });
    const res = cert.lookup_path([enc.encode("canister"), cid.toUint8Array(), enc.encode("certified_data")]);
    if (!res || res.status !== "Found") return { ok: false, why: "certified_data path " + (res ? res.status : "missing") };
    return bytesEq(res.value, expectedHash)
      ? { ok: true }
      : { ok: false, why: "certified_data ≠ head hash" };
  } catch (err) {
    // Development replicas (pocket-ic) can still fail here — their certificates
    // and subnet ranges are synthetic. `null` means UNKNOWN, never OK: the
    // caller must not paint a verified state on it. Degrade honestly, never lie.
    return { ok: null, why: (err && err.message) || String(err) };
  }
}

// ── The verifier ─────────────────────────────────────────────────────
// Walks [fromSeq..toSeq] on one archive, checking every link. `seedHash` is
// the expected prevHash of the FIRST event (the predecessor's hash — null
// skips that check, e.g. at the chain anchor). Returns the final hash.
async function verifySlice(actor, fromSeq, toSeq, seedHash, onProgress, gapSink) {
  let expectPrev = seedHash;
  let lastHash = null;
  let s = fromSeq;
  let links = 0;
  while (s <= toSeq) {
    const page = await actor.getEventsRange(BigInt(s), BigInt(Math.min(200, toSeq - s + 1)));
    if (!page.length) throw new Error(`tape gap at seq ${s}`);
    for (const e of page) {
      if (Number(e.seq) > toSeq) break;
      if (expectPrev !== null) {
        const got = optBytes(e.prevHash);
        if (!bytesEq(got, expectPrev)) {
          throw new Error(`chain BREAK at seq ${e.seq}: prevHash ${hex(got, 8)} ≠ expected ${hex(expectPrev, 8)}`);
        }
        links++;
      }
      // W2-04: #gap events are the chain's OWN declaration of a shed — the
      // only re-anchor justification this verifier accepts (getLedgerGaps is
      // an uncertified self-report).
      if (gapSink && "gap" in e.kind) gapSink.push([Number(e.kind.gap.fromSeq), Number(e.kind.gap.toSeq)]);
      lastHash = await hashEvent(e);
      expectPrev = lastHash;
      s = Number(e.seq) + 1;
    }
    if (onProgress) onProgress(s - fromSeq, toSeq - fromSeq + 1);
  }
  return { lastHash, links };
}

// Verify the WHOLE routed chain (sealed archives oldest→newest, then the
// active one up to its certified head), or just the newest `lastN` events —
// a CLIPPED FULL WALK (1788472713): every archive holding tape inside the
// window is visited, the hash carried across each boundary, and only the
// tape below the window is skipped. Every archive's certified head is
// checked where the walk covers it.
export async function verifyChainClient(deps, opts, onStatus) {
  const { listArchives, makeRawArchiveActor, rootKey, getLedgerGaps, getShedBaselines, listSeasonArchives, getSeasonRecords,
          getSeasonGaps, getSeasonShedBaselines } = deps;
  const lastN = opts && opts.lastN;
  // #55 (1788468754): opts.season walks a CLOSED season's sealed chain — the
  // routing table is getSeasonArchives(N) (getArchives serves the current
  // season only), the origin is 0 like every epoch's, and the walked head
  // must ALSO equal the chainHead the SeasonRecord committed at the boundary,
  // with the tape ending at finalEventSeq-1. Full walk only: a window over a
  // finite sealed tape would skip the segments whose certificates are the point.
  // 1788474114: the closed season's gap tuples and shed re-baselines come from
  // deps.getSeasonGaps(N) / deps.getSeasonShedBaselines(N) (the boundary
  // preserves them; the live pair describes the NEW season) and are used
  // exactly as the live pair is in a live walk — claims the chain must prove,
  // and the fold's reset points (baselineCount / baselineResumeSeq).
  const season = opts && Number.isInteger(opts.season) ? opts.season : null;
  if (season !== null && lastN) throw new Error("a sealed season is walked in full — season and lastN are exclusive");
  let seasonRec = null;
  let archives;
  if (season !== null) {
    const recs = getSeasonRecords ? await getSeasonRecords() : [];
    seasonRec = recs.find((r) => Number(r.season) === season) || null;
    if (!seasonRec) throw new Error(`no SeasonRecord for season ${season} (${recs.length} season(s) recorded)`);
    if (!seasonRec.chainHead.length) throw new Error(`season ${season}: the SeasonRecord committed no chainHead${Number(seasonRec.finalEventSeq) === 0 ? " (finalEventSeq 0 — the season closed with no tape)" : ""} — nothing anchors a sealed chain; refusing to vouch`);
    const table = listSeasonArchives ? await listSeasonArchives(season) : [];
    // 1788477403: the SeasonRecord is the PERMANENT record — it survives a
    // #dev/#play resetExchange, which deletes every season's segments and
    // clears the routing tables. An EMPTY table under a record that committed
    // a chainHead is "the sealed tape is gone", a different verdict from "the
    // routed segments hold no event" (below); the page's picker relabels the
    // season from this message (setupLedger keys on "none is routed any more").
    if (!table.length) throw new Error(`season ${season}: the SeasonRecord names ${seasonRec.archives.length} archive(s) but none is routed any more — its sealed tape was deleted (a #dev/#play resetExchange wipes every season's archives and keeps only the record); the record's chainHead cannot be re-walked`);
    const recorded = new Set(seasonRec.archives.map((p) => p.toText()));
    archives = [];
    for (const a of table) {
      if (!recorded.has(a.canisterId)) throw new Error(`season ${season}: segment ${a.canisterId} is routed but absent from the SeasonRecord's archive list`);
      if (a.lastSeq.length) { archives.push(a); continue; }
      // A lastSeq-null row is the season's tip OR the successor pre-spawned
      // before the boundary, which never held an event — its certified head
      // tells. A hidden tip does not pass: the record's chainHead and
      // finalEventSeq still have to be met by whatever remains.
      const h = await (await makeRawArchiveActor(a.canisterId)).getCertifiedHead();
      if (!h.headHash.length) continue;
      archives.push(a);
    }
    if (!archives.length) throw new Error(`season ${season}: no segment holds any event`);
  } else {
    archives = await listArchives();
  }
  if (!archives.length) throw new Error("no archives yet — the ledger starts with the first event");
  // H-18 (F21): the routing list is an uncertified self-report, and its SHAPE
  // is checked before anything is walked — see validateArchiveList. Before
  // this, a non-final row with lastSeq null made the tentative re-anchor at
  // the row after it final with nothing to justify (both guards below keyed
  // on the predecessor's lastSeq), so the active segment verified linked to
  // nothing.
  validateArchiveList(archives);
  const active = archives[archives.length - 1];
  const activeActor = await makeRawArchiveActor(active.canisterId);
  const head = await activeActor.getCertifiedHead();
  if (!head.headHash.length) throw new Error("active archive has no chain head yet");
  const headSeq = Number(head.headSeq[0]);
  // The chain origin is an INPUT to the audit, shared by both modes.
  // #55.1: the default is 0, never the head's chainStartSeq — that field is
  // uncertified and is the ACTIVE segment's own per-canister anchor, so a
  // host that drops its sealed archives from getArchives and reports
  // start = its own firstSeq satisfied the full walk's genesis pin by
  // construction. The backend's tape starts at seq 0 on first deploy and
  // restarts at 0 at every season boundary (docs/pre-mainnet-checklist.md),
  // so 0 is the origin of every chain it serves; opts.expectStart is the
  // out-of-band override. Never seed this from anything the host answered.
  const origin = opts && Number.isInteger(opts.expectStart) ? opts.expectStart : 0;

  // Recorded ledger gaps (L2 archive-failover sheds). A gap's toSeq is a
  // legitimate re-anchor point: the archive beginning there opens a fresh chain
  // segment, so its first event's prevHash is NOT expected to link to the
  // previous archive's head. Consulting these tells a documented gap apart from
  // tampering (docs/archive-design.md §8b).
  // #55 (1788468754): the LIVE tuples (and the shed baselines below) describe
  // the CURRENT season — the boundary clears both — so a season walk never
  // reads them. 1788474114: the boundary now PRESERVES the closed season's
  // tuples (getSeasonGaps / getSeasonShedBaselines); season mode reads those,
  // as claims the sealed chain's own #gap events must still prove. A season
  // closed before that landed answers [] (a pre-1788474114 backend rejects →
  // []) — its re-anchors are then inferred from the list jumps below, as before.
  let gaps = [];
  if (season === null) { try { gaps = getLedgerGaps ? await getLedgerGaps() : []; } catch { /* pre-failover backend */ } }
  else { try { gaps = getSeasonGaps ? await getSeasonGaps(season) : []; } catch { /* pre-1788474114 backend */ } }
  const reanchorSeqs = new Set(gaps.map((g) => Number(g[1])));
  const gapEventsMissing = gaps.reduce((n, g) => n + (Number(g[1]) - Number(g[0])), 0);
  // W2-04: the tuples above are only CLAIMS. Each structural discontinuity
  // honored below must be justified after the walk by a #gap event that is
  // hash-committed in the chain itself, or by an operator-audited legacy gap
  // passed in opts.acceptGaps ([[from,to], …]).
  const acceptGaps = (opts && opts.acceptGaps) || [];
  const chainGaps = [];
  const pendingJustify = [];
  // Shed re-baselines: after each shed the canister re-attests EVERY balance
  // with absolute rows, so a replayer that resets at the baseline reconstructs
  // balances from the tape alone — the gap costs history, not replayability.
  let baselines = [];
  if (season === null) { try { baselines = getShedBaselines ? await getShedBaselines() : []; } catch { /* pre-baseline backend */ } }
  else { try { baselines = getSeasonShedBaselines ? await getSeasonShedBaselines(season) : []; } catch { /* pre-1788474114 backend */ } }

  let totalLinks = 0;
  let carried = null;   // hash carried across archive boundaries
  let heads = 0;
  let segCertsOk = 0;   // W2-04: per-segment certificates that validated
  let windowNote = null;   // #55.6: how a clipped window was accounted for
  let unvisitedBelowWindow = 0;   // 1788472713: sealed archives wholly below the window
  let seasonNote = null;   // #55 (1788468754): the sealed season's boundary anchor, once met
  let lastTo = null;       // where the last walked segment ends

  // W2-04: demand chain proof for every discontinuity honored on a walk —
  // #55.4: against the CONTIGUOUS-MERGED chain declarations (never the
  // tuple list), see mergeContiguousGaps. Shared by both modes (1788472713:
  // a window's inner jumps and its leading clip meet the same bar). Returns
  // one verdict per pending range for the caller's prose; throws on the
  // first unjustified one.
  const justifyDiscontinuities = () => {
    const declared = mergeContiguousGaps(chainGaps);
    return pendingJustify.map((p) => {
      const inChain = declared.some(([f, t]) => f === p.from && t === p.to);
      const accepted = acceptGaps.some(([f, t]) => Number(f) === p.from && Number(t) === p.to);
      if (!inChain && !accepted) {
        throw new Error(`unjustified discontinuity: ${p.what} — no #gap event or contiguous run of #gap events [${p.from}..${p.to}) is hash-committed in the verified chain`);
      }
      return { from: p.from, to: p.to, inChain };
    });
  };
  // W2-04: certify a visited segment's head — before this, sealed heads were
  // only compared against their own uncertified self-report. Shared by the
  // full walk (every segment, the active included) and the window (its
  // visited SEALED segments; the active head's certificate is the block
  // after the walk, as ever).
  const certifySegment = async (a, aHead) => {
    if (!aHead.certificate.length) {
      if (!isLocalReplicaOrigin()) throw new Error(`archive ${a.canisterId}: no certificate for this segment — an uncertified head proves nothing`);
      return;
    }
    const c = await validateCertifiedHead(aHead.certificate[0], a.canisterId, new Uint8Array(aHead.headHash[0]), rootKey);
    if (c.ok === false) throw new Error(`archive ${a.canisterId}: segment certificate FAILED: ` + c.why);
    // #55.3: a THROWN check comes back as ok === null — and a genuine
    // failure lands exactly there (Certificate.create throws a TrustError
    // on a bad BLS signature, a stale/future time, an unauthorised
    // delegation). Off-local an unknown sealed head is as unproven as a
    // missing one — same origin gate as the empty-certificate arm above,
    // same verdict as the CLI twin (scripts/verify_ledger.mjs). The gate
    // lives HERE, not in the helper: the active head on a local replica
    // still needs null for its "DID NOT RUN" prose (#4).
    if (c.ok !== true && !isLocalReplicaOrigin()) throw new Error(`archive ${a.canisterId}: segment certificate check DID NOT RUN (${c.why}) — a sealed head the subnet did not vouch for proves nothing`);
    if (c.ok === true) segCertsOk++;
  };

  if (lastN) {
    // 1788472713: the window is a CLIPPED FULL WALK. planWindow routes the
    // request [requestedFrom..headSeq] newest-backwards across the routing
    // list (every archive holding tape inside the window is a visited
    // segment, walked from max(firstSeq, requestedFrom)); the loop below is
    // the full walk's own discipline: the hash carried across every
    // boundary, every visited sealed head compared AND certificate-checked,
    // every coverage jump INSIDE the window justified by a chain-declared
    // #gap run (or an operator-accepted legacy gap) exactly as a list jump
    // is. Only the tape below requestedFrom is unverified — by definition
    // of the request. Before this the window CLIPPED at the active
    // archive's firstSeq ("not visited; run the full check"), so right
    // after an archive rotation the newest-500 scope verified a handful of
    // links. The plan is made against the routing list's serve bounds and
    // the chain origin — never against the head's uncertified start claim
    // (#55.6, planWindow below).
    const { requestedFrom, segments } = planWindow(origin, headSeq, lastN, archives, reanchorSeqs);
    unvisitedBelowWindow = segments[0].index;
    let anyJump = false;
    for (const seg of segments) {
      const a = archives[seg.index];
      const isActive = seg.index === archives.length - 1;
      const actor = isActive ? activeActor : await makeRawArchiveActor(a.canisterId);
      const aHead = isActive ? head : await actor.getCertifiedHead();
      // The seed is the expected prevHash of the first walked event (see
      // planWindow): carried from the visited predecessor; the TAPE's own
      // hash of seq from-1 on this archive ("self") or on the contiguous
      // unvisited predecessor ("predecessor" — verifying the cross-archive
      // link too); null at the chain origin, at the window's edge with
      // nothing to bridge, and at a jump (tentatively — justified below).
      let seed = null;
      if (seg.seedOn === "carried") seed = carried;
      else if (seg.seedOn !== null) {
        const seedActor = seg.seedOn === "self" ? actor : await makeRawArchiveActor(archives[seg.index - 1].canisterId);
        const prev = await seedActor.getEventsRange(BigInt(seg.from - 1), 1n);
        if (prev.length && Number(prev[0].seq) === seg.from - 1) seed = await hashEvent(prev[0]);
        else if (seg.seedOn === "predecessor") {
          throw new Error(`sealed archive ${archives[seg.index - 1].canisterId} lists lastSeq ${seg.from - 1} but serves nothing there — the window cannot be bridged to it`);
        } else if (!isActive) {
          throw new Error(`archive ${a.canisterId}: lists seq ${seg.from - 1} but serves nothing there — a sealed segment has no moving tail`);
        }
      }
      if (seg.jump) {
        anyJump = true;
        pendingJustify.push(seg === segments[0]
          ? { from: seg.jump[0], to: seg.jump[1], what: `window clipped at seq ${seg.from}: the routing list claims tape starts inside the requested window [${requestedFrom}..${headSeq}] and no listed sealed archive bridges [${seg.jump[0]}..${seg.jump[1]}) — early tape omitted?` }
          : { from: seg.jump[0], to: seg.jump[1], what: `coverage jumps ${seg.jump[0]}→${seg.jump[1]} between archives ${seg.index}/${seg.index + 1} inside the window` });
      }
      onStatus(`archive ${seg.index + 1}/${archives.length}: verifying seqs ${seg.from}…${seg.to}…${seg.jump ? " (re-anchor claimed)" : ""}`);
      const r = await verifySlice(actor, seg.from, seg.to, seed,
        (done, total) => onStatus(`archive ${seg.index + 1}/${archives.length}: ${done}/${total} events`), chainGaps);
      totalLinks += r.links;
      if (aHead.headHash.length && !bytesEq(r.lastHash, new Uint8Array(aHead.headHash[0]))) {
        throw new Error(isActive ? "recomputed head ≠ archive head — the tape does not match its own hash chain" : `archive ${a.canisterId}: recomputed head ≠ its reported head`);
      }
      if (!isActive) await certifySegment(a, aHead);
      heads++;
      carried = r.lastHash;
    }
    // Every jump inside the window — its leading clip included — must be a
    // chain-declared #gap run (collected on THIS walk: a re-anchor's
    // declarations sit at the segment's start, which a visited segment
    // always covers) or an operator-accepted legacy gap. Otherwise the host
    // has moved its "verification starts here" claim into the routing list
    // (early tape omitted).
    const notes = [];
    for (const v of justifyDiscontinuities()) {
      const how = v.inChain ? "a chain-declared shed (#gap)" : "an operator-accepted legacy gap";
      if (segments[0].jump && v.from === segments[0].jump[0] && v.to === segments[0].jump[1]) {
        notes.push(`window clipped at seq ${segments[0].from} (requested from ${requestedFrom}): [${v.from}..${v.to}) is ${how}`);
      } else {
        notes.push(`[${v.from}..${v.to}) inside the window is ${how}`);
      }
    }
    // #55.6: zero progress is refused — "0 links, head matches" is the tape
    // of one event the host chose to serve. The two honest zero-link shapes
    // are a walk that starts at the chain ORIGIN (a one-event tape) and one
    // that starts at a chain-declared re-anchor whose only event is its own
    // #gap declaration; neither is anything the host merely CLAIMED.
    if (totalLinks === 0 && segments[0].from !== origin && !anyJump) {
      throw new Error(`nothing verifiable: the host certifies a head at seq ${headSeq} but the window walked a single event with no verifiable link`);
    }
    if (segments.length > 1) notes.push(`window spans ${segments.length} of ${archives.length} archives: seqs ${segments[0].from}…${headSeq}, hash carried across ${segments.length - 1} boundar${segments.length > 2 ? "ies" : "y"}`);
    if (segments[0].index > 0) notes.push(`${segments[0].index} older sealed archive${segments[0].index > 1 ? "s hold" : " holds"} tape below seq ${requestedFrom}, outside the window — not visited; run the full check`);
    windowNote = notes.length ? notes.join("; ") : null;
  } else {
    // Full history: every archive in routing order, links carried across
    // canister boundaries, each sealed head checked AND certified too.
    // W2-04: pin the origin — coverage starting later than it is a truncated
    // archive list unless a justified gap explains that range.
    // #55.1: `origin` (above the mode split) defaults to 0, never to the
    // host's chainStartSeq claim; opts.expectStart is the only override.
    if (Number(archives[0].firstSeq) > origin) {
      pendingJustify.push({ from: origin, to: Number(archives[0].firstSeq),
        what: `history starts at seq ${archives[0].firstSeq} but the chain origin is ${origin} — early archives omitted?` });
    }
    for (let i = 0; i < archives.length; i++) {
      const a = archives[i];
      const actor = i === archives.length - 1 ? activeActor : await makeRawArchiveActor(a.canisterId);
      const aHead = i === archives.length - 1 ? head : await actor.getCertifiedHead();
      const from = Number(a.firstSeq);
      const to = a.lastSeq.length ? Number(a.lastSeq[0]) : headSeq;
      lastTo = to;
      // W2-04: a clipped first-archive start and any coverage jump between
      // archives are unverified tape — both demand a chain-visible gap.
      const clipTo = i === 0 ? chainStartOf(aHead, from) : from;
      if (i === 0 && clipTo > from) {
        pendingJustify.push({ from, to: clipTo, what: `archive 1 re-anchors its own start at ${clipTo}` });
      }
      // H-18 (F21): every predecessor is SEALED by construction now
      // (validateArchiveList refused the list otherwise), so neither the
      // coverage check nor the re-anchor justification is guarded on its
      // shape any more — a nulled seed at i > 0 ALWAYS pushes a range to
      // justify.
      if (i > 0) {
        const prevLast = Number(archives[i - 1].lastSeq[0]);
        if (from !== prevLast + 1) {
          pendingJustify.push({ from: prevLast + 1, to: from,
            what: `coverage jumps ${prevLast + 1}→${from} between archives ${i}/${i + 1}` });
        }
      }
      // Re-anchor after a CLAIMED gap: seed null so the walk accepts the
      // discontinuity — tentatively. The claim is proven after the walk by a
      // #gap event committed in the chain, or the whole run fails: a
      // fabricated tuple at a continuous boundary would need a #gap event
      // for an empty range, which the honest shed path never emits.
      // #55 (1788468754): in season mode a list jump after a sealed
      // predecessor is ALSO the re-anchor CLAIM itself — honored exactly as
      // tentatively (seed null, chain proof demanded below): an omitted
      // segment still fails. 1788474114: reanchorSeqs carries the season's
      // preserved tuples too; the inference stays for seasons closed before
      // they were preserved — the chain's #gap events are the only proof.
      const reanchored = i > 0 && (reanchorSeqs.has(from)
        || (season !== null && from !== Number(archives[i - 1].lastSeq[0]) + 1));
      if (reanchored) {
        pendingJustify.push({ from: Number(archives[i - 1].lastSeq[0]) + 1, to: from,
          what: `re-anchor claimed at archive ${i + 1} firstSeq ${from}` });
      }
      const seed = reanchored ? null : carried;
      onStatus(`archive ${i + 1}/${archives.length}: verifying seqs ${from}…${to}…${reanchored ? " (re-anchor claimed)" : ""}`);
      const r = await verifySlice(actor, Math.max(from, clipTo), to, seed,
        (done, total) => onStatus(`archive ${i + 1}/${archives.length}: ${done}/${total} events`), chainGaps);
      totalLinks += r.links;
      if (aHead.headHash.length && !bytesEq(r.lastHash, new Uint8Array(aHead.headHash[0]))) {
        throw new Error(`archive ${a.canisterId}: recomputed head ≠ its reported head`);
      }
      // W2-04: certify THIS segment's head (certifySegment, above).
      await certifySegment(a, aHead);
      heads++;
      carried = r.lastHash;
    }
    // W2-04 / #55.4: prove every discontinuity honored above by the chain's
    // own contiguous-merged declarations (justifyDiscontinuities, above).
    justifyDiscontinuities();
    // #55 (1788468754): the SECOND anchor for a sealed season — the head the
    // boundary committed into the SeasonRecord, and the extent it recorded.
    if (seasonRec) {
      const recHead = new Uint8Array(seasonRec.chainHead[0]);
      if (carried === null || !bytesEq(carried, recHead)) {
        throw new Error(`season ${season}: walked head ${carried ? hex(carried, 8) : "none"} ≠ the SeasonRecord's chainHead ${hex(recHead, 8)} — the sealed chain does not end where the boundary committed`);
      }
      const finalSeq = Number(seasonRec.finalEventSeq);
      if (lastTo + 1 !== finalSeq) {
        throw new Error(`season ${season}: the walked tape ends at seq ${lastTo} but the SeasonRecord's finalEventSeq is ${finalSeq} (its last event should be seq ${finalSeq - 1})`);
      }
      seasonNote = `season ${season} anchored: walked head == SeasonRecord.chainHead ${hex(recHead, 8)}, last seq ${lastTo} == finalEventSeq ${finalSeq} - 1`;
    }
  }

  // The head itself: validate the IC certificate over certified_data.
  //
  // THREE outcomes, and only one of them is "verified". `ok === null` means the
  // check did not run (no certificate in the response, or the SDK threw) — an
  // absence of evidence, which for years was rendered as evidence of absence of
  // tampering. The caller gets `certOk` as a hard boolean so it cannot paint a
  // verified state on an unknown; `certNote` is only the prose.
  let certNote;
  const certCheck = head.certificate.length
    ? await validateCertifiedHead(head.certificate[0], active.canisterId, new Uint8Array(head.headHash[0]), rootKey)
    : { ok: null, why: "no certificate in the query response" };
  // W2-04 verdict copy: say what was proven. The active certificate vouches
  // for the ACTIVE archive's head; sealed segments are vouched only by their
  // own per-segment certificates (counted in segCertsOk — every segment in
  // a full walk, the active included; the visited SEALED ones in a window
  // check, 1788472713). Sealed-segment immutability is absolute only with
  // blackhole-at-seal in force — see docs/archive-design.md.
  if (certCheck.ok === true) {
    certNote = lastN
      ? `IC certificate VALID — the subnet vouches for the ACTIVE archive's head${segCertsOk > 0 ? `; ${segCertsOk} sealed segment(s) inside the window certificate-validated` : ""}${unvisitedBelowWindow > 0 ? ` (${unvisitedBelowWindow} older sealed segment(s) below the window not visited)` : ""}`
      : `IC certificate VALID — the subnet vouches for ${season !== null ? `sealed season ${season}'s tip head` : "the active head"}${segCertsOk > 1 ? `; ${segCertsOk - 1} sealed segment(s) certificate-validated` : ""}`;
  }
  else if (certCheck.ok === false) throw new Error("IC certificate check FAILED: " + certCheck.why);
  else certNote = "certificate check DID NOT RUN (" + certCheck.why + ") — the head is only the canister's own claim";

  return { links: totalLinks, headSeq, headHex: hex(new Uint8Array(head.headHash[0]), 8), certNote, heads,
    certOk: certCheck.ok === true, certLocal: isLocalReplicaOrigin(), segCertsOk,
    chainGapCount: chainGaps.length, windowNote, seasonNote,
    gapCount: gaps.length, gapEventsMissing, baselineCount: baselines.length,
    baselineResumeSeq: baselines.length ? Number(baselines[baselines.length - 1][1]) : null };
}
function chainStartOf(head, fallback) {
  return head.chainStartSeq && head.chainStartSeq.length ? Number(head.chainStartSeq[0]) : fallback;
}
// H-18 (F21): the SHAPE of a served routing list, checked before any walk.
// getArchives (and a season table once its never-written successor is
// dropped) is sealed rows in seq order followed by at most ONE open row —
// the active archive, always last: the backend appends exactly one lastSeq-
// null entry. So a non-final row with lastSeq null, ranges that are not
// strictly ascending (a row starting at or below its predecessor's lastSeq),
// or an inverted row (lastSeq < firstSeq) is a shape the backend cannot emit
// — a host serving one is lying about its own topology, and the walk must
// not begin: an open non-final row would make the tentative re-anchor after
// it final with no predecessor end to justify it against, and an overlap
// would let one seq be "verified" by two different segments. Body kept
// byte-identical in scripts/verify_ledger.mjs
// (tests/verify_chain_client.test.mjs holds the two together).
export function validateArchiveList(archives) {
  for (let i = 0; i < archives.length; i++) {
    const a = archives[i];
    const first = Number(a.firstSeq);
    const last = a.lastSeq.length ? Number(a.lastSeq[0]) : null;
    if (last === null && i !== archives.length - 1) {
      throw new Error(`routing list malformed: archive ${i + 1}/${archives.length} ${a.canisterId} is open (lastSeq null) but is not the last entry — only the active archive is unsealed`);
    }
    if (last !== null && last < first) {
      throw new Error(`routing list malformed: archive ${i + 1}/${archives.length} ${a.canisterId} is inverted (firstSeq ${first} > lastSeq ${last})`);
    }
    if (i > 0 && first <= Number(archives[i - 1].lastSeq[0])) {
      throw new Error(`routing list malformed: ranges are not strictly ascending — archive ${i + 1}/${archives.length} ${a.canisterId} starts at seq ${first} but archive ${i} ends at seq ${archives[i - 1].lastSeq[0]}`);
    }
  }
}
// #55.4: a pending range is justified by the chain's OWN declarations — and a
// shed whose successor spawn is still blocked (10-min backoff) declares ITS
// range on the chain while the archive list gains no entry: an archive that
// acked nothing is ABANDONED at the next seal, not sealed. So back-to-back
// sheds leave ONE list jump [a..c) under TWO chain declarations [a..b), [b..c).
// Merge declarations that are exactly contiguous (t_i === f_{i+1}), then demand
// an EXACT match against the merged list: a hole or an overlap is never merged,
// so a superset, a fabricated tuple, or a declaration riding a legitimate
// neighbour still refuses. Only #gap events collected on the verified walk are
// merged — never getLedgerGaps tuples, which the shed already coalesces and
// which prove nothing. Body kept byte-identical in scripts/verify_ledger.mjs
// (tests/verify_chain_client.test.mjs holds the two together).
export function mergeContiguousGaps(list) {
  const sorted = list.map(([f, t]) => [f, t]).sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  const out = [];
  for (const [f, t] of sorted) {
    const last = out[out.length - 1];
    if (last && last[1] === f) last[1] = t; else out.push([f, t]);
  }
  return out;
}
// #55.6 / 1788472713 (window mode): plan the walk over the newest `lastN`
// events as a CLIPPED FULL WALK. The requested window is
// [requestedFrom .. headSeq] with requestedFrom = max(origin, headSeq-lastN+1);
// the routing list is walked NEWEST BACKWARDS and every archive holding tape
// at or above requestedFrom is a visited segment, walked from
// max(firstSeq, requestedFrom) to its lastSeq (the certified headSeq for the
// open row). Bounds come from the routing list's SERVE bounds (uncertified
// too, but they bound what each actor can physically RETURN) and the chain
// origin — NEVER from head.chainStartSeq, the host's uncertified claim about
// where verification may STOP (taking it once shrank the window to one
// event, zero links, a trivially matching hash — the #37.1 shape). Per
// segment: `seedOn` says where the expected prevHash of its first walked
// event comes from — "carried" (the visited predecessor's walked hash),
// "self" (the tape's own hash of from-1 on this archive: the window starts
// inside it), "predecessor" (the window starts exactly at this archive's
// boundary and the UNVISITED predecessor is contiguous — its last event
// bridges, verifying the cross-archive link), or null (the chain origin; the
// window's edge with nothing to bridge; a coverage jump). `jump` is the
// range [a..firstSeq) the caller must find declared on the chain (a
// contiguous run of #gap events — exactly what the full walk demands of a
// list jump) or refuse: a boundary INSIDE the window that is not contiguous,
// or one a getLedgerGaps tuple claims as a re-anchor (an empty [f..f) then,
// which no honest chain declares — the tuple lie is refused as in --full).
// The oldest visited segment's jump is the window's leading CLIP. Tape below
// requestedFrom is unverified by definition. Body kept byte-identical in
// both verifiers (tests/verify_chain_client.test.mjs holds the two together).
export function planWindow(origin, headSeq, lastN, archives, reanchors) {
  const requestedFrom = Math.max(origin, headSeq - lastN + 1);
  const segments = [];
  for (let i = archives.length - 1; i >= 0; i--) {
    const a = archives[i];
    const first = Number(a.firstSeq);
    const to = a.lastSeq.length ? Number(a.lastSeq[0]) : headSeq;
    if (to < requestedFrom) break;
    const from = Math.max(first, requestedFrom);
    if (from > to) throw new Error(`window start ${from} is beyond the certified head at seq ${headSeq} — the routing list claims tape the head does not cover`);
    const prevLast = i > 0 ? Number(archives[i - 1].lastSeq[0]) : null;
    let seedOn = null;
    let jump = null;
    if (from === origin) seedOn = null;
    else if (from > first) seedOn = "self";
    else if (first === requestedFrom) seedOn = prevLast === first - 1 ? "predecessor" : null;
    else {
      const jumpFrom = prevLast !== null ? prevLast + 1 : origin;
      if (jumpFrom < first || reanchors.has(first)) jump = [jumpFrom, first];
      else seedOn = "carried";
    }
    segments.unshift({ index: i, first, from, to, seedOn, jump });
  }
  if (!segments.length) throw new Error(`window start ${requestedFrom} is beyond the certified head at seq ${headSeq}`);
  return { requestedFrom, segments };
}

// ── Rendering (the Ledger view) ──────────────────────────────────────
const fmtAmt = (v) => {
  const n = Number(v) / 1e8;
  return (n >= 0 ? "+" : "") + n.toLocaleString(undefined, { maximumFractionDigits: 4 });
};
const shortP = (p) => { const t = typeof p === "string" ? p : p.toText(); return t.slice(0, 5) + "…" + t.slice(-3); };
const escH = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// Exported for tests/frontend_display_integrity.test.mjs §L (behavioural pin
// on the #config row); the page itself only calls it from the tape render.
export function kindCell(e) {
  const k = e.kind;
  if ("delta" in k) return ["ledger Δ", `${fmtAmt(k.delta.amount)} ${escH(k.delta.token)}`];
  if ("debtDelta" in k) return ["debt Δ", `${fmtAmt(k.debtDelta.amount)} ${escH(k.debtDelta.token)} owed to vault`];
  if ("lpShareDelta" in k) return ["LP Δ", `${fmtAmt(k.lpShareDelta.amount)} vault shares`];
  if ("insShareDelta" in k) return ["insurance Δ", `${fmtAmt(k.insShareDelta.amount)} shares`];
  if ("gap" in k) return ["ledger gap", `seqs ${k.gap.fromSeq}…${k.gap.toSeq} dropped by L2 failover (chain-declared)`];
  // #config (#55 round 18, "config row blank"): the admin setters — setBridge,
  // setArbitrageur, setFuelRoute, setAutoFuel, setXrcCanister,
  // setBlackholeAtSeal, ... — emit { setter; value } onto the tape. Both are
  // backend-authored Text but a principal or route string still goes through
  // escH: the tape is innerHTML and the archive replays it verbatim.
  if ("config" in k) return ["config", `${escH(k.config.setter)} → ${escH(k.config.value)}`];
  if ("fill" in k) { const f = k.fill; return ["fill", `${sideTag(f.side)} ${Number(f.qty) / 1e8} ${escH(f.marketId)} @ ${Number(f.price) / 1e8}`]; }
  if ("deposit" in k) { const d = k.deposit; return ["withdrawal" in d.kind ? "withdrawal" : "deposit", `${Number(d.amount) / 1e8} ${escH(d.token)}`]; }
  if ("orderClosed" in k) return ["order", "closed"];
  if ("liquidation" in k) return ["liquidation", "collateral seized"];
  if ("lpDeposit" in k) return ["LP deposit", `${Number(k.lpDeposit.lpMinted) / 1e8} shares minted`];
  if ("lpWithdraw" in k) return ["LP withdraw", `${Number(k.lpWithdraw.lpBurned) / 1e8} shares burned`];
  if ("insuranceStake" in k) return ["insurance", "stake"];
  if ("insuranceUnstake" in k) return ["insurance", "unstake"];
  if ("borrow" in k) return ["borrow", `${Number(k.borrow.amount) / 1e8} ${escH(k.borrow.token)}`];
  if ("repay" in k) return ["repay", `${Number(k.repay.amount) / 1e8} ${escH(k.repay.token)}`];
  return ["event", ""];
}

// Hash chip with a colour derived from the hash bytes — matching colours ARE
// the visual chain: a row's own-hash chip matches the row above's prev chip.
function chip(bytes, label) {
  if (!bytes || !bytes.length) return `<span class="lg-chip lg-chip-null">${label}·∅</span>`;
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const hue = ((b[0] << 8) | b[1]) % 360;
  return `<span class="lg-chip" style="border-color:hsl(${hue},70%,45%);color:hsl(${hue},80%,70%)">${label}·${hex(b, 4)}</span>`;
}

// The verify-scope picker's value → verifyChainClient opts (1788474115). This
// is the ONE place the page mints verifier options: "season:N" walks a CLOSED
// season in full — `{ season: N }` alone, never with a lastN beside it (the
// verifier refuses the pair; a sealed tape is finite and every segment's
// certificate is the point); "full" is the whole live chain; anything else
// is a newest-N window, defaulting to 500 like the picker's first option.
export function verifyScopeOpts(scope) {
  const m = /^season:(\d+)$/.exec(scope || "");
  if (m) return { season: parseInt(m[1], 10) };
  if (scope === "full") return {};
  const n = parseInt(scope, 10);
  return { lastN: Number.isFinite(n) && n > 0 ? n : 500 };
}

// One picker label per SeasonRecord. A season that closed with no tape
// (finalEventSeq 0, chainHead null) is LISTED and labelled rather than
// hidden: the verifier refuses to vouch for it (nothing anchors a sealed
// chain), and that refusal is the honest verdict a player should be able
// to reach from the picker — silence would read as "never existed".
// 1788477403: `wiped` marks a season whose verify already reported an empty
// season table (its archives deleted by a #dev/#play resetExchange, the
// record kept). The page learns it from the verify verdict — NOT by probing
// listSeasonArchives per record on every refresh, which would cost one
// query per season forever — so the label costs nothing extra.
export function seasonOptionLabel(rec, wiped) {
  const s = Number(rec.season);
  if (wiped) return `Verify season ${s} (sealed — archives wiped)`;
  const finalSeq = Number(rec.finalEventSeq);
  return finalSeq > 0 && rec.chainHead && rec.chainHead.length
    ? `Verify season ${s} (sealed, ends seq ${(finalSeq - 1).toLocaleString()})`
    : `Verify season ${s} (sealed with no tape — unverifiable)`;
}

export function setupLedger(deps) {
  const pane = document.getElementById("ledger-view");
  if (!pane) return null;
  let loaded = false;
  document.getElementById("lg-refresh")?.addEventListener("click", () => { pageEnd = null; refresh(); });
  document.getElementById("lg-verify")?.addEventListener("click", verify);
  document.getElementById("lg-older")?.addEventListener("click", () => { if (windowStart !== null) { pageEnd = windowStart - 1; loadTape(); } });
  document.getElementById("lg-newer")?.addEventListener("click", () => { if (pageEnd !== null) { pageEnd = pageEnd + PAGE; loadTape(); } });
  document.getElementById("lg-newest")?.addEventListener("click", () => { pageEnd = null; loadTape(); });

  // 1788474115: the verify-scope picker lists every sealed season below the
  // window/full options (newest first), each option carrying `season:N` for
  // verifyScopeOpts. Options are tagged so a Refresh re-lists without
  // duplicating; the current choice survives when it still exists. Never
  // throws — a pre-season backend (no getSeasonRecords) simply lists none.
  // 1788477403: seasons a verify has already found wiped (empty season table
  // under a committed record) — refreshSeasonPicker relabels them from here.
  const wipedSeasons = new Set();
  async function refreshSeasonPicker() {
    const sel = document.getElementById("lg-verify-scope");
    if (!sel || !deps.getSeasonRecords) return;
    let recs;
    try { recs = await deps.getSeasonRecords(); } catch { return; }
    const keep = sel.value;
    for (const o of [...sel.querySelectorAll("option[data-season]")]) o.remove();
    const sorted = [...recs].sort((a, b) => Number(b.season) - Number(a.season));
    for (const r of sorted) {
      const o = document.createElement("option");
      o.value = `season:${Number(r.season)}`;
      o.dataset.season = String(Number(r.season));
      o.textContent = seasonOptionLabel(r, wipedSeasons.has(Number(r.season)));
      sel.appendChild(o);
    }
    if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
  }

  async function refresh() {
    const chainEl = document.getElementById("lg-chain");
    const tapeEl = document.getElementById("lg-tape");
    try {
      await refreshSeasonPicker();
      const archives = await deps.listArchives();
      if (!archives.length) {
        chainEl.innerHTML = `<div class="empty-state">No archive yet — the ledger begins with the first event.</div>`;
        tapeEl.innerHTML = "";
        return;
      }
      // Chain table: one row per archive, its range + certified head.
      const rows = [];
      for (const a of archives) {
        const actor = await deps.makeRawArchiveActor(a.canisterId);
        let headHex8 = "—", anchor = "—", count = "—";
        try {
          const h = await actor.getCertifiedHead();
          if (h.headHash.length) headHex8 = hex(new Uint8Array(h.headHash[0]), 8);
          if (h.chainStartSeq.length) anchor = String(h.chainStartSeq[0]);
          const st = await actor.stats();
          count = Number(st.eventCount).toLocaleString();
        } catch {}
        const sealed = a.lastSeq.length;
        rows.push(`<tr>
          <td><code>${escH(a.canisterId)}</code></td>
          <td>${a.firstSeq}…${sealed ? a.lastSeq[0] : "live"}</td>
          <td>${count}</td>
          <td><code>${headHex8}</code></td>
          <td><span class="lg-badge ${sealed ? "lg-sealed" : "lg-active"}">${sealed ? "sealed" : "active"}</span></td>
        </tr>`);
      }
      chainEl.innerHTML = `<table class="positions-table"><thead><tr>
        <th>Archive canister</th><th>Seq range</th><th>Events</th><th>Certified head</th><th></th>
      </tr></thead><tbody>${rows.join("")}</tbody></table>`;

      _archList = archives;
      await loadTape();
    } catch (err) {
      chainEl.innerHTML = `<div class="empty-state">Ledger unavailable: ${escH(err && err.message ? err.message : err)}</div>`;
    }
  }

  // ── Tape pagination ────────────────────────────────────────────────
  // A window of PAGE events ending at `pageEnd` (null = follow the newest).
  // Windows are SEQ-addressed and ROUTED: a window that crosses a seal
  // boundary fetches from both archives, so paging back walks seamlessly
  // into blackholed history.
  const PAGE = 30;
  let pageEnd = null;
  let windowStart = null;
  let _archList = [];

  async function fetchRouted(from, count) {
    const out = [];
    for (const a of _archList) {
      const aFirst = Number(a.firstSeq);
      const aLast = a.lastSeq.length ? Number(a.lastSeq[0]) : Infinity;
      const lo = Math.max(from, aFirst);
      const hi = Math.min(from + count - 1, aLast);
      if (lo > hi) continue;
      const actor = await deps.makeRawArchiveActor(a.canisterId);
      const page = await actor.getEventsRange(BigInt(lo), BigInt(hi - lo + 1));
      out.push(...page);
    }
    return out;
  }

  async function loadTape() {
    const tapeEl = document.getElementById("lg-tape");
    if (!_archList.length) { tapeEl.innerHTML = ""; return; }
    try {
      const active = _archList[_archList.length - 1];
      const actor = await deps.makeRawArchiveActor(active.canisterId);
      const st = await actor.stats();
      const newestSeq = Number(st.nextSeq) - 1;
      const chainFirst = Number(_archList[0].firstSeq);
      let end = pageEnd === null ? newestSeq : Math.min(pageEnd, newestSeq);
      if (pageEnd !== null && end >= newestSeq) { pageEnd = null; end = newestSeq; }   // paged past the head → follow it
      const start = Math.max(chainFirst, end - PAGE + 1);
      windowStart = start;
      const events = end >= start ? await fetchRouted(start, end - start + 1) : [];
      const withHashes = [];
      for (const e of events) withHashes.push({ e, own: await hashEvent(e) });
      withHashes.reverse();   // newest first
      const trows = withHashes.map(({ e, own }, i) => {
        const [tag, detail] = kindCell(e);
        const prev = optBytes(e.prevHash);
        // Link check against the row BELOW (the previous event).
        const below = withHashes[i + 1];
        const linked = below ? bytesEq(prev, below.own) : null;
        return `<tr>
          <td>${e.seq}</td>
          <td class="lg-time">${new Date(Number(e.ts) / 1e6).toLocaleTimeString()}</td>
          <td><span class="lg-kind">${tag}</span></td>
          <td><code>${shortP(e.user)}</code></td>
          <td class="lg-detail">${detail}</td>
          <td class="lg-hashes">${chip(prev, "prev")}${linked === false ? "⚠" : ""} ${chip(own, "hash")}</td>
        </tr>`;
      }).join("");
      tapeEl.innerHTML = `<table class="positions-table lg-tape-table"><thead><tr>
        <th>Seq</th><th>Time</th><th>Kind</th><th>Account</th><th>Detail</th><th>Chain link (prev ← hash)</th>
      </tr></thead><tbody>${trows}</tbody></table>
      <div class="lg-note">Hashes are recomputed in YOUR browser from the event bytes — each row's
      <em>hash</em> chip reappears as the row above's <em>prev</em> chip. Matching colours are the chain.</div>`;
      // Pager chrome: range label + button states.
      const lbl = document.getElementById("lg-range");
      if (lbl) lbl.textContent = end >= start
        ? `seqs ${start.toLocaleString()}–${end.toLocaleString()} of ${newestSeq.toLocaleString()}${pageEnd === null ? " (live)" : ""}`
        : "empty";
      const older = document.getElementById("lg-older");
      const newer = document.getElementById("lg-newer");
      const newest = document.getElementById("lg-newest");
      if (older) older.disabled = start <= chainFirst;
      if (newer) newer.disabled = pageEnd === null;
      if (newest) newest.disabled = pageEnd === null;
    } catch (err) {
      tapeEl.innerHTML = `<div class="empty-state">Tape unavailable: ${escH(err && err.message ? err.message : err)}</div>`;
    }
  }

  async function verify() {
    const btn = document.getElementById("lg-verify");
    const out = document.getElementById("lg-verify-result");
    const scope = document.getElementById("lg-verify-scope")?.value || "500";
    btn.disabled = true;
    out.className = "lg-verify-out";
    // 1788474115: the picker value maps through verifyScopeOpts — a
    // `season:N` choice reaches the verifier as { season: N } untouched.
    const opts = verifyScopeOpts(scope);
    const seasonN = Number.isInteger(opts.season) ? opts.season : null;
    try {
      const res = await verifyChainClient(
        deps,
        opts,
        (msg) => { out.textContent = msg; },
      );
      // FAIL CLOSED. Green (`lg-ok`, "✓ … verified") is reserved for a
      // certificate that actually validated against the IC root key. Anything
      // else — no certificate in the response, an SDK that threw, a host whose
      // root key we refuse to trust — is a materially weaker claim: the tape
      // agrees with ITSELF, and nothing more. A canister serving a fabricated
      // tape with `certificate = []` is internally consistent by construction,
      // so painting that green is exactly the reassurance an attacker wants.
      out.className = res.certOk ? "lg-verify-out lg-ok" : "lg-verify-out lg-warn";
      // W2-04: a full walk THROWS on any gap that is not justified by a #gap
      // event hash-committed in the chain — so gaps surviving to this render
      // are chain-declared, and the copy may say so. (A window check never
      // walks them; it keeps the weaker "recorded" wording.)
      const gapWord = res.chainGapCount ? "chain-declared" : "recorded";
      const gapNote = res.gapCount
        ? (res.baselineCount
          ? ` <br><span class="lg-gap-note">⚠ across ${res.gapCount} ${gapWord} ledger gap${res.gapCount > 1 ? "s" : ""}
              (${res.gapEventsMissing.toLocaleString()} events dropped by archive-failover — ${res.chainGapCount ? "declared on the chain itself, hash-committed — " : "documented, "}not tampering).
              The tape re-baselined itself after the shed${res.baselineCount > 1 ? "s" : ""}: every balance was re-attested
              with absolute rows, so replay reconstructs balances exactly from seq ${res.baselineResumeSeq.toLocaleString()}
              onward — only the dropped history itself is gone.</span>`
          : ` <br><span class="lg-gap-note">⚠ across ${res.gapCount} recorded ledger gap${res.gapCount > 1 ? "s" : ""}
              (${res.gapEventsMissing.toLocaleString()} events dropped by archive-failover — documented, not tampering;
              live balances intact, but the tape can't reconstruct through a gap unaided).</span>`)
        : "";
      // A sealed season is named as such in the prose — "the archive" is the
      // live chain's; here the head is the season's tip at the boundary.
      const subject = seasonN !== null
        ? `sealed season ${seasonN}'s archive${res.heads > 1 ? `s (${res.heads} heads)` : ""}`
        : `the archive${res.heads > 1 ? `s (${res.heads} heads)` : ""}`;
      const chainPart = `<strong>${res.links.toLocaleString()} chain links</strong> recomputed in your browser up to seq ${res.headSeq}
        — head <code>${res.headHex}</code> matches ${subject}${
        res.windowNote ? ` <span class="lg-gap-note">(${escH(res.windowNote)})</span>` : ""}${
        res.seasonNote ? ` <span class="lg-gap-note">(${escH(res.seasonNote)})</span>` : ""}`;
      out.innerHTML = res.certOk
        ? `✓ ${chainPart}. ${escH(res.certNote)}.${gapNote}`
        // Distinct, non-green state. Says what WAS established and what was
        // not, in those words — self-consistency is not certification.
        : `⚠ <strong>Chain self-consistent, certificate NOT verified.</strong> ${chainPart},
           but that head is the canister's own claim: ${escH(res.certNote)}.
           ${res.certLocal
             ? `<span class="lg-gap-note">(Expected on a local development replica — its certificates are synthetic.
                On the deployed app this state means the subnet's signature was never checked.)</span>`
             : `<span class="lg-gap-note">A tape fabricated wholesale is self-consistent by construction,
                so this result does NOT rule out tampering. Re-run against the ledger with
                <code>scripts/verify_ledger.mjs</code>, which anchors on the built-in IC root key.</span>`}${gapNote}`;
    } catch (err) {
      out.className = "lg-verify-out lg-bad";
      out.textContent = "✗ VERIFICATION FAILED: " + (err && err.message ? err.message : err);
      // 1788477403: a wiped season (empty season table, record kept) is now
      // known to the page — relabel its picker option in place, and remember
      // it so the next refreshSeasonPicker keeps the label.
      if (seasonN !== null && err && /none is routed any more/.test(err.message || "")) {
        wipedSeasons.add(seasonN);
        const o = document.querySelector(`#lg-verify-scope option[data-season="${seasonN}"]`);
        if (o) o.textContent = seasonOptionLabel({ season: seasonN }, true);
      }
    } finally {
      btn.disabled = false;
    }
  }

  // main.js calls this when the Ledger view activates — the first show loads
  // the chain + tape; after that the user drives refreshes explicitly.
  return { onShow() { if (!loaded) { loaded = true; refresh(); } } };
}
