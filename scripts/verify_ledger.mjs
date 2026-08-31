#!/usr/bin/env node
// MULTI/DEX standalone ledger verifier — trust nothing, recompute everything.
//
// This file is deliberately SELF-CONTAINED: the canonical event form and the
// chain walk are re-implemented inline (not imported from the DEX frontend),
// so an auditor can read this one file top to bottom and run it against any
// deployment. Its only dependency is the IC agent library for candid
// decoding and certificate validation:
//
//   npm i @icp-sdk/core        (already present in this repo's node_modules)
//
// Usage:
//   node scripts/verify_ledger.mjs --backend <canister-id> [--host <url>]
//                                  [--last <n> | --full] [--fold]
//
//   --host     gateway URL (default http://127.0.0.1:8000; mainnet:
//              https://icp-api.io)
//   --insecure-root-key
//              trust the root key SERVED BY --host instead of the built-in IC
//              one. Only for a non-standard test network. With this flag the
//              certificate check proves nothing against a hostile host, and
//              the verifier says so on stderr.
//   --last N   verify only the newest N events on the active archive
//   --full     verify the ENTIRE history across every archive (default)
//   --expect-start N
//              pin the chain origin externally (default: the ACTIVE head's own
//              chainStartSeq claim). History starting later than this fails
//              unless a chain-declared gap explains it — the out-of-band
//              anchor that makes "omit the early archives" refusable.
//   --accept-gap FROM:TO   (repeatable)
//              accept ONE discontinuity that has no #gap event in the chain —
//              for operator-audited legacy gaps recorded before gaps were
//              chain-declared. Anything else: a re-anchor is honored only if
//              a #gap event with that exact range is hash-committed in the
//              chain being verified. getLedgerGaps alone proves nothing — it
//              is an uncertified self-report by the party under audit.
//   --max-tail-skew N
//              how many events below the certified head the ACTIVE tape may
//              stop short (query replicas lag the certified state a little).
//              Default 200 (one page). Beyond it the run FAILS: a host
//              serving a genuine certificate while answering [] for the tape
//              is hiding what it certifies (#37.1).
//   --fold     additionally fold every #delta row into per-account balances
//              and print per-token liability totals — the Proof-of-Reserves
//              liabilities computation, from the public tape alone
//
// What it checks:
//   1. every event's SHA-256 (over the frozen v1 canonical form below)
//      equals the NEXT event's prevHash — one unbroken chain, including
//      across sealed archive canisters;
//   2. each archive's recomputed head equals its certified head;
//   3. the active head's IC certificate (subnet BLS signature over
//      certified_data) validates against the network root key.
// Exit code 0 = everything verified; 1 = ANY check failed.

import { createHash } from "node:crypto";

// ── CLI ──────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf("--" + name);
  return i >= 0 ? (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true) : null;
};
const HOST = flag("host") || "http://127.0.0.1:8000";
const BACKEND = flag("backend");
const LAST = flag("last") ? parseInt(flag("last"), 10) : null;
// #37.1 — bound on the active-tail concession, in events (default one page).
const MAX_TAIL_SKEW = flag("max-tail-skew") ? parseInt(flag("max-tail-skew"), 10) : 200;
const FOLD = !!flag("fold");
const INSECURE_ROOT_KEY = !!flag("insecure-root-key");
if (!BACKEND) {
  console.error("usage: verify_ledger.mjs --backend <canister-id> [--host <url>] [--last N|--full] [--fold]");
  process.exit(2);
}
// A development replica mints its own root key, so it must be fetched; any
// other host is treated as untrusted and validated against the built-in IC
// root key. Matching on the HOSTNAME (not a substring of the URL) so that
// e.g. https://localhost.evil.example/ is NOT mistaken for a local replica.
const LOCAL_HOST = (() => {
  let h;
  try { h = new URL(HOST).hostname; } catch { return false; }
  return h === "localhost" || h === "127.0.0.1" || h === "::1" || h === "[::1]"
      || h.endsWith(".localhost");
})();

// ── Candid interfaces (verifier surface only) ────────────────────────
const { HttpAgent, Actor, Certificate } = await import("@icp-sdk/core/agent");
const { IDL } = await import("@icp-sdk/core/candid");
const { Principal } = await import("@icp-sdk/core/principal");

