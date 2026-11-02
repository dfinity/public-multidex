// ── Demo / mock mode (#54.9) ──────────────────────────────────────
// The init path in main.js catches EVERY throw (SDK import, agent creation,
// the first markets query) and falls back to a built-in mock actor so the
// page still paints. The mock serves a populated venue — fabricated prices,
// balances, a 500T-cycle canister — which is fine for a screenshot and a
// disaster for a user whose SDK load failed for any reason: a working-looking
// exchange with made-up numbers and no way to tell (OhShii round 18, #54.9).
//
// This module makes the state UNMISTAKABLE and derives it from actor IDENTITY,
// not from the code path that got there:
//   · createMockActor() stamps the object it returns (a non-enumerable
//     Symbol-keyed mark — invisible to JSON, iteration and the IDL);
//   · isMockActor(x) is the ONE predicate; appState.actor IS the mock or it
//     is not. Any future fallback that swaps the mock in lights the marker
//     without being told, because the render path asks the object, not the
//     caller.
//   · renderDemoMarker() — called from updateUI() on every auth/actor change —
//     shows the persistent #demo-banner and disables every sign-in button
//     with a stated reason; demoSignInRefusal() is what login() consults so
//     the click handler refuses even if a button slipped the disable.
// Rejected shape: a toast at the catch site (transient; the page would then
// read as live for the rest of the session).
//
// Import-clean under plain node with a stub `document` (no main.js
// dependency), so tests/frontend_security.test.mjs exercises the real
// fallback — setupDemoMode() is the exact function the init catch calls.
import { appState } from "./state.js";

// Symbol.for so the mark survives duplicated module instances (two bundles,
// an HMR reload) — the registry key is the identity, not this module's copy.
const MOCK_ACTOR_MARK = Symbol.for("mdx.mockActor");

export function markMockActor(actor) {
  Object.defineProperty(actor, MOCK_ACTOR_MARK, {
    value: true, enumerable: false, configurable: false, writable: false,
  });
  return actor;
}

// THE predicate. Identity, never shape: a real actor that happens to expose
// the same methods is not a mock, and a mock wrapped in another object is
// (see wrap below) — only the stamp counts.
export function isMockActor(actor) {
  return !!actor && actor[MOCK_ACTOR_MARK] === true;
}

export const DEMO_BANNER_ID = "demo-banner";
export const DEMO_SIGNIN_REASON =
  "Sign-in is disabled in demo mode: the exchange could not be reached, so nothing on this page is live. Reload to reconnect.";
// Every sign-in affordance the shell renders (header CTA, the Account/AI/
// explorer sign-in cards, the order-panel overlay, the deposit verify card).
// Buttons that don't exist yet when the marker renders are still covered by
// the login() refusal — this list is the disable, demoSignInRefusal() the wall.
export const DEMO_SIGNIN_BUTTON_IDS = [
  "auth-btn", "account-signin-btn", "intelli-signin-btn",
  "order-panel-signin-btn", "dx-signin-btn", "deposit-verify-signin",
];
const GATED_CLASS = "signin-demo-off";

// The init fallback (and sign-out with no II client): swap the mock in.
// Deliberately does NOT render — updateUI() is the single render path and
// every caller reaches it; the marker must never depend on this function
// remembering to light it.
export function setupDemoMode() {
  appState.actor = createMockActor();
  appState.publicActor = appState.actor;
  appState.isAuthenticated = false;
}

// The reason sign-in is refused right now, or null when it may proceed.
export function demoSignInRefusal() {
  return isMockActor(appState.actor) ? DEMO_SIGNIN_REASON : null;
}

// Idempotent. Returns whether the page is in demo mode after the pass.
export function renderDemoMarker() {
  const demo = isMockActor(appState.actor);
  const el = document.getElementById(DEMO_BANNER_ID);
  if (el) {
    if (demo) {
      el.innerHTML =
        `<span class="demo-mark" aria-hidden="true">⚠</span>` +
        `<strong>DEMO MODE — NOT LIVE.</strong> The exchange could not be reached, so this page is ` +
        `running on a built-in mock: every price, balance and figure shown is fabricated placeholder ` +
        `data. Nothing here is real and sign-in is disabled. `;
      const b = document.createElement("button");
      b.className = "demo-reload";
      b.type = "button";
      b.textContent = "Reload to reconnect";
      b.addEventListener("click", () => { try { location.reload(); } catch {} });
      el.appendChild(b);
      el.style.display = "block";
    } else {
      el.style.display = "none";
    }
  }
  for (const id of DEMO_SIGNIN_BUTTON_IDS) {
    const btn = document.getElementById(id);
    if (!btn) continue;
    if (demo) {
      btn.disabled = true;
      btn.title = DEMO_SIGNIN_REASON;
      btn.setAttribute("aria-disabled", "true");
      btn.classList.add(GATED_CLASS);
      // The header CTA's label is re-derived by updateUI() on every pass, so
      // it is safe to overwrite here; the others keep their static copy.
      if (id === "auth-btn") btn.textContent = "Sign-in disabled";
    } else if (btn.classList.contains(GATED_CLASS)) {
      // Only undo what THIS gate did — a healthy-path disable set elsewhere
      // (an in-flight sign-in, say) is not ours to clear.
      btn.disabled = false;
      btn.title = "";
      btn.removeAttribute("aria-disabled");
      btn.classList.remove(GATED_CLASS);
    }
  }
  return demo;
}

