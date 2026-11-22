// ── Shared app state ───────────────────────────────────────────────
// The cross-cutting singletons read by BOTH main.js and the extracted feature
// modules (data explorer, assistant). Held on one mutable object so the modules
// can share them WITHOUT an import cycle: every module imports `appState` from
// here; main.js owns the writes (sign-in, actor creation). Reading a field
// always sees the latest value — `appState.actor` is the live actor.
export const appState = {
  actor: null,           // authenticated backend actor (null until sign-in)
  publicActor: null,     // anonymous actor for pre-login queries
  archiveActor: null,    // lazily-built actor for the archive sidecar canister
  isAuthenticated: false,
  myPrincipalText: null, // cached principal text, populated on sign-in
  intelliTab: "ai",      // active Intelli sub-tab ("ai" | "explorer") — Agent Chat is the default; shared by main.js routing + explorer.js (stays reachable with no AI key: help-only mode, task 1793489932)
  deployMode: "dev",     // backend posture ("dev" | "play" | "production"), fetched at startup — drives the on-ramp button
  aiConfigured: null,    // whether the backend has an AI key set — null until the startup probe answers, then true/false; false puts Agent Chat in help-only mode (Docs answers, no model call)
  login: null,           // main.js's login() — feature modules trigger sign-in through this (never a bare `login` global)
  getUserProfile: null,  // () => the live userProfile main.js maintains (username etc.), or null pre-login
};