const backendIdl = ({ IDL }) =>
  IDL.Service({
    getArchives: IDL.Func([], [IDL.Vec(IDL.Record({
      canisterId: IDL.Text, firstSeq: IDL.Nat, lastSeq: IDL.Opt(IDL.Nat),
    }))], ["query"]),
    // Wired arbitrage canister, if any — used only to ATTRIBUTE external
    // flows in the --fold report (its deposits/withdrawals are venue-minted
    // synthetic supply, not custody-backed; see docs/amm-vault-design.md).
    getArbitrageur: IDL.Func([], [IDL.Opt(IDL.Principal)], ["query"]),
    // Recorded gaps in the durable tape (L2 archive-failover sheds): a seq
    // range that was DROPPED to keep the exchange alive when archival was down
    // (docs/archive-design.md §8b). Each is (fromSeq, toSeqExcl, ts). A gap is
    // an EXPECTED cross-archive discontinuity — the events after it re-anchor a
    // fresh archive — so the chain walk consults this to tell a documented gap
    // apart from tampering. Custody/PoR is unaffected (only observability drops).
    getLedgerGaps: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat, IDL.Int))], ["query"]),
    // Shed re-baselines: after every L2 shed the canister reopens the tape
    // with one absolute re-attestation row per live ledger entry (balances,
    // debt, LP shares, insurance shares). Each entry is that snapshot's seq
    // range [fromSeq, toSeqExcl). Fold contract: ZERO the accumulation when
    // reaching fromSeq, then fold on — from toSeqExcl onward the fold again
    // equals live state exactly, from the public tape alone.
    getShedBaselines: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat))], ["query"]),
  });

const archiveIdl = ({ IDL }) => {
  const Side = IDL.Variant({ buy: IDL.Null, sell: IDL.Null });
  const UserEventKind = IDL.Variant({
    fill: IDL.Record({ marketId: IDL.Text, side: Side, price: IDL.Nat, qty: IDL.Nat, orderId: IDL.Nat, tradeId: IDL.Nat }),
    deposit: IDL.Record({ token: IDL.Text, amount: IDL.Nat, timestamp: IDL.Int, kind: IDL.Variant({ deposit: IDL.Null, withdrawal: IDL.Null }) }),
    orderClosed: IDL.Record({ id: IDL.Nat, marketId: IDL.Text, side: Side, orderType: IDL.Variant({ market: IDL.Null, limit: IDL.Null }), price: IDL.Nat, quantity: IDL.Nat, filled: IDL.Nat, status: IDL.Variant({ open: IDL.Null, partiallyFilled: IDL.Null, filled: IDL.Null, cancelled: IDL.Null }), placedAt: IDL.Int, closedAt: IDL.Int }),
    liquidation: IDL.Record({ user: IDL.Principal, debtToken: IDL.Text, debtRepaid: IDL.Nat, debtRepaidUsd: IDL.Nat, collateralToken: IDL.Text, collateralSeized: IDL.Nat, proceedsUsd: IDL.Nat, penaltyUsd: IDL.Nat, healthBefore: IDL.Nat, healthAfter: IDL.Nat, timestamp: IDL.Int }),
    borrow: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
    repay: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
    lpDeposit: IDL.Record({ marketId: IDL.Text, baseAmount: IDL.Nat, quoteAmount: IDL.Nat, lpMinted: IDL.Nat }),
    lpWithdraw: IDL.Record({ lpBurned: IDL.Nat, basket: IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat)) }),
    insuranceStake: IDL.Record({ amountUsd: IDL.Nat, shares: IDL.Nat }),
    insuranceUnstake: IDL.Record({ shares: IDL.Nat, payoutUsd: IDL.Nat }),
    delta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
    debtDelta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
    lpShareDelta: IDL.Record({ marketId: IDL.Text, amount: IDL.Int }),
    insShareDelta: IDL.Record({ amount: IDL.Int }),
    gap: IDL.Record({ fromSeq: IDL.Nat, toSeq: IDL.Nat }),
    config: IDL.Record({ setter: IDL.Text, value: IDL.Text }),
  });
  const UserEvent = IDL.Record({
    seq: IDL.Nat, ts: IDL.Int, user: IDL.Principal,
    counterparty: IDL.Opt(IDL.Principal), kind: UserEventKind,
    prevHash: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  return IDL.Service({
    getEventsRange: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(UserEvent)], ["query"]),
    getCertifiedHead: IDL.Func([], [IDL.Record({
      headHash: IDL.Opt(IDL.Vec(IDL.Nat8)), headSeq: IDL.Opt(IDL.Nat),
      chainStartSeq: IDL.Opt(IDL.Nat), certificate: IDL.Opt(IDL.Vec(IDL.Nat8)),
    })], ["query"]),
  });
};

