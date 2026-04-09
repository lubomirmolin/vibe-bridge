# Architecture

Architecture decisions, module boundaries, and patterns discovered during planning.

**What belongs here:** stable architectural decisions, canonical paths, and boundaries workers should preserve.

---

- Product shape:
  - `apps/mobile` — Flutter app for iOS and Android
  - `apps/mac-shell` — SwiftUI macOS shell (`CodexMobileCompanion.xcodeproj`, scheme `CodexMobileCompanion`)
  - `crates/bridge-core` — Rust bridge core, package `bridge-core`, binary `bridge-server`
  - `crates/shared-contracts` — Rust shared DTO/event contract crate consumed by bridge code and fixtures/tests
  - `shared/contracts` — canonical cross-platform JSON fixtures and wire-shape examples for shared contracts
- `codex app-server` is the primary integration surface. The phone must never talk to it directly.
- The Rust bridge owns the stable REST/WebSocket product API and normalizes upstream experimental protocol changes.
- For the thread timeline, correctness depends on consistent ordering across the bridge snapshot page and the Flutter thread-detail controller; fixes should prefer preserving stable per-event identity and deterministic page boundaries over UI-only workarounds.
- Real-data parity mission target: thread `019d0d0c-07df-7632-81fa-a1636651400a` (`Investigate thread detail sync`). Treat this thread as the canonical regression source when deciding whether a bridge/mobile behavior is truthful.
- Bridge detail truth and bridge timeline truth must stay coherent for the same thread. If `/threads/:id` and `/threads/:id/timeline` disagree on freshness, summary, or status, fix the bridge merge/model logic before tuning Flutter presentation.
- Current performance investigation shows the thread-detail initial-open path pays for two sequential backend reads (`/threads/:id` then `/threads/:id/timeline`) and both routes currently trigger per-thread sync/archive work. Backend-first speed work should eliminate duplicate sync cost before changing UI behavior.
- Flutter thread detail currently depends on both controller-level visibility filtering and widget-level hiding. Pagination or hydration fixes must account for rows that exist in the data model but intentionally collapse away in the rendered timeline.
- Flutter thread-detail validation for this mission must use real-thread-backed payloads captured from the live bridge; synthetic-only fixtures are not sufficient for parity decisions.
- Thread switching correctness includes in-flight HTTP responses, reconnect catch-up, and late live events from the previously selected thread. Do not limit race hardening to websocket filtering only.
- For this mission, the newer current mobile UX is the source of truth. If baseline tests still assert older copy, hooks, or navigation details, update those tests unless a genuine user-visible regression is proven.
- `Codex.app` is a secondary desktop consumer only. Use supported open/refresh compatibility paths; never automate its UI.
- Tailscale is transport only. Pairing, trust, permissions, and auditability are product responsibilities.
- One phone pairs to one Mac at a time; fail closed on revoked trust or identity mismatch.
- Debug-only pairing helpers are acceptable for validation builds, but they must remain confined to the scan/pairing flow and must not alter release trust semantics.
