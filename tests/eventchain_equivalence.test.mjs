#!/usr/bin/env node
// tests/eventchain_equivalence.test.mjs — cross-encoder byte equivalence for
// the frozen v1 canonical event form (#44.4 residual; factory task 1787182535).
//
// Three hand-written copies of the canonical encoder exist:
//   1. src/backend/lib/EventChain.mo           (the origin — Motoko)
//   2. src/frontend/src/ledger.js              canonicalEvent()/hashEvent()
//   3. scripts/verify_ledger.mjs               canonical()/hashEvent()
// EventChain itself is NOT untested (tests/EventChain.test.mo, W2-01) and the
// standalone verifier is executed by tests/test_verify_ledger_gate.sh (W5-09);
// what no gate asserted before this file is MIRROR DIVERGENCE — that all
// three produce IDENTICAL BYTES for the same event.
//
// Mechanism (offline, no venue, no replica):
//   * The pinned vectors are PARSED OUT OF tests/EventChain.test.mo (the
//     MDX-VECTORS block) — the single pin, produced by the Motoko encoder and
//     re-asserted against it on every `mops test`. There is deliberately no
//     second committed copy that could drift from the first.
//   * The fixture events below MIRROR the Motoko fixture list exactly (same
//     names, same order, same values) in candid-decoded shape.
//   * Both JS encoders run over every fixture:
//       - ledger.js is imported directly (it is side-effect-free at module
//         top level; WebCrypto is global in node >= 19);
//       - verify_ledger.mjs cannot be imported (it talks to a host at top
//         level), so canonical()/hashEvent() are SLICED out of the real file
//         by marker and evaluated — the same correct-by-construction
//         technique as tests/fixtures/verify-ledger-stub/stub-agent.js.
//   * Every canonical byte string and every SHA-256 must equal the pin.
// Any one encoder drifting in field order/format goes red here or in
// `mops test` — which is the whole point.

import { readFileSync } from "node:fs";

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`✓ ${name}`); }
  else { failed++; console.log(`✗ ${name}`); if (detail) console.log(`    ${detail}`); }
}
const hexOf = (b) => Buffer.from(b).toString("hex");

// ── 1. The pin, parsed from the Motoko test (the single source) ──────
const moUrl = new URL("./EventChain.test.mo", import.meta.url);
const moSrc = readFileSync(moUrl, "utf8");
const block = moSrc.match(/MDX-VECTORS-BEGIN([\s\S]*?)MDX-VECTORS-END/);
if (!block) {
  console.log("✗ tests/EventChain.test.mo has no MDX-VECTORS block — nothing to hold the JS mirrors to");
  process.exit(1);
}
const pin = [];
const tupleRe = /\(\s*"([^"]+)",\s*"([0-9a-f]*)",\s*"([0-9a-f]{64})"\s*\)/g;
for (let m; (m = tupleRe.exec(block[1])); ) pin.push({ name: m[1], canon: m[2], hash: m[3] });
check("pin parsed from EventChain.test.mo (>= 22 vectors)", pin.length >= 22, `got ${pin.length}`);

// ── 2. The fixture twins (MIRROR of the Motoko list — edit together) ─
const P = (t) => ({ toText: () => t });
const A = P("2vxsx-fae"), B = P("aaaaa-aa");
const prev32 = new Uint8Array(Array.from({ length: 32 }, (_, i) => i));
const ev = (kind) => ({ seq: 7n, ts: 1723456789000000123n, user: A, counterparty: [], prevHash: [], kind });
const fixtures = [
  ["fill-buy", ev({ fill: { marketId: "ICP-ICPUSD", side: { buy: null }, price: 105000000n, qty: 250000000n, orderId: 42n, tradeId: 9001n } })],
  ["fill-sell-linked", { seq: 8n, ts: 1723456789000000124n, user: A, counterparty: [B], prevHash: [prev32],
    kind: { fill: { marketId: "BTC-ICPUSD", side: { sell: null }, price: 6500000000000n, qty: 1000n, orderId: 7n, tradeId: 8n } } }],
  ["deposit", ev({ deposit: { token: "ICP", amount: 500000000n, timestamp: 1723000000000000000n, kind: { deposit: null } } })],
  ["withdrawal", ev({ deposit: { token: "USDT", amount: 25000000n, timestamp: 1723000000000000001n, kind: { withdrawal: null } } })],
  ["orderClosed-filled-market", ev({ orderClosed: { id: 11n, marketId: "ICP-ICPUSD", side: { buy: null }, orderType: { market: null }, price: 100000000n, quantity: 3000000n, filled: 3000000n, status: { filled: null }, placedAt: 1723000000000000002n, closedAt: 1723000000000000003n } })],
  ["orderClosed-cancelled-limit", ev({ orderClosed: { id: 12n, marketId: "BTC-ICPUSD", side: { sell: null }, orderType: { limit: null }, price: 99000000n, quantity: 5n, filled: 0n, status: { cancelled: null }, placedAt: 1723000000000000004n, closedAt: 1723000000000000005n } })],
  ["orderClosed-open-market", ev({ orderClosed: { id: 13n, marketId: "ICP-ICPUSD", side: { buy: null }, orderType: { market: null }, price: 1n, quantity: 2n, filled: 1n, status: { open: null }, placedAt: 1723000000000000006n, closedAt: 1723000000000000007n } })],
  ["orderClosed-partial-limit", ev({ orderClosed: { id: 14n, marketId: "ICP-ICPUSD", side: { sell: null }, orderType: { limit: null }, price: 42n, quantity: 10n, filled: 4n, status: { partiallyFilled: null }, placedAt: 1723000000000000008n, closedAt: 1723000000000000009n } })],
  ["liquidation", ev({ liquidation: { user: B, debtToken: "USDT", debtRepaid: 1000000n, debtRepaidUsd: 1000000n, collateralToken: "ICP", collateralSeized: 120000n, proceedsUsd: 1050000n, penaltyUsd: 50000n, healthBefore: 95000000n, healthAfter: 101000000n, timestamp: 1723000000000000010n } })],
  ["borrow", ev({ borrow: { token: "ICP", amount: 77000n } })],
  ["repay", ev({ repay: { token: "USDT", amount: 88000n } })],
  ["lpDeposit", ev({ lpDeposit: { marketId: "ICP-ICPUSD", baseAmount: 1000n, quoteAmount: 2000n, lpMinted: 1414n } })],
  ["lpWithdraw-basket2", ev({ lpWithdraw: { lpBurned: 500n, basket: [["ICP", 300n], ["USDT", 600n]] } })],
  ["lpWithdraw-empty", ev({ lpWithdraw: { lpBurned: 1n, basket: [] } })],
  ["insuranceStake", ev({ insuranceStake: { amountUsd: 10000000n, shares: 9999n } })],
  ["insuranceUnstake", ev({ insuranceUnstake: { shares: 9999n, payoutUsd: 10100000n } })],
  ["delta-negative", ev({ delta: { token: "ICP", amount: -123456789n } })],
  ["debtDelta-negative", ev({ debtDelta: { token: "USDT", amount: -1n } })],
  ["lpShareDelta-negative", ev({ lpShareDelta: { marketId: "ICP-ICPUSD", amount: -42n } })],
  ["insShareDelta-positive", ev({ insShareDelta: { amount: 314159n } })],
  ["gap", ev({ gap: { fromSeq: 1000n, toSeq: 2000n } })],
  ["config", ev({ config: { setter: "setAutoFuel", value: "disabled" } })],
];
check("fixture twins cover the pin 1:1 (same names, same order)",
  fixtures.length === pin.length && fixtures.every(([n], i) => n === pin[i].name),
  `fixtures: ${fixtures.map(([n]) => n).join(",")}\n    pin:      ${pin.map((v) => v.name).join(",")}`);