// ── The frozen v1 canonical form (mirror of lib/EventChain.mo) ───────
// netstring fields — <decimal byte length>:<bytes> — concatenated in the
// exact order below. Text is UTF-8; Nat/Int are decimal text; principals
// are their canonical text form; a null prevHash/counterparty is "".
const enc = new TextEncoder();
function canonical(e) {
  const parts = [];
  const put = (bytes) => { parts.push(enc.encode(String(bytes.length) + ":")); parts.push(bytes); };
  const putT = (t) => put(enc.encode(t));
  const putN = (v) => putT(v.toString());
  const side = (s) => ("buy" in s ? "buy" : "sell");
  putT("v1");
  put(e.prevHash.length ? new Uint8Array(e.prevHash[0]) : new Uint8Array(0));
  putN(e.seq);
  putN(e.ts);
  putT(e.user.toText());
  putT(e.counterparty.length ? e.counterparty[0].toText() : "");
  const k = e.kind;
  if ("fill" in k) {
    const f = k.fill;
    putT("fill"); putT(f.marketId); putT(side(f.side));
    putN(f.price); putN(f.qty); putN(f.orderId); putN(f.tradeId);
  } else if ("deposit" in k) {
    const d = k.deposit;
    putT("withdrawal" in d.kind ? "withdrawal" : "deposit");
    putT(d.token); putN(d.amount); putN(d.timestamp);
  } else if ("orderClosed" in k) {
    const o = k.orderClosed;
    putT("orderClosed"); putN(o.id); putT(o.marketId); putT(side(o.side));
    putT("market" in o.orderType ? "market" : "limit");
    putN(o.price); putN(o.quantity); putN(o.filled);
    putT("filled" in o.status ? "filled" : "cancelled" in o.status ? "cancelled" : "open" in o.status ? "open" : "partiallyFilled");
    putN(o.placedAt); putN(o.closedAt);
  } else if ("liquidation" in k) {
    const l = k.liquidation;
    putT("liquidation"); putT(l.user.toText()); putT(l.debtToken); putN(l.debtRepaid);
    putN(l.debtRepaidUsd); putT(l.collateralToken); putN(l.collateralSeized);
    putN(l.proceedsUsd); putN(l.penaltyUsd); putN(l.healthBefore); putN(l.healthAfter); putN(l.timestamp);
  } else if ("borrow" in k) {
    putT("borrow"); putT(k.borrow.token); putN(k.borrow.amount);
  } else if ("repay" in k) {
    putT("repay"); putT(k.repay.token); putN(k.repay.amount);
  } else if ("lpDeposit" in k) {
    const d = k.lpDeposit;
    putT("lpDeposit"); putT(d.marketId); putN(d.baseAmount); putN(d.quoteAmount); putN(d.lpMinted);
  } else if ("lpWithdraw" in k) {
    const w = k.lpWithdraw;
    putT("lpWithdraw"); putN(w.lpBurned); putN(BigInt(w.basket.length));
    for (const [tok, amt] of w.basket) { putT(tok); putN(amt); }
  } else if ("insuranceStake" in k) {
    putT("insuranceStake"); putN(k.insuranceStake.amountUsd); putN(k.insuranceStake.shares);
  } else if ("insuranceUnstake" in k) {
    putT("insuranceUnstake"); putN(k.insuranceUnstake.shares); putN(k.insuranceUnstake.payoutUsd);
  } else if ("delta" in k) {
    putT("delta"); putT(k.delta.token); putN(k.delta.amount);
  } else if ("debtDelta" in k) {
    putT("debtDelta"); putT(k.debtDelta.token); putN(k.debtDelta.amount);
  } else if ("lpShareDelta" in k) {
    putT("lpShareDelta"); putT(k.lpShareDelta.marketId); putN(k.lpShareDelta.amount);
  } else if ("insShareDelta" in k) {
    putT("insShareDelta"); putN(k.insShareDelta.amount);
  } else if ("gap" in k) {
    putT("gap"); putN(k.gap.fromSeq); putN(k.gap.toSeq);
  } else if ("config" in k) {
    putT("config"); putT(k.config.setter); putT(k.config.value);
  } else {
    throw new Error(`seq ${e.seq}: unknown event kind — verifier older than the canister`);
  }
  return Buffer.concat(parts.map((p) => Buffer.from(p)));
}
const hashEvent = (e) => createHash("sha256").update(canonical(e)).digest();
const hex8 = (b) => Buffer.from(b).toString("hex").slice(0, 16) + "…";
const eq = (a, b) => Buffer.from(a).equals(Buffer.from(b));

// W2-04: one certificate check PER SEGMENT. Sealed archives set their own
// certified_data at the sealing appendBatch, so each segment's head can be
// subnet-vouched — comparing a sealed head against getCertifiedHead().headHash
// alone was comparing a self-report to itself. Throws on a real network;
// returns false (check unavailable) only on a development host.
let certsValidated = 0;
async function validateArchiveCert(certOpt, canisterIdText, headHashOpt, label) {
  if (!headHashOpt.length) throw new Error(`${label}: no headHash to certify`);
  if (!certOpt || !certOpt.length) {
    if (LOCAL_HOST) { console.log(`  ~ ${label}: no certificate served (development host)`); return false; }
    throw new Error(`${label}: host served NO certificate for this segment — an uncertified head proves nothing`);
  }
  try {
    const cid = Principal.fromText(canisterIdText);
    const cert = await Certificate.create({
      certificate: new Uint8Array(certOpt[0]),
      rootKey: agent.rootKey instanceof Uint8Array ? agent.rootKey : new Uint8Array(agent.rootKey),
      principal: { canisterId: cid },
      disableTimeVerification: LOCAL_HOST,
    });
    const res = cert.lookup_path([enc.encode("canister"), cid.toUint8Array(), enc.encode("certified_data")]);
    if (!(res && res.status === "Found" && eq(res.value, Buffer.from(headHashOpt[0])))) {
      throw new Error(`${label}: the subnet certificate does NOT commit to this segment's head`);
    }
    certsValidated++;
    return true;
  } catch (err) {
    if (LOCAL_HOST) { console.log(`  ~ ${label}: certificate check unavailable on development host (${err.message})`); return false; }
    throw new Error(`${label}: certificate check FAILED: ${err.message}`);
  }
}

