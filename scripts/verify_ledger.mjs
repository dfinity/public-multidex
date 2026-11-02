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
//   --last N   verify the newest N events — a CLIPPED FULL WALK (1788472713):
//              every archive holding tape inside the window is visited,
//              newest backwards, the hash carried across each boundary, every
//              visited sealed head compared and certificate-checked; only the
//              tape BELOW the window is skipped (by definition of the request)
//   --full     verify the ENTIRE history across every archive (default)
//   --season N verify a CLOSED season's sealed chain instead of the live one.
//              getArchives serves the CURRENT season only (the season boundary
//              detaches the closed chain from it), so the routing table is
//              getSeasonArchives(N); the origin is 0 (every season restarts
//              the chain at seq 0); and the walked head must ALSO equal the
//              chainHead the SeasonRecord committed at the boundary, with the
//              tape ending exactly at finalEventSeq-1 — a SECOND out-of-band
//              anchor for the sealed chain. Sealed-segment certificates
//              validate as in --full. Full walk only (no --last). The
//              closed season's gap tuples and shed re-baselines come from
//              getSeasonGaps(N) / getSeasonShedBaselines(N) (1788474114 —
//              the boundary preserves them; the live getLedgerGaps /
//              getShedBaselines describe the NEW season and are never
//              consulted here), consulted exactly as the live ones are:
//              re-anchor CLAIMS the chain's #gap events must prove, and the
//              seqs where --fold resets. A season closed before that landed
//              answers [] — its re-anchors are then inferred from the season
//              table's list jumps (same proof demanded) and --fold cannot
//              reset across its sheds (warned). An EMPTY season table under
//              a record that committed a chainHead is refused as "archives
//              deleted" (1788477403): the record is permanent, but a
//              #dev/#play resetExchange wipes every season's segments and
//              keeps only the record — nothing can re-walk that chainHead.
//   --expect-start N
//              pin the chain origin externally (default 0 — the origin of
//              every chain this canister mints: the tape starts at seq 0 on
//              first deploy and restarts at 0 at every season boundary; see
//              docs/pre-mainnet-checklist.md). History starting later than
//              this fails unless a chain-declared gap explains it — the
//              out-of-band anchor that makes "omit the early archives"
//              refusable. The default is deliberately NOT the active head's
//              chainStartSeq: that field is uncertified and is the ACTIVE
//              segment's own per-canister anchor, so a host that omits its
//              sealed archives and reports start = its own first seq would
//              satisfy a check seeded from it by construction (#55.1).
//   --accept-gap FROM:TO   (repeatable)
//              accept ONE discontinuity that has no #gap event in the chain —
//              for operator-audited legacy gaps recorded before gaps were
//              chain-declared. Anything else: a re-anchor is honored only if
//              a #gap event with that exact range is hash-committed in the
//              chain being verified — or a run of exactly CONTIGUOUS #gap
//              events covering it (#55.4: back-to-back sheds under a blocked
//              spawn declare one range per shed while the archive list gains
//              a single jump). getLedgerGaps alone proves nothing — it is an
//              uncertified self-report by the party under audit.
//   --max-tail-skew N
//              how many events below the certified head the ACTIVE tape may
//              stop short (query replicas lag the certified state a little).
//              Default 200 (one page). Beyond it the run FAILS: a host
//              serving a genuine certificate while answering [] for the tape
//              is hiding what it certifies (#37.1).
//   --anchor-retries N
//              how many times a walk that stopped short of the certified
//              head re-fetches getCertifiedHead to ANCHOR itself (default 5,
//              with a growing pause between). Every link such a walk checked
//              is consistent with itself and with nothing the subnet signed,
//              so it is vouched for only once (a) the tape catches up to a
//              fresh certified head — recomputed head == that head, THAT
//              certificate validated — or (b) a fresh certified head lands
//              INSIDE the readable window (the replica serving the tape
//              vouching for what it has) — the recomputed hash AT that seq
//              == it, that certificate validated. Neither within the bound:
//              the run is INCONCLUSIVE (exit 3), never VALID (H-18 / F10 —
//              the old tail-skew concession printed VALID over a window it
//              had compared to nothing certified).
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
// Exit code 0 = everything verified; 1 = ANY check failed; 2 = usage;
// 3 = INCONCLUSIVE — nothing failed, but the readable tape never reached a
//     certified head within --anchor-retries, so nothing certified covers
//     the walk: re-run later, or against another gateway. Never trust a
//     3 as a pass.

import { createHash } from "node:crypto";

