# Bridge Rewrite Plan

This document is the source of truth for the `bridge-core` rewrite.

The current bridge is too complex because it combines:

- live app-server transport handling
- notification forwarding
- synthetic timeline/event generation
- archive parsing and archive-time event reconstruction
- watchdog completion repair
- projection/cache reconciliation

That layering creates multiple competing sources of truth and is the reason live bridge behavior diverges from Codex itself.

This rewrite drops that architecture and rebuilds the bridge around one rule:

`codex app-server` is authoritative for loaded threads and active turns.

## Grounding In Codex

Reference sources in `tmp/codex/codex-rs/app-server`:

- [README.md](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/README.md)
- [initialize.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/tests/suite/v2/initialize.rs)
- [thread_start.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/tests/suite/v2/thread_start.rs)
- [thread_read.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/tests/suite/v2/thread_read.rs)
- [turn_start.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/tmp/codex/codex-rs/app-server/tests/suite/v2/turn_start.rs)

Important protocol facts we must mirror:

- Each connection must send `initialize`, then `initialized`.
- `thread/start` creates a thread and emits `thread/started`.
- `turn/start` immediately returns a turn object, then streams notifications on the same connection.
- `turn/completed` is the authoritative end of the live turn.
- `thread/read` and `thread/list` expose persisted threads without requiring our own archive parser to invent lifecycle state.

## Rewrite Goals

1. Make the bridge a thin protocol adapter, not a second runtime.
2. Split large files into small focused modules.
3. Remove archive-driven completion logic for live Codex turns.
4. Remove synthetic event reconstruction that guesses at timeline meaning.
5. Use stable upstream ids and notifications instead of semantic dedupe.
6. Keep mobile-facing DTOs and HTTP routes only where they are still needed.
7. Prefer deleting code over preserving backwards compatibility.

## Hard Rules

1. One source of truth for live turns:
   live app-server notifications on the active thread connection.
2. One source of truth for loaded thread snapshots:
   `thread/read` or equivalent app-server read on demand.
3. Archive access is cold-start recovery only:
   use it only when app-server cannot provide a thread because it is not loaded.
4. No watchdog that fabricates completion from archive state while a live turn is in progress.
5. No completion-time snapshot refresh that can overwrite fresher live state with stale archive state.
6. No semantic message dedupe based on text content for Codex events.
7. No new god files:
   new modules should usually stay below about 300-400 lines unless there is a strong reason.

## Target Architecture

New `bridge-core` thread stack:

### 1. App-server client layer

Purpose:
- own JSON-RPC transport
- initialize connections correctly
- issue thread/turn/read/list calls
- surface notifications without bridge-specific interpretation

Planned modules:

- `crates/bridge-core/src/codex/client/mod.rs`
- `crates/bridge-core/src/codex/client/connection.rs`
- `crates/bridge-core/src/codex/client/requests.rs`
- `crates/bridge-core/src/codex/client/notifications.rs`
- `crates/bridge-core/src/codex/client/types.rs`

### 2. Live session layer

Purpose:
- manage one active live session per loaded thread
- subscribe to thread events
- keep the stream open through turn completion
- publish normalized bridge events directly from app-server notifications

Planned modules:

- `crates/bridge-core/src/threads/live/mod.rs`
- `crates/bridge-core/src/threads/live/session.rs`
- `crates/bridge-core/src/threads/live/registry.rs`
- `crates/bridge-core/src/threads/live/mapper.rs`

### 3. Read model layer

Purpose:
- convert authoritative app-server thread data into bridge DTOs
- hold a minimal in-memory cache only for HTTP responsiveness
- never synthesize completion from unrelated data sources

Planned modules:

- `crates/bridge-core/src/threads/read_model/mod.rs`
- `crates/bridge-core/src/threads/read_model/store.rs`
- `crates/bridge-core/src/threads/read_model/mappers.rs`
- `crates/bridge-core/src/threads/read_model/dto.rs`

### 4. Cold archive fallback