// ── Walk + verify ────────────────────────────────────────────────────
const agent = await HttpAgent.create({ host: HOST });

// ROOT KEY — the anchor of the whole exercise.
//
// The certificate check (3) is only worth anything if the key it validates
// against is one this file already trusts. fetchRootKey() ASKS THE HOST for
// that key and installs whatever comes back, so calling it unconditionally
// means a hostile gateway hands us its own key, signs a forged head with the
// matching secret, and this verifier prints "certificate VALID" — while the
// docs promise it "does not even trust this website". Development replicas
// genuinely need it (their key is per-instance and can't be baked in), so it
// stays available, but it must be an explicit, visible act.
if (LOCAL_HOST) {
  await agent.fetchRootKey();          // development replica: key is per-instance
  console.log(`⚠ development host ${HOST} — fetched its root key (not the IC's)`);
} else if (INSECURE_ROOT_KEY) {
  await agent.fetchRootKey();
  console.log(`⚠ --insecure-root-key: trusting the root key served by ${HOST}.`);
  console.log("  Certificate validation proves NOTHING against a host that may be hostile.");
} else {
  // Mainnet: the built-in IC root key. Never fetched, so a bad host cannot
  // substitute it — a forged head fails signature validation.
}

const backend = Actor.createActor(backendIdl, { agent, canisterId: BACKEND });
// Declared here (before the fetch below and the foldEvent closure that reads
// it) so it is out of the temporal dead zone when assigned.
let ARB_TEXT = null;
const archives = await backend.getArchives();
if (!archives.length) { console.error("no archives — the ledger starts with the first event"); process.exit(1); }
try {
  const arbOpt = await backend.getArbitrageur();
  if (arbOpt.length) ARB_TEXT = arbOpt[0].toText();
} catch { /* pre-arbitrageur backend — attribution simply reports none wired */ }
// Recorded ledger gaps (L2 sheds). A gap's toSeq is a legitimate re-anchor
// point: the archive that begins there opens a fresh chain segment, so its
// first event's prevHash is NOT expected to match the previous archive's head.
let GAPS = [];
try { GAPS = await backend.getLedgerGaps(); } catch { /* pre-failover backend — no gaps */ }
const REANCHOR = new Set(GAPS.map(([, to]) => Number(to)));
// W2-04: re-anchors claimed by getLedgerGaps are honored only TENTATIVELY —
// after the walk, each structural discontinuity must be justified by a #gap
// event hash-committed in the chain itself, or by an explicit --accept-gap.
const ACCEPT_GAPS = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--accept-gap" && args[i + 1]) {
    const m = String(args[i + 1]).match(/^(\d+):(\d+)$/);
    if (!m) { console.error(`bad --accept-gap ${args[i + 1]} (want FROM:TO)`); process.exit(2); }
    ACCEPT_GAPS.push([parseInt(m[1], 10), parseInt(m[2], 10)]);
  }
}
const CHAIN_GAPS = [];        // [from, to) collected from #gap events on the walk
const PENDING_JUSTIFY = [];   // structural discontinuities awaiting chain proof
const gapEventsMissing = GAPS.reduce((n, [f, t]) => n + (Number(t) - Number(f)), 0);
// Shed re-baselines (see the IDL note): seqs where the fold must reset.
let BASELINES = [];
try { BASELINES = await backend.getShedBaselines(); } catch { /* pre-baseline backend */ }
const BASELINE_STARTS = new Set(BASELINES.map(([f]) => Number(f)));
console.log(`routing table: ${archives.length} archive(s)`);
for (const a of archives) {
  console.log(`  ${a.canisterId}  seqs ${a.firstSeq}…${a.lastSeq.length ? a.lastSeq[0] : "live"}`);
}
if (GAPS.length) {
  console.log(`recorded ledger gaps (L2 failover sheds — observability only, custody unaffected):`);
  for (const [f, t] of GAPS) console.log(`  seq [${f}..${t})  (${Number(t) - Number(f)} events dropped)`);
}
if (BASELINES.length) {
  console.log(`shed re-baselines (absolute re-attestation of every balance after a shed):`);
  for (const [f, t] of BASELINES) console.log(`  seq [${f}..${t})  (${Number(t) - Number(f)} re-attestation rows — fold resets here)`);
}