// ── CLI ──────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf("--" + name);
  return i >= 0 ? (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true) : null;
};
const HOST = flag("host") || "http://127.0.0.1:8000";
const BACKEND = flag("backend");
if (!BACKEND) {
  console.error("usage: verify_ledger.mjs --backend <canister-id> [--host <url>] [--last N|--full] [--fold]");
  process.exit(2);
}
// A numeric flag is either ABSENT (its default applies) or a well-formed
// non-negative integer. Nothing in between: a bare `--max-tail-skew` or an
// `--expect-start abc` used to parse to NaN, and every comparison against NaN
// is false — so a typo silently DISABLED the bound it named (#55.1). Refuse
// loudly instead, before any network I/O, as a usage error (exit 2).
const numFlag = (name, dflt) => {
  const v = flag(name);
  if (v === null) return dflt;
  if (v === true || !/^\d+$/.test(v)) {
    console.error(`--${name} needs a non-negative integer (got ${v === true ? "no value" : JSON.stringify(v)})`);
    process.exit(2);
  }
  return parseInt(v, 10);
};
const LAST = numFlag("last", null);
// #37.1 — bound on the active-tail concession, in events (default one page).
const MAX_TAIL_SKEW = numFlag("max-tail-skew", 200);
// H-18 (F10) — how many re-fetches of getCertifiedHead a truncated walk gets
// to anchor itself before the run is declared INCONCLUSIVE (exit 3).
const ANCHOR_RETRIES = numFlag("anchor-retries", 5);
// #55.1 — the chain origin is an INPUT to the audit, never a reading from the
// host (see --expect-start above). Parsed here so a malformed value fails
// before the first query, not after a long walk.
const EXPECT_START = numFlag("expect-start", null);
// #55 (1788468754): a closed season's chain is walked in FULL — a window over
// a finite, sealed tape has nothing to bound and would skip the segments
// whose certificates are the point.
const SEASON = numFlag("season", null);
if (SEASON !== null && LAST !== null) { console.error("--season walks the sealed chain in full; drop --last"); process.exit(2); }
const FOLD = !!flag("fold");
const INSECURE_ROOT_KEY = !!flag("insecure-root-key");
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
    // 1788474114: the CLOSED season's gap tuples and shed re-baselines — the
    // same shapes as the two above, preserved at the season boundary (the
    // live tuples are cleared there and describe the new season). Absent on
    // a pre-1788474114 backend (the call rejects → treated as []).
    getSeasonGaps: IDL.Func([IDL.Nat], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat, IDL.Int))], ["query"]),
    getSeasonShedBaselines: IDL.Func([IDL.Nat], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat))], ["query"]),
    // #55 (1788468754): a CLOSED season's routing table (same row shape as
    // getArchives — sealed segments, the season's tip, and possibly the
    // successor pre-spawned before the boundary, which never held an event)
    // and the boundary records the sealed chain is anchored to.
    getSeasonArchives: IDL.Func([IDL.Nat], [IDL.Vec(IDL.Record({
      canisterId: IDL.Text, firstSeq: IDL.Nat, lastSeq: IDL.Opt(IDL.Nat),
    }))], ["query"]),
    getSeasonRecords: IDL.Func([], [IDL.Vec(IDL.Record({
      season: IDL.Nat, endedNs: IDL.Int, finalEventSeq: IDL.Nat, totalRanked: IDL.Nat,
      archives: IDL.Vec(IDL.Principal), chainHead: IDL.Opt(IDL.Vec(IDL.Nat8)),
      finalTop: IDL.Vec(IDL.Record({
        rank: IDL.Nat, username: IDL.Text, profitUsd: IDL.Int, capitalUsd: IDL.Nat,
        equityUsd: IDL.Int, returnBps: IDL.Int, feeLevel: IDL.Nat, badgeCount: IDL.Nat,
      })),
    }))], ["query"]),
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
// #55 (1788468754): season mode routes by the CLOSED season's own table and
// anchors to its boundary record. Both are the host's answers, exactly like
// getArchives — the per-segment certificates and the hash walk are what
// prove them; the record is the second anchor the walk must ALSO meet.
let SEASON_REC = null;
let archives;
if (SEASON !== null) {
  const recs = await backend.getSeasonRecords();
  SEASON_REC = recs.find((r) => Number(r.season) === SEASON) || null;
  if (!SEASON_REC) { console.error(`no SeasonRecord for season ${SEASON} (${recs.length} season(s) recorded)`); process.exit(1); }
  if (!SEASON_REC.chainHead.length) {
    // A season closed with no tape at all (finalEventSeq 0) has nothing to
    // walk — and nothing to vouch for: same verdict as zero progress (#37.1).
    console.error(`season ${SEASON}: the SeasonRecord committed no chainHead${Number(SEASON_REC.finalEventSeq) === 0 ? " (finalEventSeq 0 — the season closed with no tape)" : ""} — nothing anchors a sealed chain; refusing to vouch`);
    process.exit(1);
  }
  const table = await backend.getSeasonArchives(BigInt(SEASON));
  if (!table.length) {
    // 1788477403: the SeasonRecord is the PERMANENT record — it survives a
    // #dev/#play resetExchange, which deletes every season's segments and
    // clears the routing tables. An EMPTY table under a record that committed
    // a chainHead is therefore "the sealed tape is gone", a different verdict
    // from "the routed segments hold no event" (below), and the message says
    // so — the old wording read as if the segments were merely empty.
    console.error(`season ${SEASON}: the SeasonRecord names ${SEASON_REC.archives.length} archive(s) but none is routed any more — its sealed tape was deleted (a #dev/#play resetExchange wipes every season's archives and keeps only the record); the record's chainHead cannot be re-walked`);
    process.exit(1);
  }
  const recorded = new Set(SEASON_REC.archives.map((p) => p.toText()));
  archives = [];
  for (const a of table) {
    if (!recorded.has(a.canisterId)) { console.error(`season ${SEASON}: segment ${a.canisterId} is routed but absent from the SeasonRecord's archive list`); process.exit(1); }
    if (a.lastSeq.length) { archives.push(a); continue; }
    // A lastSeq-null row is the season's tip OR the successor pre-spawned
    // before the boundary, which never held an event — its certified head
    // tells. A tip the host hides behind an empty head does not pass: the
    // record's chainHead and finalEventSeq still have to be met by whatever
    // remains, and a sealed segment cannot end at the boundary's head unless
    // it IS the tip.
    const h = await Actor.createActor(archiveIdl, { agent, canisterId: a.canisterId }).getCertifiedHead();
    if (!h.headHash.length) { console.log(`  ~ season ${SEASON}: ${a.canisterId} never held an event (successor pre-spawned before the boundary) — not walked`); continue; }
    archives.push(a);
  }
  console.log(`season ${SEASON}: sealed chain — the boundary record says finalEventSeq ${SEASON_REC.finalEventSeq}, chainHead ${hex8(SEASON_REC.chainHead[0])}`);
} else {
  archives = await backend.getArchives();
}
if (!archives.length) { console.error(SEASON !== null ? `season ${SEASON}: no segment holds any event` : "no archives — the ledger starts with the first event"); process.exit(1); }
// H-18 (F21): the SHAPE of a served routing list, checked before any walk.
// getArchives (and a season table once its never-written successor is
// dropped) is sealed rows in seq order followed by at most ONE open row —
// the active archive, always last: the backend appends exactly one lastSeq-
// null entry. So a non-final row with lastSeq null, ranges that are not
// strictly ascending (a row starting at or below its predecessor's lastSeq),
// or an inverted row (lastSeq < firstSeq) is a shape the backend cannot emit
// — a host serving one is lying about its own topology, and the walk must
// not begin: an open non-final row would make the tentative re-anchor after
// it final with no predecessor end to justify it against (and, before this,
// took the active-tail concession below — which keyed on lastSeq null, not
// on being LAST), and an overlap would let one seq be "verified" by two
// different segments. Body kept byte-identical in src/frontend/src/ledger.js
// (tests/verify_chain_client.test.mjs holds the two together).
function validateArchiveList(archives) {
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
try { validateArchiveList(archives); } catch (err) { console.error(`✗ ${err.message}`); process.exit(1); }
try {
  const arbOpt = await backend.getArbitrageur();
  if (arbOpt.length) ARB_TEXT = arbOpt[0].toText();
} catch { /* pre-arbitrageur backend — attribution simply reports none wired */ }
// Recorded ledger gaps (L2 sheds). A gap's toSeq is a legitimate re-anchor
// point: the archive that begins there opens a fresh chain segment, so its
// first event's prevHash is NOT expected to match the previous archive's head.
// #55 (1788468754): the LIVE tuples (and the shed baselines below) describe
// the CURRENT season — performWorldWipe clears both at the boundary — so a
// season walk never reads them. 1788474114: the boundary now PRESERVES the
// closed season's tuples under its season number (getSeasonGaps /
// getSeasonShedBaselines), so season mode reads THOSE, exactly as claims: a
// re-anchor is still proven only by the #gap events the sealed chain commits.
// A season closed before that landed answers [] (or rejects on an older
// backend) — its re-anchors are then inferred from the season table's list
// jumps below, as before.
let GAPS = [];
if (SEASON === null) { try { GAPS = await backend.getLedgerGaps(); } catch { /* pre-failover backend — no gaps */ } }
else { try { GAPS = await backend.getSeasonGaps(BigInt(SEASON)); } catch { /* pre-1788474114 backend — inferred from list jumps */ } }
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
// which prove nothing. Body kept byte-identical in src/frontend/src/ledger.js
// (tests/verify_chain_client.test.mjs holds the two together).
function mergeContiguousGaps(list) {
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
function planWindow(origin, headSeq, lastN, archives, reanchors) {
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
// W2-04: every structural discontinuity honored on a walk must be proven by
// the chain itself (or an explicit operator flag). getLedgerGaps and
// getArchives are uncertified self-reports; the #gap events collected on the
// walk are hash-committed and certificate-covered. #55.4: exact match against
// the CONTIGUOUS-MERGED chain declarations — see mergeContiguousGaps; the
// tuple list (GAPS) is never consulted here. Shared by --full and --last
// (1788472713: a window's inner jumps and its leading clip meet the same
// bar). Returns one verdict per pending range, in order, for the caller's
// own reporting; throws on the first unjustified one.
function justifyDiscontinuities() {
  const DECLARED = mergeContiguousGaps(CHAIN_GAPS);
  const noted = new Set();   // one range can be pending twice (coverage jump + claimed re-anchor)
  const verdicts = [];
  for (const p of PENDING_JUSTIFY) {
    const inChain = DECLARED.some(([f, t]) => f === p.from && t === p.to);
    const accepted = ACCEPT_GAPS.some(([f, t]) => f === p.from && t === p.to);
    if (!inChain && !accepted) {
      const seen = CHAIN_GAPS.length ? ` (chain-declared: ${CHAIN_GAPS.map(([f, t]) => `[${f}..${t})`).join(" ")})` : "";
      throw new Error(`unjustified discontinuity: ${p.what} — no #gap event or contiguous run of #gap events [${p.from}..${p.to}) is hash-committed in the verified chain${seen} and no --accept-gap ${p.from}:${p.to} was given`);
    }
    if (!inChain) console.log(`  ⚠ discontinuity [${p.from}..${p.to}) accepted by FLAG (legacy, not chain-declared): ${p.what}`);
    else if (!CHAIN_GAPS.some(([f, t]) => f === p.from && t === p.to) && !noted.has(`${p.from}:${p.to}`)) {
      noted.add(`${p.from}:${p.to}`);
      const run = CHAIN_GAPS.filter(([f, t]) => f >= p.from && t <= p.to).length;
      console.log(`  ✓ discontinuity [${p.from}..${p.to}) justified by ${run} contiguous chain-declared #gap events (back-to-back sheds)`);
    }
    verdicts.push({ from: p.from, to: p.to, inChain });
  }
  return verdicts;
}
const gapEventsMissing = GAPS.reduce((n, [f, t]) => n + (Number(t) - Number(f)), 0);
// Shed re-baselines (see the IDL note): seqs where the fold must reset.
let BASELINES = [];
if (SEASON === null) { try { BASELINES = await backend.getShedBaselines(); } catch { /* pre-baseline backend */ } }
else { try { BASELINES = await backend.getSeasonShedBaselines(BigInt(SEASON)); } catch { /* pre-1788474114 backend — no reset points */ } }
const BASELINE_STARTS = new Set(BASELINES.map(([f]) => Number(f)));
console.log(`routing table: ${archives.length} archive(s)${SEASON !== null ? ` (season ${SEASON}, sealed)` : ""}`);
for (const a of archives) {
  console.log(`  ${a.canisterId}  seqs ${a.firstSeq}…${a.lastSeq.length ? a.lastSeq[0] : "live"}`);
}
if (GAPS.length) {
  console.log(`recorded ledger gaps (L2 failover sheds — observability only, custody unaffected${SEASON !== null ? "; preserved at the season boundary" : ""}):`);
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

// `tail` (optional Map seq → hash): H-18 (F10) retains the recomputed hash of
// the newest MAX_TAIL_SKEW+1 events walked, so a walk that stops short of the
// certified head can later be anchored at a fresh certified head that falls
// INSIDE what it read — compared AT that seq, not at the end of the walk.
async function verifySlice(actor, from, to, seed, label, tail) {
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
      if (tail) {
        tail.set(Number(e.seq), lastHash);
        if (tail.size > MAX_TAIL_SKEW + 1) tail.delete(tail.keys().next().value);
      }
    }
    process.stdout.write(`\r${label}: ${s - from}/${to - from + 1} events`);
  }
  process.stdout.write("\n");
  return { lastHash, links, truncatedAt };
}

// H-18 (F10): the verdict that is neither pass nor fail. A walk that stopped
// short of the certified head checked links that are consistent with each
// other and with NOTHING the subnet signed; when the bounded anchoring below
// cannot change that, the honest answer is "could not tell" — exit 3, no
// VALID, no "chain links verified" — never a pass by concession.
class Inconclusive extends Error {}

// H-18 (F10): anchor a walk that stopped short of the certified head.
// Both getCertifiedHead and getEventsRange are queries answered by whichever
// replica the gateway picks, so "the tape is one page behind the head" is a
// routine, honest shape — and ALSO exactly what a host serving a fabricated
// prefix under a genuine certificate for a withheld head looks like. The old
// concession could not tell them apart and vouched for both. Now the walk
// re-fetches the head (bounded by --anchor-retries) and is vouched for only
// once it is compared against SOMETHING certified:
//   (a) caught up — the fresh head is at or beyond the truncation point and
//       the tape now reads through to it: extend the walk, recomputed head
//       == fresh head;
//   (b) fresh head INSIDE the readable window — the replica that serves the
//       tape certifies its own lower head: the recomputed hash AT that seq
//       (retained in `tail`) == fresh head.
// A mismatch in either is a hard FAIL (the readable tape is not the tape the
// subnet signed). Returns { anchored, head, headSeq, anchorHash, walk } —
// the caller validates the fresh certificate exactly as it would the
// original and compares nothing else; `walk` is the latest state either way.
async function anchorTruncatedTail(actor, walk, seed, label, tail) {
  let latest = null;
  for (let attempt = 0; attempt < ANCHOR_RETRIES; attempt++) {
    await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
    const fresh = await actor.getCertifiedHead();
    if (!fresh.headHash.length || !fresh.headSeq.length) continue;
    latest = fresh;
    const freshSeq = Number(fresh.headSeq[0]);
    const readTo = walk.truncatedAt - 1;
    if (freshSeq <= readTo) {
      const at = tail.get(freshSeq);
      if (!at) {
        console.log(`  ~ fresh certified head at seq ${freshSeq} is more than --max-tail-skew below the readable tape (seq ${readTo}) — not anchorable (attempt ${attempt + 1}/${ANCHOR_RETRIES})`);
        continue;
      }
      if (!eq(at, Buffer.from(fresh.headHash[0]))) {
        throw new Error(`${label}: recomputed hash at seq ${freshSeq} ≠ the certified head served for that seq — the readable tape is not the tape the subnet signed`);
      }
      console.log(`  anchored at a fresh certified head: seq ${freshSeq} == recomputed hash ${hex8(at)} (${readTo - freshSeq} readable event(s) above it are hash-consistent but not certificate-covered)`);
      return { anchored: true, head: fresh, headSeq: freshSeq, anchorHash: at, walk };
    }
    const ext = await verifySlice(actor, walk.truncatedAt, freshSeq, walk.lastHash ?? seed, label, tail);
    walk = { lastHash: ext.lastHash ?? walk.lastHash, links: walk.links + ext.links, truncatedAt: ext.truncatedAt };
    if (ext.truncatedAt === null) {
      if (!eq(walk.lastHash, Buffer.from(fresh.headHash[0]))) {
        throw new Error(`${label}: recomputed head ≠ certified head at seq ${freshSeq}`);
      }
      console.log(`  tape caught up: recomputed head ${hex8(walk.lastHash)} == certified head at seq ${freshSeq}`);
      return { anchored: true, head: fresh, headSeq: freshSeq, anchorHash: walk.lastHash, walk };
    }
    console.log(`  ~ still short: readable to seq ${ext.truncatedAt - 1}, certified head at seq ${freshSeq} (attempt ${attempt + 1}/${ANCHOR_RETRIES})`);
  }
  return { anchored: false, head: latest, headSeq: latest ? Number(latest.headSeq[0]) : null, anchorHash: null, walk };
}
// The verdict on a walk the anchoring could not anchor. Two of the three are
// FAILURES (the host hides tape it certifies; the host served nothing at
// all — #37.1); the third is the honest "could not tell".
function unanchoredVerdict(walk, headSeq, runLinks, label) {
  const readTo = walk.truncatedAt - 1;
  const skew = headSeq - readTo;
  if (skew > MAX_TAIL_SKEW) {
    throw new Error(`${label}: tail unreadable from seq ${walk.truncatedAt} — ${skew} events short of the certified head at ${headSeq} (--max-tail-skew ${MAX_TAIL_SKEW}); the host is hiding tape it certifies`);
  }
  if (runLinks === 0) {
    throw new Error(`nothing verifiable: the host certifies a head at seq ${headSeq} but served no readable tape at all`);
  }
  throw new Inconclusive(`${label}: walked ${runLinks} link(s) up to seq ${readTo}, but the readable tape never reached the certified head at seq ${headSeq} and no fresh certified head fell inside the readable window (${ANCHOR_RETRIES} re-fetch(es)) — nothing the subnet signed covers this walk`);
}

const active = archives[archives.length - 1];
const activeActor = Actor.createActor(archiveIdl, { agent, canisterId: active.canisterId });
// `let`: H-18 (F10) re-anchors a truncated walk at a FRESH certified head,
// which then becomes the head the certificate block below validates.
let head = await activeActor.getCertifiedHead();
if (!head.headHash.length) { console.error("no chain head yet"); process.exit(1); }
let headSeq = Number(head.headSeq[0]);
// The chain ORIGIN is an INPUT to the audit, shared by both modes.
// #55.1: the default is 0, NOT head.chainStartSeq. That field is
// uncertified (only the 32-byte head hash sits in certified_data) and is
// the ACTIVE segment's own per-canister anchor (set on the first event
// stored in THAT canister), so on any chain with a sealed predecessor a
// "consistent liar" — sealed archives dropped from getArchives, head
// claiming start = its own firstSeq — satisfied `firstSeq > origin` by
// construction and exited 0 with "0 chain links verified". 0 is the truth
// of every chain the backend mints: nextEventSeq starts at 0 on first
// deploy and is reset to 0 (chain state cleared) at every wipe and season
// boundary — main.mo performWorldWipe; docs/pre-mainnet-checklist.md.
// --expect-start is the out-of-band override for the one legitimate
// exception (a dev venue whose tape predates the chain code). NEVER seed
// this from getCertifiedHead, getArchives or getLedgerGaps: any default
// the party under audit chose reopens the hole.
const ORIGIN = EXPECT_START !== null ? EXPECT_START : 0;

let totalLinks = 0;
let failed = false;
// 1788472713: what the window visited, for the certificate block's verdict copy.
let WINDOW = null;
try {
  if (LAST) {
    // 1788472713: the window is a CLIPPED FULL WALK. planWindow routes the
    // request [requestedFrom..headSeq] newest-backwards across the routing
    // list (every archive holding tape inside the window is a visited
    // segment, walked from max(firstSeq, requestedFrom)); the loop below is
    // the full walk's own discipline: the hash carried across every
    // boundary, every visited sealed head compared AND certificate-checked
    // (validateArchiveCert), every coverage jump INSIDE the window justified
    // by a chain-declared #gap run (or --accept-gap) exactly as a list jump
    // is. Only the tape below requestedFrom is unverified — by definition of
    // the request. Before this the window CLIPPED at the active archive's
    // firstSeq and printed "not visited; run --full", so right after an
    // archive rotation `--last 500` verified a handful of links. The plan is
    // made against serve bounds and the chain origin — never against the
    // head's uncertified start claim (#55.6).
    const { requestedFrom, segments } = planWindow(ORIGIN, headSeq, LAST, archives, REANCHOR);
    WINDOW = { requestedFrom, from: segments[0].from, visited: segments.length, unvisited: segments[0].index };
    let carried = null;
    let anyJump = false;
    for (const seg of segments) {
      const a = archives[seg.index];
      const isActive = seg.index === archives.length - 1;
      const actor = isActive ? activeActor : Actor.createActor(archiveIdl, { agent, canisterId: a.canisterId });
      let aHead = isActive ? head : await actor.getCertifiedHead();
      const label = `archive ${seg.index + 1}/${archives.length} ${a.canisterId}`;
      // The seed is the expected prevHash of the first walked event (see
      // planWindow): carried from the visited predecessor; the TAPE's own
      // hash of seq from-1 on this archive ("self") or on the contiguous
      // unvisited predecessor ("predecessor" — verifying the cross-archive
      // link too); null at the chain origin, at the window's edge with
      // nothing to bridge, and at a jump (tentatively — justified below).
      let seed = null;
      if (seg.seedOn === "carried") seed = carried;
      else if (seg.seedOn !== null) {
        const seedActor = seg.seedOn === "self" ? actor
          : Actor.createActor(archiveIdl, { agent, canisterId: archives[seg.index - 1].canisterId });
        const prev = await seedActor.getEventsRange(BigInt(seg.from - 1), 1n);
        if (prev.length && Number(prev[0].seq) === seg.from - 1) seed = hashEvent(prev[0]);
        else if (seg.seedOn === "predecessor") {
          throw new Error(`sealed archive ${archives[seg.index - 1].canisterId} lists lastSeq ${seg.from - 1} but serves nothing there — the window cannot be bridged to it`);
        } else if (!isActive) {
          throw new Error(`${label}: lists seq ${seg.from - 1} but serves nothing there — a sealed segment has no moving tail`);
        }
        // (active: an unserved from-1 is judged by the walk itself — a hole
        // above it is a tape gap, a lagging tail is anchored or INCONCLUSIVE.)
      }
      if (seg.jump) {
        anyJump = true;
        PENDING_JUSTIFY.push(seg === segments[0]
          ? { from: seg.jump[0], to: seg.jump[1], what: `window clipped at seq ${seg.from}: the routing list claims tape starts inside the requested window [${requestedFrom}..${headSeq}] and no listed sealed archive bridges [${seg.jump[0]}..${seg.jump[1]}) — early tape omitted?` }
          : { from: seg.jump[0], to: seg.jump[1], what: `coverage jumps ${seg.jump[0]}→${seg.jump[1]} between archives ${seg.index}/${seg.index + 1} inside the window` });
      }
      const tail = isActive ? new Map() : null;
      let r = await verifySlice(actor, seg.from, seg.to, seed, label, tail);
      let anchorHash = r.lastHash;
      let anchoredNote = "";
      if (r.truncatedAt !== null) {
        // Only the ACTIVE archive has a moving tail; a sealed one that stops
        // short lists a lastSeq it does not serve.
        if (!isActive) {
          throw new Error(`${label}: serves nothing from seq ${r.truncatedAt} but lists lastSeq ${a.lastSeq[0]} — a sealed segment has no moving tail`);
        }
        // H-18 (F10): the walk is ANCHORED (anchorTruncatedTail) or the
        // verdict is a failure / INCONCLUSIVE (unanchoredVerdict) — never
        // VALID by concession.
        console.log(`~ tail not yet readable from seq ${r.truncatedAt} (certified head at seq ${headSeq}) — re-fetching the head to anchor the walk`);
        const anch = await anchorTruncatedTail(actor, r, seed, label, tail);
        r = anch.walk;
        if (!anch.anchored) unanchoredVerdict(r, anch.headSeq ?? headSeq, totalLinks + r.links, label);
        head = anch.head; headSeq = anch.headSeq; aHead = anch.head; anchorHash = anch.anchorHash;
        anchoredNote = " (anchored after re-fetch)";
      }
      totalLinks += r.links;
      if (aHead.headHash.length && !eq(anchorHash, Buffer.from(aHead.headHash[0]))) {
        throw new Error(isActive ? "recomputed head ≠ archive head" : `${a.canisterId}: recomputed head ≠ its reported head`);
      }
      if (isActive) {
        console.log(`head ok: ${hex8(anchorHash)} == certified head at seq ${headSeq}${anchoredNote}`);
      } else {
        // W2-04: certify THIS sealed segment's head — the window visits it,
        // so it is vouched for exactly as in --full. (The active head's
        // certificate is the block after the walk, as ever.)
        const certed = await validateArchiveCert(aHead.certificate, a.canisterId, aHead.headHash, a.canisterId);
        console.log(`  head ok: ${hex8(anchorHash)} (sealed)${certed ? " [certified]" : ""}${seg.jump ? " [re-anchor claimed]" : ""}`);
      }
      carried = r.lastHash;
    }
    // Every jump inside the window — its leading clip included — must be a
    // chain-declared #gap run (collected on THIS walk: a re-anchor's
    // declarations sit at the segment's start, which a visited segment
    // always covers) or an explicit --accept-gap. Otherwise the host has
    // moved its "verification starts here" claim into the routing list, and
    // it is refused exactly as consistent-liar is (early tape omitted).
    for (const v of justifyDiscontinuities()) {
      const how = v.inChain ? "a chain-declared shed (#gap)" : "accepted by FLAG (legacy, not chain-declared)";
      if (segments[0].jump && v.from === segments[0].jump[0] && v.to === segments[0].jump[1]) {
        console.log(`  ⚠ window clipped at seq ${segments[0].from} (requested from ${requestedFrom}): [${v.from}..${v.to}) is ${how}`);
      } else {
        console.log(`  ✓ [${v.from}..${v.to}) inside the window is ${how}`);
      }
    }
    // #55.6: zero progress is refused here exactly as on the truncated-tail
    // branch above. The two honest zero-link shapes are a walk that starts at
    // the chain ORIGIN (a one-event tape) and one that starts at a
    // chain-declared re-anchor whose only event is its own #gap declaration;
    // neither is anything the host merely CLAIMED.
    if (totalLinks === 0 && segments[0].from !== ORIGIN && !anyJump) {
      throw new Error(`nothing verifiable: the host certifies a head at seq ${headSeq} but the window walked a single event with no verifiable link`);
    }
    if (segments.length > 1) {
      console.log(`  window spans ${segments.length}/${archives.length} archive(s): seqs ${segments[0].from}…${headSeq}, hash carried across ${segments.length - 1} boundary(ies)`);
    }
    if (segments[0].index > 0) {
      console.log(`  ⚠ ${segments[0].index} older sealed archive(s) hold tape below seq ${requestedFrom}, outside the window — not visited; run --full`);
    }
  } else {
    // W2-04: pin the origin — coverage starting LATER than it is a truncated
    // archive list unless a justified gap explains exactly that range.
    // #55.1: ORIGIN (above the mode split) defaults to 0, never to the
    // host's chainStartSeq claim; --expect-start is the only override.
    if (Number(archives[0].firstSeq) > ORIGIN) {
      PENDING_JUSTIFY.push({ from: ORIGIN, to: Number(archives[0].firstSeq),
        what: `history starts at seq ${archives[0].firstSeq} but the chain origin is ${ORIGIN} — early archives omitted?` });
    }
    let carried = null;
    let lastTo = null;   // #55 (1788468754): where the last walked segment ends
    for (let i = 0; i < archives.length; i++) {
      const a = archives[i];
      const isActive = i === archives.length - 1 && !a.lastSeq.length;
      const actor = i === archives.length - 1 ? activeActor : Actor.createActor(archiveIdl, { agent, canisterId: a.canisterId });
      let aHead = i === archives.length - 1 ? head : await actor.getCertifiedHead();
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
      lastTo = to;
      // W2-04: coverage continuity — an omitted middle archive is a seq jump.
      // H-18 (F21): every predecessor is SEALED by construction now
      // (validateArchiveList refused the list otherwise), so neither this
      // check nor the re-anchor justification below is guarded on its shape
      // any more — a nulled seed at i > 0 ALWAYS pushes a range to justify.
      if (i > 0) {
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
      // #55 (1788468754): in season mode a list jump after a sealed
      // predecessor is ALSO the re-anchor CLAIM itself — honored exactly as
      // tentatively (seed null, chain proof demanded below): an omitted
      // segment still fails, as "unjustified discontinuity" instead of
      // "chain BREAK". 1788474114: REANCHOR now carries the season's own
      // preserved tuples too (getSeasonGaps); the inference stays for
      // seasons closed before they were preserved — either way the chain's
      // #gap events are the only proof.
      const reanchored = i > 0 && (REANCHOR.has(Number(a.firstSeq))
        || (SEASON !== null && Number(a.firstSeq) !== Number(archives[i - 1].lastSeq[0]) + 1));
      if (reanchored) {
        PENDING_JUSTIFY.push({ from: Number(archives[i - 1].lastSeq[0]) + 1, to: Number(a.firstSeq),
          what: `re-anchor claimed at archive ${i + 1} firstSeq ${a.firstSeq}` });
      }
      const seed = reanchored ? null : carried;
      const label = `archive ${i + 1}/${archives.length} ${a.canisterId}`;
      const tail = isActive ? new Map() : null;
      let r = await verifySlice(actor, from, to, seed, label, tail);
      let anchorHash = r.lastHash;
      if (r.truncatedAt !== null) {
        // #55 (1788468754): a sealed season has no moving tail anywhere.
        if (SEASON !== null) {
          throw new Error(`season ${SEASON}: ${a.canisterId} serves nothing from seq ${r.truncatedAt} — a sealed season's tape has no moving tail`);
        }
        // Only the ACTIVE archive — the LAST entry, and open — has a moving
        // tail (H-18 / F21: the old test was lastSeq null alone, which a
        // non-final open row satisfied). A sealed one that stops short is a
        // genuine failure: it lists a lastSeq it does not serve.
        if (!isActive) {
          throw new Error(`${label}: serves nothing from seq ${r.truncatedAt} but lists lastSeq ${a.lastSeq[0]} — a sealed segment has no moving tail`);
        }
        // H-18 (F10): the old concession bounded the skew (#37.1), skipped
        // the head comparison AND validateArchiveCert below, and let the
        // active certificate vouch for a head the walk never reached. Now
        // the walk is ANCHORED at a fresh certified head (which the head
        // comparison and certificate check below then run against) or the
        // verdict is a failure / INCONCLUSIVE — never VALID by concession.
        console.log(`  ~ tail not yet readable from seq ${r.truncatedAt} (certified head at seq ${headSeq}) — re-fetching the head to anchor the walk`);
        const anch = await anchorTruncatedTail(actor, r, seed, label, tail);
        r = anch.walk;
        if (!anch.anchored) unanchoredVerdict(r, anch.headSeq ?? headSeq, totalLinks + r.links, label);
        head = anch.head; headSeq = anch.headSeq; aHead = anch.head; anchorHash = anch.anchorHash;
      }
      totalLinks += r.links;
      if (aHead.headHash.length && !eq(anchorHash, Buffer.from(aHead.headHash[0]))) {
        throw new Error(`${a.canisterId}: recomputed head ≠ its reported head`);
      }
      // W2-04: certify THIS segment's head — sealed ones included. Before
      // this, only the active archive's certificate was validated and every
      // sealed head was trusted on its own say-so.
      const certed = await validateArchiveCert(aHead.certificate, a.canisterId, aHead.headHash, a.canisterId);
      console.log(`  head ok: ${hex8(anchorHash)}${a.lastSeq.length ? " (sealed)" : " (active)"}${certed ? " [certified]" : ""}${reanchored ? " [re-anchor claimed]" : ""}`);
      carried = r.lastHash;
    }
    // W2-04 / #55.4: prove every discontinuity honored above by the chain's
    // own contiguous-merged declarations (justifyDiscontinuities — shared
    // with --last, which holds its jumps to the same bar).
    justifyDiscontinuities();
    // #55 (1788468754): the SECOND anchor for a sealed season — the head the
    // boundary committed into the SeasonRecord, and the extent it recorded.
    // The table and the record are two answers from the same host; agreeing
    // with each other AND with the certified per-segment heads is the bar.
    if (SEASON_REC) {
      const recHead = Buffer.from(SEASON_REC.chainHead[0]);
      if (carried === null || !eq(carried, recHead)) {
        throw new Error(`season ${SEASON}: walked head ${carried ? hex8(carried) : "none"} ≠ the SeasonRecord's chainHead ${hex8(recHead)} — the sealed chain does not end where the boundary committed`);
      }
      const finalSeq = Number(SEASON_REC.finalEventSeq);
      if (lastTo + 1 !== finalSeq) {
        throw new Error(`season ${SEASON}: the walked tape ends at seq ${lastTo} but the SeasonRecord's finalEventSeq is ${finalSeq} (its last event should be seq ${finalSeq - 1})`);
      }
      console.log(`  season ${SEASON} anchored: walked head == SeasonRecord.chainHead ${hex8(recHead)}, last seq ${lastTo} == finalEventSeq ${finalSeq} - 1`);
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
  if (err instanceof Inconclusive) {
    // H-18 (F10): not a failure, not a pass. Nothing below runs — the
    // certificate block would validate a head the walk never reached, and
    // "VALID" beside an unanchored walk is exactly the lie this replaces.
    console.error(`\n? INCONCLUSIVE — ${err.message}`);
    console.error("  nothing certified covers this walk; re-run later (the tape may catch up) or against another gateway. Exit 3 is NOT a pass.");
    process.exit(3);
  }
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
      // per-segment certificates where the walk visits them (--full: all of
      // them; --last: those holding tape inside the window — 1788472713).
      // The guarantee also leans on sealed
      // archives being immutable — absolute only once setBlackholeAtSeal is
      // in force (pre-mainnet checklist); until then a reinstall by the
      // controller could rewrite a sealed segment under a fresh certificate.
      // 1788472713: in --last the active head is certified HERE only (the
      // walk's validateArchiveCert ran on the visited SEALED segments), so
      // the count is not one-off the way the full walk's is.
      const sealedCerts = LAST ? certsValidated : certsValidated - 1;
      console.log(`✓ IC certificate VALID — the subnet vouches for ${SEASON !== null ? "the sealed season's final segment" : "the ACTIVE archive"}'s head${sealedCerts > 0 ? ` (+ ${sealedCerts} sealed segment(s) validated separately)` : ""}`);
      if (WINDOW && WINDOW.unvisited > 0) console.log(`  ⚠ --last mode: ${WINDOW.unvisited} sealed segment(s) below seq ${WINDOW.requestedFrom} not visited; run --full for their certificates`);
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
  // 1788474114: a sealed season's shed baselines are preserved at the
  // boundary (getSeasonShedBaselines) and the fold reset at them above —
  // the "healed by" line below then reads from the preserved tuples. Only a
  // season closed BEFORE that landed (or a pre-1788474114 backend) has
  // chain-declared gaps with no reset points; say so instead of folding on
  // silently.
  if (SEASON !== null && CHAIN_GAPS.length && !BASELINES.length) {
    console.log(`  ⚠ season fold across ${CHAIN_GAPS.length} chain-declared gap(s): no shed re-baselines were preserved for season ${SEASON} (closed before 1788474114), so balances cannot be reconstructed through a dropped range`);
  }
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