Purpose:
- only load non-loaded historical threads when app-server cannot
- map archive content as faithfully as possible
- no live repair, no watchdog, no semantic overwrite of live state

Planned modules:

- `crates/bridge-core/src/threads/archive/mod.rs`
- `crates/bridge-core/src/threads/archive/load.rs`
- `crates/bridge-core/src/threads/archive/map.rs`

### 5. HTTP/API layer

Purpose:
- expose mobile routes
- delegate to thread services
- contain no lifecycle logic

Planned modules:

- `crates/bridge-core/src/server/http/mod.rs`
- `crates/bridge-core/src/server/http/routes_threads.rs`
- `crates/bridge-core/src/server/http/routes_pairing.rs`
- `crates/bridge-core/src/server/http/routes_admin.rs`

### 6. Application services

Purpose:
- orchestrate thread start/resume/read/list/interrupt
- keep flow small and testable

Planned modules:

- `crates/bridge-core/src/app/mod.rs`
- `crates/bridge-core/src/app/thread_service.rs`
- `crates/bridge-core/src/app/pairing_service.rs`
- `crates/bridge-core/src/app/event_bus.rs`

## What Gets Deleted

These ideas are being removed as architecture, not patched:

- archive-driven finalization for bridge-owned turns
- notification suspension / resume as the primary synchronization tool
- completion watchdog used to repair running-state drift
- snapshot reconciliation loops that overwrite live projection state
- semantic message dedupe for Codex live/archive messages
- giant mixed-responsibility files, especially the current state/gateway/thread-api god objects

## Migration Strategy

The rewrite will be done in phases so the code remains runnable:

### Phase 1. Freeze the contract

- Write this plan
- Keep using current endpoints and DTOs temporarily
- Add focused repro tests for the current failures

### Phase 2. Introduce the new Codex client

- Build a clean app-server client that only knows protocol
- Prove `initialize`, `thread/start`, `thread/read`, `thread/list`, `turn/start`, `turn/interrupt`
- Do not port old bridge logic into this layer

### Phase 3. Replace live turn handling

- Route live Codex turns through the new live session layer
- Publish bridge events directly from app-server notifications
- Remove watchdog completion logic
- Remove completion-time archive refresh for loaded live turns

### Phase 4. Replace snapshot/read paths

- Thread detail/list for loaded threads should come from app-server reads
- Use archive fallback only when the thread is not loaded
- Delete old mixed `thread_api` read/reconcile path once parity is reached

### Phase 5. Replace mobile HTTP routes

- Move routes onto new application services
- Keep only thin request parsing and DTO mapping in handlers

### Phase 6. Delete obsolete code

- remove dead modules
- shrink or remove old `thread_api` pieces
- split remaining large modules until the structure is understandable

## Testing Strategy

The rewrite is complete only when all of these pass against the new architecture:

### Rust unit/integration

- transport handshake tests
- thread start/read/list/interrupt tests
- live notification mapping tests
- loaded-thread snapshot consistency tests
- archive fallback tests for not-loaded historical threads

### Existing bridge regressions

- `terminal_live_thread_status_clears_active_turn_id`
- `watchdog_does_not_finalize_while_turn_stream_is_active`

These may be rewritten or deleted if the old abstraction disappears, but the behaviors they protect must still be covered.

### Mobile controller tests

- duplicate frame suppression
- snapshot replacement after malformed live text
- late completion refresh behavior

### Live validation

- direct bridge two-turn repro
- host-side duplicate probe
- physical-device Codex duplicate flow

## Success Criteria

The rewrite is done when:

1. live Codex turns never require archive-driven completion repair
2. bridge snapshot/history match the authoritative Codex live stream for loaded threads
3. the host-side duplicate probe passes cleanly
4. the physical-device Codex duplicate flow runs on the new driver and passes
5. `bridge-core` no longer relies on multi-thousand-line state modules

## Working Notes

- Prefer deleting code instead of adapting it when the old abstraction is part of the problem.
- When in doubt, re-check the app-server tests in `tmp/codex`.
- If a new change conflicts with this plan, update the plan first and then change the code.