const folded = new Map();   // "principal#token" → BigInt (only with --fold)
// Semantic external flows (#deposit events): net per token, split by source —
// bridge/user custody flows vs the wired arbitrageur (venue-minted synthetic
// supply). Attribution only; the balance fold above stays deltas-only.
const extFlows = { user: new Map(), arb: new Map() };
const foldEvent = (e) => {
  // A shed re-baseline starts here: the rows that follow re-attest EVERY live
  // balance absolutely. Reset the (gap-lossy) accumulation and let them rebuild
  // it — from the baseline's end onward the fold is exact again. extFlows stays:
  // it is lifetime flow ATTRIBUTION, and the dropped semantic rows in the gap
  // remain missing from it (documented below).
  if (BASELINE_STARTS.has(Number(e.seq))) folded.clear();
  if ("deposit" in e.kind) {
    const d = e.kind.deposit;
    const sign = "withdrawal" in d.kind ? -1n : 1n;
    const bucket = e.user.toText() === ARB_TEXT ? extFlows.arb : extFlows.user;
    bucket.set(d.token, (bucket.get(d.token) ?? 0n) + sign * d.amount);
    return;
  }
  if (!("delta" in e.kind)) return;
  const key = e.user.toText() + "#" + e.kind.delta.token;
  folded.set(key, (folded.get(key) ?? 0n) + e.kind.delta.amount);
};

// An empty page is ambiguous, and the two meanings could not be further apart:
// a genuine HOLE in the tape (rows missing that should be there — a real
// failure), or simply the READABLE TAIL (this replica has not yet caught up).
// Both getCertifiedHead and getEventsRange are QUERIES, so on a live venue they
// can be answered by different replicas at different heights — one certifies a
// head whose rows another has not got yet. Reporting that as "tape gap" cries
// corruption over an artefact of reading a moving tape.
//
// The discriminator: probe ABOVE the empty seq. If higher rows are readable
// while seq s is not, rows really are missing. If nothing at or above s reads
// back, we are simply at the tail. Retry first — the usual cause is skew that
// resolves in a moment.
async function classifyEmptyPage(actor, s, to) {
  for (let attempt = 0; attempt < 3; attempt++) {
    await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
    const retry = await actor.getEventsRange(BigInt(s), 1n);
    if (retry.length) return { kind: "resolved" };
  }
  for (const probe of [s + 1, Math.floor((s + to) / 2), to]) {
    if (probe > to || probe <= s) continue;
    const ahead = await actor.getEventsRange(BigInt(probe), 1n);
    if (ahead.length) return { kind: "hole", readableAt: probe };
  }
  return { kind: "tail" };
}

async function verifySlice(actor, from, to, seed, label) {
  let expectPrev = seed;
  let lastHash = null;
  let s = from;
  let links = 0;
  let truncatedAt = null;
  while (s <= to) {
    const page = await actor.getEventsRange(BigInt(s), BigInt(Math.min(200, to - s + 1)));
    if (!page.length) {
      const verdict = await classifyEmptyPage(actor, s, to);
      if (verdict.kind === "hole") {
        throw new Error(`${label}: tape gap at seq ${s} (seq ${verdict.readableAt} reads back, so rows are MISSING)`);
      }
      if (verdict.kind === "tail") {
        // Not a failure: the tape is being written as we read it.
        truncatedAt = s;
        break;
      }
      continue;   // resolved on retry — carry on from the same seq
    }
    for (const e of page) {
      if (Number(e.seq) > to) break;
      if (expectPrev !== null) {
        const got = e.prevHash.length ? Buffer.from(e.prevHash[0]) : Buffer.alloc(0);
        if (!eq(got, expectPrev)) throw new Error(`${label}: chain BREAK at seq ${e.seq}`);
        links++;
      }
      if ("gap" in e.kind) CHAIN_GAPS.push([Number(e.kind.gap.fromSeq), Number(e.kind.gap.toSeq)]);
      if (FOLD) foldEvent(e);
      lastHash = hashEvent(e);
      expectPrev = lastHash;
      s = Number(e.seq) + 1;
    }
    process.stdout.write(`\r${label}: ${s - from}/${to - from + 1} events`);
  }
  process.stdout.write("\n");
  return { lastHash, links, truncatedAt };
}

const active = archives[archives.length - 1];
const activeActor = Actor.createActor(archiveIdl, { agent, canisterId: active.canisterId });
const head = await activeActor.getCertifiedHead();
if (!head.headHash.length) { console.error("no chain head yet"); process.exit(1); }
const headSeq = Number(head.headSeq[0]);
const chainStart = head.chainStartSeq.length ? Number(head.chainStartSeq[0]) : Number(active.firstSeq);