export function createMockActor() {
  const balances = {};
  const orders = [];
  const deposits = [];
  let nextId = 1;

  return markMockActor({
    addTestTokens: async (token, amount) => {
      balances[token] = (balances[token] || 0) + amount;
      deposits.push({ token, amount, timestamp: Date.now() * 1000000, kind: { deposit: null } });
    },
    getBalances: async () => {
      return Object.entries(balances).filter(([_, v]) => v > 0.0001);
    },
    getBalance: async (token) => balances[token] || 0,
    getMarkets: async () => [
      { id: "BTC-ICPUSD", baseToken: "BTC", quoteToken: "ICPUSD", lastPrice: 67500.0, volume24h: 8_215_000.0, priceChange24hAbs:  1550.00, markPrice: 67510.0 },
      { id: "ETH-ICPUSD", baseToken: "ETH", quoteToken: "ICPUSD", lastPrice:  3450.0, volume24h: 2_110_000.0, priceChange24hAbs:   -39.12, markPrice:  3451.0 },
      { id: "ICP-ICPUSD", baseToken: "ICP", quoteToken: "ICPUSD", lastPrice:    12.5, volume24h:   340_000.0, priceChange24hAbs:     0.0, markPrice:    12.5 },
    ],
    getOrderBook: async () => ({
      bids: [
        { price: 67400, quantity: 0.5, orderCount: 3 },
        { price: 67300, quantity: 1.2, orderCount: 5 },
        { price: 67200, quantity: 0.8, orderCount: 2 },
      ],
      asks: [
        { price: 67600, quantity: 0.3, orderCount: 2 },
        { price: 67700, quantity: 0.9, orderCount: 4 },
        { price: 67800, quantity: 1.5, orderCount: 6 },
      ],
      spread: 200,
    }),
    getRecentTrades: async () => {
      const now = Date.now() * 1000000;
      return [
        { id: 1n, marketId: "BTC-ICPUSD", side: { buy: null },  price: 67010, quantity: 0.12, timestamp: now - 40000000000 },
        { id: 2n, marketId: "BTC-ICPUSD", side: { sell: null }, price: 67120, quantity: 0.08, timestamp: now - 25000000000 },
        { id: 3n, marketId: "BTC-ICPUSD", side: { sell: null }, price: 67080, quantity: 0.21, timestamp: now - 9000000000 },
        { id: 4n, marketId: "BTC-ICPUSD", side: { buy: null },  price: 67200, quantity: 0.05, timestamp: now - 2000000000 },
      ];
    },
    getRecentEvents: async () => {
      const now = Date.now() * 1000000;
      return [
        { id: 4, ts: now - 5000000000,   severity: "info",  category: "swap",   message: "Swap 50.00 ICP → 0.02 BTC", market: ["BTC-ICPUSD"] },
        { id: 3, ts: now - 60000000000,  severity: "warn",  category: "amm",    message: "BTC oracle stale — AMM widening quotes (+1.20% half-spread)", market: ["BTC-ICPUSD"] },
        { id: 2, ts: now - 90000000000,  severity: "warn",  category: "oracle", message: "BTC price feed degraded to 5/6 sources ($67,000.00)", market: ["BTC-ICPUSD"] },
        { id: 1, ts: now - 120000000000, severity: "info",  category: "oracle", message: "BTC price feed recovered to 6/6 sources", market: ["BTC-ICPUSD"] },
      ];
    },
    getAllTrades: async () => [],
    getCandles: async () => ({ candles: [], hasMore: false }),
    getTradesSince: async () => [],
    getUserStatus: async () => ({ version: 0n, lastTradeTime: 0n, openOrderCount: 0n }),
    getMyTradeHistorySince: async () => [],
    getMarketStatus: async () => ({ version: 0n, lastTradeId: 0n }),
    getRecentPublicTrades: async () => [],
    getPublicTradesSince: async () => [],
    getMarketChanges: async () => ({
      marketStatus: [], orderBook: [], orderBookDelta: [], newTrades: [],
      userStatus: [], userOpenOrders: [], userBalances: [], newUserTrades: [],
    }),
    getMyOrders: async () => orders.filter((o) => o.status.open !== undefined || o.status.partiallyFilled !== undefined),
    getMyClosedOrders: async () => [
      {
        id: 9002n, marketId: "BTC-ICPUSD", side: { sell: null }, orderType: { limit: null },
        price: 68120.0, quantity: 0.25, filled: 0.25, status: { filled: null },
        placedAt: (BigInt(Date.now()) - 7_200_000n) * 1_000_000n,
        closedAt: (BigInt(Date.now()) - 3_600_000n) * 1_000_000n,
      },
      {
        id: 9001n, marketId: "ETH-ICPUSD", side: { buy: null }, orderType: { limit: null },
        price: 1580.0, quantity: 2.0, filled: 0.0, status: { cancelled: null },
        placedAt: (BigInt(Date.now()) - 86_400_000n) * 1_000_000n,
        closedAt: (BigInt(Date.now()) - 82_800_000n) * 1_000_000n,
      },
    ],
    getMyOrdersOnMarket: async () => [],
    getMyStagedOrderIds: async () => [],
    getMyRecentSwap: async () => [],
    placeLimitOrder: async (market, side, price, qty) => {
      const o = { id: nextId++, marketId: market, owner: "demo", side, orderType: { limit: null }, price, quantity: qty, filled: 0, status: { open: null }, timestamp: Date.now() * 1000000, originalQuantity: qty };
      orders.push(o);
      return { ok: o };
    },
    placeLimitOrderExp: async (market, side, price, qty) => {
      const o = { id: nextId++, marketId: market, owner: "demo", side, orderType: { limit: null }, price, quantity: qty, filled: 0, status: { open: null }, timestamp: Date.now() * 1000000, originalQuantity: qty };
      orders.push(o);
      return { ok: o };
    },
    placeMarketOrder: async () => ({ ok: { trades: [], remainingQty: 0, totalFilled: 0, avgPrice: 0 } }),
    swap: async () => ({ ok: { fromAmount: 0, toAmount: 0, fullyFilled: false, swapOrderId: [] } }),
    cancelMyOrder: async (id) => {
      const idx = orders.findIndex((o) => Number(o.id) === Number(id));
      if (idx >= 0) orders[idx].status = { cancelled: null };
      return { ok: null };
    },
    whoami: async () => "demo-principal",
    getMyProfile: async () => ({
      userId: "DEMO",
      username: "Swift-Fox-42",
      regenCount: 0,
      createdAt: Date.now() * 1000000,
    }),
    regenerateUsername: async () => ({ ok: { userId: "DEMO", username: "Brave-Hawk-17", regenCount: 1, createdAt: Date.now() * 1000000 } }),
    getMyTradeHistory: async () => [],
    getMyAdjustments: async () => [],
    getMyDeposits: async () => deposits,
    getCanisterInfo: async () => ({
      canisterId: "rdmx6-jaaaa-aaaaa-aaadq-cai", cycles: 500_000_000_000_000n,
      freezingLimitCycles: 1_500_000_000_000n,
      burnPerDay: 4_200_000_000_000n, idleBurnPerDay: 1_400_000_000_000n,
      computeAllocation: 0n,
      lastHeartbeatNs: BigInt(Date.now()) * 1_000_000n,
      nowNs: BigInt(Date.now()) * 1_000_000n, timersPaused: false,
      memorySizeBytes: 268_435_456n, heapLiveBytes: 201_326_592n,
      wasmMemoryLimitBytes: 4_294_967_296n, lowMemoryAtNs: 0n, ordersRetained: 1_204n,
      tradesRetained: 5_877n, usersRegistered: 42n,
      journalUnshipped: 2n, ledgerJournalPending: 0n, archivedEvents: 18_344n,
      archiveCanisterId: ["rrkah-fqaaa-aaaaa-aaaaq-cai"],
      pendingSpawn: [],
      archivesSealed: 0n,
      archiveCycles: 2_000_000_000_000n, archiveLifetimeTopUp: 0n,
      autoFuelEnabled: true, fuelRouteWired: true, fuelLifetimeCycles: 0n,
      fuelPendingNotify: [],
      treasuryUsdE8s: 96_260_607_603_700n, treasuryIcpE8s: 5_000_000_000n,
      oracleDivergence: [],
    }),
  });
}