// ── 3. Encoder 2: the frontend mirror, imported directly ─────────────
const ledger = await import(new URL("../src/frontend/src/ledger.js", import.meta.url).href);
if (typeof ledger.canonicalEvent !== "function" || typeof ledger.hashEvent !== "function") {
  console.log("✗ ledger.js does not export canonicalEvent/hashEvent — the frontend mirror moved; update this suite");
  process.exit(1);
}

// ── 4. Encoder 3: the verifier mirror, sliced by marker ──────────────
// (verify_ledger.mjs executes a network walk at top level, so it cannot be
// imported whole; same slice-and-eval as the W5-09 hostile-host stub, and
// the same refusal to proceed if the slice no longer contains the encoder.)
const vlLines = readFileSync(new URL("../scripts/verify_ledger.mjs", import.meta.url), "utf8").split("\n");
const sIdx = vlLines.findIndex((l) => /^const enc = /.test(l));
const eIdx = vlLines.findIndex((l) => /^const eq = /.test(l));
const sliced = sIdx >= 0 && eIdx > sIdx ? vlLines.slice(sIdx, eIdx + 1).join("\n") : "";
if (!/function canonical/.test(sliced) || !/const hashEvent/.test(sliced)) {
  console.log("✗ could not slice canonical()/hashEvent() out of scripts/verify_ledger.mjs — the marker window moved; update this suite (and the W5-09 stub, which uses the same markers)");
  process.exit(1);
}
const verifier = await import(
  "data:text/javascript," + encodeURIComponent(
    'import { createHash } from "node:crypto";\n' + sliced + "\nexport { canonical, hashEvent };\n"
  )
);

// ── 5. Byte-for-byte equivalence against the Motoko-produced pin ─────
let ledgerOk = 0, verifierOk = 0;
for (let i = 0; i < Math.min(fixtures.length, pin.length); i++) {
  const [name, e] = fixtures[i];
  const want = pin[i];

  const lCanon = hexOf(ledger.canonicalEvent(e));
  const lHash = hexOf(await ledger.hashEvent(e));
  if (lCanon === want.canon && lHash === want.hash) ledgerOk++;
  else check(`ledger.js == Motoko for '${name}'`, false,
    `canonical want ${want.canon}\n    canonical got  ${lCanon}\n    hash want ${want.hash}\n    hash got  ${lHash}`);

  const vCanon = hexOf(verifier.canonical(e));
  const vHash = hexOf(verifier.hashEvent(e));
  if (vCanon === want.canon && vHash === want.hash) verifierOk++;
  else check(`verify_ledger.mjs == Motoko for '${name}'`, false,
    `canonical want ${want.canon}\n    canonical got  ${vCanon}\n    hash want ${want.hash}\n    hash got  ${vHash}`);
}
check(`ledger.js canonicalEvent/hashEvent reproduce all ${pin.length} Motoko vectors byte-for-byte`, ledgerOk === pin.length, `${ledgerOk}/${pin.length}`);
check(`verify_ledger.mjs canonical/hashEvent reproduce all ${pin.length} Motoko vectors byte-for-byte`, verifierOk === pin.length, `${verifierOk}/${pin.length}`);

// ── Verdict ──────────────────────────────────────────────────────────
console.log(`\n${failed === 0 ? "ALL GREEN" : "FAILURES"}: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log("A red here means one of the three canonical encoders drifted in field order/format.");
  console.log("The v1 form is FROZEN — fix the drifted mirror; never regenerate the pin to match it.");
}
process.exit(failed === 0 ? 0 : 1);