let totalLinks = 0;
let failed = false;
try {
  if (LAST) {
    let from = Math.max(chainStart, headSeq - LAST + 1);
    let seed = null;
    if (from > chainStart) {
      const prev = await activeActor.getEventsRange(BigInt(from - 1), 1n);
      if (prev.length) { seed = hashEvent(prev[0]); from = Number(prev[0].seq) + 1; }
    }
    const r = await verifySlice(activeActor, from, headSeq, seed, `active ${active.canisterId}`);
    totalLinks = r.links;
    if (r.truncatedAt !== null) {
      // We never reached the certified head, so comparing against it would be
      // comparing different points on the tape. Every link we DID walk is
      // verified; say exactly that rather than claiming a head match — but
      // BOUND the concession (#37.1): an honest replica lags by at most a
      // little, while a host answering [] under a genuine certificate is
      // hiding the tape it certifies. Unbounded, this branch let such a host
      // exit 0 with zero links verified.
      const skew = headSeq - r.truncatedAt + 1;
      if (skew > MAX_TAIL_SKEW) {
        throw new Error(`tail unreadable from seq ${r.truncatedAt} — ${skew} events short of the certified head at ${headSeq} (--max-tail-skew ${MAX_TAIL_SKEW}); the host is hiding tape it certifies`);
      }
      // Zero progress is not a concession: "verified 0 links, exit 0" is the
      // exact lie #37.1 describes, and on a young tape the whole history can
      // fit inside any absolute skew allowance.
      if (r.links === 0) {
        throw new Error(`nothing verifiable: the host certifies a head at seq ${headSeq} but served no readable tape at all`);
      }
      console.log(`~ tail not yet readable from seq ${r.truncatedAt} (live tape / replica skew, ${skew} ≤ ${MAX_TAIL_SKEW})`);
      console.log(`  verified up to seq ${r.truncatedAt - 1}; certified head is ${headSeq}`);
    } else if (!eq(r.lastHash, Buffer.from(head.headHash[0]))) {
      throw new Error("recomputed head ≠ archive head");
    } else {
      console.log(`head ok: ${hex8(r.lastHash)} == certified head at seq ${headSeq}`);
    }
  } else {
    // W2-04: pin the origin. The active head's chainStartSeq is itself only a
    // claim, so --expect-start is the true out-of-band anchor when given;
    // either way, coverage starting LATER than the origin is a truncated
    // archive list unless a justified gap explains exactly that range.
    const claimedStart = head.chainStartSeq.length ? Number(head.chainStartSeq[0]) : 0;
    const esFlag = flag("expect-start");
    const ORIGIN = esFlag !== null && esFlag !== true ? parseInt(esFlag, 10) : claimedStart;
    if (Number(archives[0].firstSeq) > ORIGIN) {
      PENDING_JUSTIFY.push({ from: ORIGIN, to: Number(archives[0].firstSeq),
        what: `history starts at seq ${archives[0].firstSeq} but the chain origin is ${ORIGIN} — early archives omitted?` });
    }
    let carried = null;
    for (let i = 0; i < archives.length; i++) {
      const a = archives[i];
      const actor = i === archives.length - 1 ? activeActor : Actor.createActor(archiveIdl, { agent, canisterId: a.canisterId });
      const aHead = i === archives.length - 1 ? head : await actor.getCertifiedHead();
      // Clip only the FIRST archive's start, and by ITS OWN chain start (not the
      // active archive's — which, after a re-anchor, is a later segment's start).
      // W2-04: the clipped range is unverified tape — it too needs a justified gap.
      const aStart = aHead.chainStartSeq.length ? Number(aHead.chainStartSeq[0]) : Number(a.firstSeq);
      const from = i === 0 ? Math.max(Number(a.firstSeq), aStart) : Number(a.firstSeq);
      if (i === 0 && aStart > Number(a.firstSeq)) {
        PENDING_JUSTIFY.push({ from: Number(a.firstSeq), to: aStart,
          what: `archive 1 re-anchors its own start at ${aStart}, skipping [${a.firstSeq}..${aStart})` });
      }
      const to = a.lastSeq.length ? Number(a.lastSeq[0]) : headSeq;
      // W2-04: coverage continuity — an omitted middle archive is a seq jump.
      if (i > 0 && archives[i - 1].lastSeq.length) {
        const prevLast = Number(archives[i - 1].lastSeq[0]);
        if (Number(a.firstSeq) !== prevLast + 1) {
          PENDING_JUSTIFY.push({ from: prevLast + 1, to: Number(a.firstSeq),
            what: `coverage jumps ${prevLast + 1}→${a.firstSeq} between archives ${i}/${i + 1}` });
        }
      }
      // A recorded gap ends at this archive's firstSeq → it re-anchors a fresh
      // chain segment; its first event's prevHash intentionally does NOT link to
      // the previous archive's head. Seed null so the walk accepts the claimed
      // discontinuity (and still verifies this archive's own chain internally) —
      // TENTATIVELY: the claim must be proven by a chain-committed #gap event
      // after the walk, or the run fails. A fabricated tuple whose only job is
      // to suppress this link check demands a #gap event for an EMPTY range
      // ([firstSeq..firstSeq), when coverage is continuous), which the honest
      // shed path never emits — so the fabrication is refused.
      const reanchored = i > 0 && REANCHOR.has(Number(a.firstSeq));
      if (reanchored && archives[i - 1].lastSeq.length) {
        PENDING_JUSTIFY.push({ from: Number(archives[i - 1].lastSeq[0]) + 1, to: Number(a.firstSeq),
          what: `re-anchor claimed at archive ${i + 1} firstSeq ${a.firstSeq}` });
      }
      const seed = reanchored ? null : carried;
      const r = await verifySlice(actor, from, to, seed, `archive ${i + 1}/${archives.length} ${a.canisterId}`);
      totalLinks += r.links;
      if (r.truncatedAt !== null) {
        // Only the ACTIVE archive has a moving tail; a sealed one that stops
        // short is a genuine failure, so let the head comparison below catch it.
        if (!a.lastSeq.length) {
          // #37.1 — same bound as the --last path: the concession is for a
          // replica lagging a certified head by a little, not for a host
          // hiding the whole tape behind a genuine certificate.
          const skew = headSeq - r.truncatedAt + 1;
          if (skew > MAX_TAIL_SKEW) {
            throw new Error(`${a.canisterId}: tail unreadable from seq ${r.truncatedAt} — ${skew} events short of the certified head at ${headSeq} (--max-tail-skew ${MAX_TAIL_SKEW}); the host is hiding tape it certifies`);
          }
          // Zero progress on the WHOLE RUN is not a concession (see the
          // --last path): sealed archives before this one may have verified
          // links, so gate on the run total, not this slice's count.
          if (totalLinks === 0) {
            throw new Error(`nothing verifiable: the host certifies a head at seq ${headSeq} but served no readable tape at all`);
          }
          console.log(`  ~ tail not yet readable from seq ${r.truncatedAt} (live tape / replica skew, ${skew} ≤ ${MAX_TAIL_SKEW})`);
          console.log(`    verified up to seq ${r.truncatedAt - 1} (active)`);
          carried = r.lastHash;
          continue;
        }
      }
      if (aHead.headHash.length && !eq(r.lastHash, Buffer.from(aHead.headHash[0]))) {
        throw new Error(`${a.canisterId}: recomputed head ≠ its reported head`);
      }
      // W2-04: certify THIS segment's head — sealed ones included. Before
      // this, only the active archive's certificate was validated and every
      // sealed head was trusted on its own say-so.
      const certed = await validateArchiveCert(aHead.certificate, a.canisterId, aHead.headHash, a.canisterId);
      console.log(`  head ok: ${hex8(r.lastHash)}${a.lastSeq.length ? " (sealed)" : " (active)"}${certed ? " [certified]" : ""}${reanchored ? " [re-anchor claimed]" : ""}`);
      carried = r.lastHash;
    }
    // W2-04: every structural discontinuity honored above must now be proven
    // by the chain itself (or an explicit operator flag). getLedgerGaps and
    // getArchives are uncertified self-reports; the #gap events collected on
    // the walk are hash-committed and certificate-covered.
    for (const p of PENDING_JUSTIFY) {
      const inChain = CHAIN_GAPS.some(([f, t]) => f === p.from && t === p.to);
      const accepted = ACCEPT_GAPS.some(([f, t]) => f === p.from && t === p.to);
      if (!inChain && !accepted) {
        throw new Error(`unjustified discontinuity: ${p.what} — no #gap event [${p.from}..${p.to}) is hash-committed in the verified chain and no --accept-gap ${p.from}:${p.to} was given`);
      }
      if (!inChain) console.log(`  ⚠ discontinuity [${p.from}..${p.to}) accepted by FLAG (legacy, not chain-declared): ${p.what}`);
    }
  }
  const certSummary = certsValidated > 0 ? `; ${certsValidated} segment certificate(s) subnet-validated` : "";
  if (GAPS.length) {
    console.log(`\n✓ ${totalLinks.toLocaleString()} chain links verified across ${GAPS.length} gap(s), each chain-declared or operator-accepted `
      + `(${gapEventsMissing.toLocaleString()} events dropped by L2 failover — documented, not tampering`
      + `${BASELINES.length ? `; ${BASELINES.length} re-baseline(s) keep the tape replayable` : ""})${certSummary}`);
  } else {
    console.log(`\n✓ ${totalLinks.toLocaleString()} chain links verified${certSummary}`);
  }
} catch (err) {
  console.error(`\n✗ ${err.message}`);
  failed = true;
}

