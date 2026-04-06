# Architecture

How the codex-mobile-companion system works at a high level.

**What belongs here:** System architecture, component relationships, data flows, invariants.
**What does NOT belong here:** Implementation details, code snippets, env vars (use `environment.md`).

---

## System Overview

The system connects a Flutter mobile app to a locally running Codex session through a Rust bridge server. The mobile app never communicates directly with the Codex app-server.

```
[Flutter Mobile App] ←→ [Rust Bridge Server] ←→ [Codex App-Server]
      (HTTP + WS)            (JSON-RPC over WS)       (local process)
```

## Components

### 1. Bridge Server (`crates/bridge-core/`)

Rust HTTP server (Axum) on configurable port (default 3210). Central hub between mobile and Codex.

- **Codex transport** — connects to local Codex app-server via WebSocket (JSON-RPC) on port 4222
- **Two-step handshake** — `initialize` request + `initialized` notification required before any session activity
- **Thread actors** — one actor per thread, each backed by `std::thread` + `mpsc` channel for notification routing
- **Event hub** — publish/subscribe system for streaming events to mobile clients over WebSocket SSE
- **Pairing/trust** — Ed25519-based device authentication and trust registry
- **Access modes** — `read_only`, `control_with_approvals`, `full_control` — gate destructive operations
- **Codex lifecycle** — auto-spawns or attaches to a running Codex app-server process

### 2. Codex App-Server (External)

Local Codex JSON-RPC server on port 4222. Managed by the bridge; not directly accessible to mobile.

- Thread creation, turn management, and live streaming via JSON-RPC notifications
- The bridge wraps and secures its entire API surface

### 3. Flutter Mobile App (`apps/mobile/`)

Cross-platform app targeting iOS and Android.

- **HTTP client** — bridge REST API for thread CRUD, turns, approvals, git operations
- **WebSocket client** — live event streaming from bridge
- **State management** — Riverpod controllers (`ThreadDetailController`, `ThreadListController`) with `autoDispose`
- **Navigation** — Go Router
- **Security** — secure key storage for pairing/trust credentials
- **Resilience** — reconnection handling for flaky mobile connections

### 4. Shared Contracts (`crates/shared-contracts/` + `shared/contracts/`)

DTOs and schema fixtures shared across bridge and mobile app.

- Thread snapshots, live events, approval records, settings
- Versioned contract fixtures for cross-platform consistency

## Data Flows

### Thread Creation

```
Mobile → POST /threads → Bridge → Codex thread/start → Codex thread/read
→ Bridge returns ThreadSnapshotDto → Mobile
```

### Turn Execution

```
Mobile → POST /threads/{id}/turns → Bridge → Codex turn/start
→ Bridge opens notification stream
→ Live events: Codex → Bridge notification actor → EventHub → WebSocket SSE → Mobile
→ Mobile controller updates state in real-time
→ Turn completes on Codex turn/completed
```

### Live Streaming

1. Mobile opens WebSocket to `/events?scope=thread&thread_id=X`
2. Bridge subscribes to Codex notification stream for that thread
3. Codex sends JSON-RPC notifications (`item/started`, `item/agentMessage/delta`, `item/completed`, `turn/completed`)
4. Bridge normalizes and publishes via event hub
5. Mobile receives `BridgeEventEnvelope`, updates controller state

### Approval Flow

1. Mobile triggers git operation (branch switch, pull)
2. Bridge checks access mode → if `control_with_approvals`, creates approval record
3. Approval appears in mobile approvals queue
4. User approves or rejects from mobile
5. Bridge executes or cancels the operation

## Key Invariants

1. **Mobile NEVER connects directly to Codex** — always through bridge
2. **Thread IDs are provider-prefixed** — `codex:<uuid>`
3. **Error responses use consistent JSON** — `ErrorEnvelope` format with `message` and `code`
4. **Two-step handshake required** — `initialize` + `initialized` for Codex transport
5. **Events carry `event_id`** — for deduplication on mobile side
6. **Access mode gates destructive operations** — git branch-switch, pull, etc.

## State Management

### Bridge State (`BridgeAppState`)

Main state container holding:
- Thread runtimes (one per active thread)
- Gateway (Codex + Claude connections)
- Event hub (publish/subscribe)
- Approval queue
- Access mode setting
- Pairing/trust registry

### Mobile State (Riverpod)

- **`ThreadDetailController`** — single thread view, live streaming, composer mutations
- **`ThreadListController`** — thread list, workspace selection
- Controllers use `autoDispose` — state is lost when UI navigates away

## File Layout (Key Paths)

### Bridge Server
| Path | Purpose |
|------|---------|
| `crates/bridge-core/src/server/api.rs` | HTTP API handlers |
| `crates/bridge-core/src/server/gateway/codex/` | Codex connection management |
| `crates/bridge-core/src/server/gateway/codex/actor.rs` | Per-thread notification actors |
| `crates/bridge-core/src/server/state/` | State management modules |
| `crates/bridge-core/src/server/events.rs` | Event hub |

### Mobile App
| Path | Purpose |
|------|---------|
| `apps/mobile/lib/foundation/network/` | Transport layer |
| `apps/mobile/lib/features/threads/data/` | API clients |
| `apps/mobile/lib/features/threads/application/` | Controllers |
| `apps/mobile/lib/features/threads/presentation/` | UI pages |
| `apps/mobile/integration_test/` | Live integration tests |
| `apps/mobile/integration_test/support/` | Shared test helpers |

## Thread Lifecycle

```
idle → running → completed
                 ↘ interrupted
                 ↘ failed
      ↘ pending_user_input → (user responds) → running → ...
```