// ── IC certificate over the active head ──────────────────────────────
if (!failed && head.certificate.length) {
  try {
    const cid = Principal.fromText(active.canisterId);
    const cert = await Certificate.create({
      certificate: new Uint8Array(head.certificate[0]),
      rootKey: agent.rootKey instanceof Uint8Array ? agent.rootKey : new Uint8Array(agent.rootKey),
      // TAGGED principal — the SDK dispatches on `canisterId`/`subnetId` being
      // present and throws its internal UNREACHABLE_ERROR for a bare Principal.
      // Passing one bare made every certificate check fail with "unreachable",
      // which the catch below reported as an environment limitation — so this
      // check, the one the root key exists to anchor, never actually ran.
      principal: { canisterId: cid },
      // #37.5 — the freshness window misfires on a LOCAL replica (its clock
      // is not wall time); it must NOT be waived anywhere else. The browser
      // verifier states the same rule for itself — an arbitrary --host is
      // exactly where a stale-but-genuine certificate replay lives.
      disableTimeVerification: LOCAL_HOST,
    });
    const res = cert.lookup_path([enc.encode("canister"), cid.toUint8Array(), enc.encode("certified_data")]);
    if (res && res.status === "Found" && eq(res.value, Buffer.from(head.headHash[0]))) {
      // W2-04 verdict copy: say what was proven. This certificate covers the
      // ACTIVE archive's head only; sealed segments are vouched by their own
      // per-segment certificates in --full mode (and NOT AT ALL in --last
      // mode, which never visits them). The guarantee also leans on sealed
      // archives being immutable — absolute only once setBlackholeAtSeal is
      // in force (pre-mainnet checklist); until then a reinstall by the
      // controller could rewrite a sealed segment under a fresh certificate.
      console.log(`✓ IC certificate VALID — the subnet vouches for the ACTIVE archive's head${certsValidated > 1 ? ` (+ ${certsValidated - 1} sealed segment(s) validated separately)` : ""}`);
      if (LAST) console.log("  ⚠ --last mode: sealed history was not visited; run --full for per-segment certificates");
    } else {
      console.error("✗ IC certificate does NOT commit to this head");
      failed = true;
    }
  } catch (err) {
    // Development replicas (pocket-ic) can still fail here — their certificates
    // and subnet ranges are synthetic. On a real network this must SUCCEED, so
    // treat a failure there as a verification failure rather than a shrug:
    // silently downgrading is how the check went unnoticed for so long.
    if (LOCAL_HOST) {
      console.log(`~ certificate check unavailable on development host (${err.message})`);
    } else {
      console.error(`✗ certificate check FAILED: ${err.message}`);
      failed = true;
    }
  }
} else if (!failed) {
  // #37.2 — ABSENCE must not be quieter than invalidity. The block above
  // fails closed on a bad certificate; a host that simply omitted the field
  // skipped the whole check and the run exited 0 with no certificate line
  // at all — while :348 exits 1 when the SAME record's headHash is missing.
  if (LOCAL_HOST) {
    console.log("~ no certificate served (development host)");
  } else {
    console.error("✗ host served NO certificate for the head — a chain without the subnet's signature proves nothing; refusing to vouch");
    failed = true;
  }
}

// ── PoR liabilities fold ─────────────────────────────────────────────
if (FOLD && !failed) {
  const perToken = new Map();
  let accounts = 0;
  for (const [key, bal] of folded) {
    if (bal === 0n) continue;
    accounts++;
    const token = key.split("#")[1];
    perToken.set(token, (perToken.get(token) ?? 0n) + (bal > 0n ? bal : 0n));
  }
  console.log(`\nPoR liabilities (fold of every #delta row over the verified tape):`);
  for (const [token, total] of [...perToken.entries()].sort()) {
    console.log(`  ${token.padEnd(8)} ${(Number(total) / 1e8).toLocaleString(undefined, { maximumFractionDigits: 4 })}`);
  }
  console.log(`  across ${accounts} accounts with nonzero folded balances`);
  if (GAPS.length && BASELINES.length) {
    const lastB = BASELINES[BASELINES.length - 1];
    console.log(`  ✓ ${GAPS.length} recorded gap(s) (${gapEventsMissing.toLocaleString()} events dropped by L2 failover), healed by`);
    console.log(`    ${BASELINES.length} re-baseline(s): the fold reset at each baseline and rebuilt from its absolute`);
    console.log(`    re-attestation rows — balances above are EXACT from seq ${lastB[1]} onward, tape alone.`);
    console.log(`    (Only the dropped HISTORY is gone; per-account flow attribution across a gap stays partial.)`);
  } else if (GAPS.length) {
    console.log(`  ⚠ ${GAPS.length} recorded gap(s), ${gapEventsMissing.toLocaleString()} events (incl. #delta rows) dropped by L2`);
    console.log(`    failover — no re-baseline follows (pre-baseline backend): balances cannot be`);
    console.log(`    reconstructed from the public tape alone through a dropped range. The LIVE balances`);
    console.log(`    are intact (only the archived RECORD was shed); re-seed from getBalances at the gap.`);
  }
  const fmtFlow = (m) => [...m.entries()].sort()
    .map(([t, v]) => `${t} ${(Number(v) / 1e8).toLocaleString(undefined, { maximumFractionDigits: 4 })}`)
    .join(" · ") || "none";
  console.log(`
  attributed external flows (net, from semantic #deposit rows):`);
  console.log(`    bridge/users            ${fmtFlow(extFlows.user)}`);
  console.log(`    arbitrageur (synthetic) ${fmtFlow(extFlows.arb)}${ARB_TEXT ? "" : "  (none wired)"}`);
  if (LAST) console.log(`  ⚠ WINDOW fold (--last ${LAST}) — run --full for complete liabilities`);
  console.log(`  (custody must cover liabilities NET of arbitrageur-minted supply —`);
  console.log(`   the arb's flows are the venue's own import/export at the oracle mark,`);
  console.log(`   not user custody; see docs/amm-vault-design.md)`);
}

process.exit(failed ? 1 : 0);
