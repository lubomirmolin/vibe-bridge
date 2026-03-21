# Backend Rewrite Plan

## Goal

Rewrite the bridge backend so the app feels immediate under real usage.

Target outcomes:

- thread list loads immediately
- opening a hot thread is immediate
- sending a message shows pending/streaming state immediately
- assistant output appears incrementally instead of after a blocking reload
- idle app usage does not keep the Mac busy
- trust, approvals, and mutations are handled correctly

This plan intentionally does not preserve backward compatibility. The app is not live yet, so the rewrite should optimize for the correct architecture rather than incremental patches.

## Why Rewrite Instead of Patch

The current backend has structural problems that make piecemeal fixes expensive and fragile:

- request-time full rebuilds on `/threads` and thread detail
- multiple competing thread-state mutation paths: request sync, reconcile loop, live notifications
- one broad `ThreadApiService` object acting as RPC client, archive reader, normalizer, cache, and command service
- primitive custom TCP/HTTP handling with query-string mutation inputs
- incomplete trust enforcement on mutating routes
- simulated git routes that look real but are not

The current design does too much work on the hot path and has no clear single source of truth for thread state.

## Core Principles

1. Stream-first, not reload-first.
2. One authoritative backend state model.
3. Request handlers read projections; they do not rebuild conversations.
4. Long-lived upstream Codex connections, not one connection per request.
5. Files and JSONL are fallback and recovery tools, not the primary live path.
6. Mutations require a trusted paired client.
7. The mobile contract should reflect what the app actually needs, not everything the old bridge happened to expose.

## Target Architecture

The new backend should be split into focused modules.

### 1. API Layer

Use Tokio + Axum.

Responsibilities:

- HTTP routing
- websocket upgrades
- JSON body parsing
- auth/trust middleware
- request validation
- typed responses

This replaces the current hand-rolled TCP request parser.

### 2. Codex Gateway

Own the live connection to Codex app-server.

Responsibilities:

- long-lived upstream connection management
- notification stream supervision
- typed RPC calls for:
  - `thread/list`
  - `thread/start`
  - `thread/resume`
  - `thread/read`
  - `turn/start`
  - `turn/interrupt`
  - approval flows if needed
- reconnect and backoff behavior

This module should be the only place that talks directly to Codex.

### 3. Projection Store

This becomes the backend source of truth.

Responsibilities:

- maintain a global thread summary projection
- maintain hot per-thread projections for active and recently opened threads
- apply reducers from upstream notifications
- expose snapshot reads to API handlers

Important constraints:

- no global mutex around all thread operations
- use actor-style ownership or fine-grained `RwLock`s
- request handlers must not trigger full-thread reconstruction for normal reads

### 4. Recovery Layer

Recovery is a separate concern, not the normal path.

Responsibilities:

- bootstrap summaries from Codex `thread/list`
- targeted rehydrate of one thread using `thread/read(includeTurns=true)`
- optional fallback to local JSONL/archive when Codex is unavailable

Important constraint:

- no periodic full reconcile loop as a normal operating mode

### 5. Stream Hub

Own downstream subscriptions from mobile clients.

Responsibilities:

- list-scope subscriptions
- thread-scope subscriptions
- event fan-out
- backpressure behavior
- subscription lifecycle

Important constraint:

- deltas must be incremental only
- do not resend the full accumulated message/output on every chunk

### 6. Security and Trust

Responsibilities:

- trusted-session validation for all mutating routes
- approval identity binding
- security audit events
- bridge policy enforcement

Important constraint:

- thread mutations and approval resolutions must not be reachable without trust validation

## New Backend Contract

Redesign the contract around snapshots and deltas.

### HTTP

#### `GET /bootstrap`

Returns:

- bridge health
- Codex health
- pairing/trust session state
- model catalog if still needed
- initial thread summaries

#### `GET /threads`

Returns summary list only.

Fields needed by mobile:

- `thread_id`
- `title`
- `status`
- `workspace`
- `repository`
- `branch`
- `updated_at`

No turns. No heavy merge work.

#### `GET /threads/:id/snapshot`

Returns full normalized snapshot for one thread.

Fields needed by mobile:

- `thread_id`
- `title`
- `status`
- `workspace`
- `repository`
- `branch`
- `access_mode`
- timestamps needed for freshness
- initial visible thread items or enough metadata to immediately render the thread shell

#### `GET /threads/:id/history?before&limit`

Returns paged timeline/history entries for one thread.

Each entry should include:

- `event_id`
- `kind`
- `occurred_at`
- minimal rendering payload
- annotations used by mobile:
  - `group_kind`
  - `exploration_kind`
  - `entry_label`

`group_id` can be dropped unless a later UI uses it.

#### `POST /threads/:id/turns`

Starts a turn and returns immediately with an accepted response.

Response only needs enough for the app to transition immediately:

- `message`
- `thread_status`

#### `POST /threads/:id/interrupt`

Interrupts the active turn.

#### `GET /approvals`

Returns current approvals needed by the mobile app.

#### `POST /approvals/:id/approve`

#### `POST /approvals/:id/reject`

### WebSocket

Use one websocket endpoint, for example `WS /events`.

Support subscriptions by scope:

- `list`
- `thread:<id>`

Event kinds:

- `thread.upserted`
- `thread.status_changed`
- `thread.activity`
- `turn.started`
- `turn.completed`
- `item.started`
- `item.delta`
- `item.completed`
- `approval.requested`
- `approval.resolved`
- `thread.snapshot_reset`

Rules:

- list subscriptions receive compact events only
- thread subscriptions receive rendering deltas for that thread only
- `item.delta` is a true incremental delta
- no quadratic payload growth from repeated full accumulated content

## Data Model Strategy

### Thread Summaries

Summary state should be maintained from:

- initial `thread/list`
- live `thread/started`
- live `thread/status/changed`
- activity-producing item events

This is enough for the list screen.

### Thread Detail

Thread detail should work like this:

1. Open thread.
2. Return hot projection if present.
3. If missing or stale, do one targeted hydrate for that thread only.
4. Apply live deltas after that.
5. If drift is detected, do one targeted recovery hydrate.

This keeps the first open correct and the ongoing experience fast.

### Local Files and JSONL

Use local files only for:

- startup fallback
- offline recovery
- backfill of old archived threads
- targeted repair when upstream data is unavailable

Do not make JSONL tailing the primary live source if Codex notifications are available.

## Mobile Contract Simplification

The mobile app needs less backend data than the current bridge sends.

### List Screen Needs

- thread summary fields
- compact live activity and status signals

The list screen does not need:

- full message payloads
- command outputs
- diffs
- approval payload bodies
- security audit bodies

### Detail Screen Needs

Initial snapshot:

- thread metadata
- access mode
- enough current history to render immediately

Live updates:

- message delta plus user/assistant role
- plan delta text
- command delta text and command label
- file change diff or file-change summary
- thread status changes
- approvals and git status where relevant

### Fields to Drop

These appear unnecessary in the current app behavior:

- redundant detail metadata not surfaced in UI
- heavy event payload fields not rendered by mobile
- list-stream event bodies beyond status/activity metadata
- unused response fields on mutation/open-on-Mac responses
- model metadata fields not used by the current composer UI

## Mutation and UX Rules

This part is critical because it fixes the bad “loading disappears, then nothing happens” UX.

### On Send

1. Mobile posts the turn.
2. Backend returns accepted immediately.
3. Mobile inserts a pending assistant placeholder immediately.
4. Backend emits `turn.started` immediately when possible.
5. Mobile keeps the streaming indicator visible until `turn.completed`.
6. `item.delta` updates the visible assistant message incrementally.

### Important Rule

Do not make the UI wait for a full thread reload after submit.

Normal post-submit behavior must be entirely stream-driven.

## Git Endpoints

The current fake git mutation routes should not survive the rewrite.

Choose one:

- remove them entirely from the contract for now
- replace them with real audited operations

Do not keep simulated success responses.

## Suggested Build Sequence

### Phase 1: Contract and Skeleton

- define the new shared contracts
- create new backend modules
- stand up async server and websocket infrastructure
- add trust middleware

### Phase 2: Codex Gateway

- implement long-lived upstream connection management
- implement typed Codex request API
- implement notification supervisor

### Phase 3: Projections

- implement summary projection
- implement per-thread projection
- implement reducers for live events
- implement targeted hydrate and recovery flow

### Phase 4: API

- implement `/bootstrap`
- implement `/threads`
- implement `/threads/:id/snapshot`
- implement `/threads/:id/history`
- implement turn and approval mutations

### Phase 5: Streaming

- implement list subscriptions
- implement thread subscriptions
- implement incremental delta fan-out
- remove old stream behavior

### Phase 6: Mobile Migration

- update list screen to compact list events
- update detail screen to snapshot + deltas
- add optimistic pending assistant state
- keep streaming indicator until turn completion

### Phase 7: Remove Old System

- delete request-time full sync path
- delete heavy reconcile loop
- delete custom TCP routing layer
- delete simulated git behavior
- remove old `ThreadApiService` architecture where replaced

## Testing and Validation

The rewrite is not complete until it passes real end-to-end validation.

### Unit and Integration Tests

- projection reducer correctness
- websocket subscription filtering
- trust enforcement on mutating routes
- approval state transitions
- reconnect and recovery behavior

### Real Codex Integration Tests

Run the real bridge against a real local Codex runtime.

Validate:

- thread summary bootstrap from live Codex
- thread open hydrate from real upstream data
- real turn execution
- real notification handling
- recovery after Codex reconnect

### Mobile E2E Tests

Run on emulator or simulator.

Validate:

- app launch loads real thread list quickly
- opening a real thread renders immediately
- sending a real message shows pending state immediately
- first assistant text appears incrementally
- `turn.completed` finalizes correctly
- reconnect recovers correctly
- approvals work with real backend state

### Manual Validation

Use real data and real runtime behavior:

- kill the current bridge
- rebuild and run the new bridge
- connect the app to the new bridge
- test with real `~/.codex` session data
- test against a real repository and real Codex turns

### Performance Gates

Minimum targets:

- warm `/threads` under 100 ms local
- hot thread open under 150 ms
- send-to-pending-feedback under 100 ms
- no periodic heavy CPU churn while idle
- no payload explosion from streamed output

## Exit Criteria

The rewrite is successful only if all of these are true:

- thread list feels immediate
- opening a thread feels immediate after the first hydrate
- sending a message shows progress immediately
- assistant output streams in without a long blank gap
- backend state converges from one authoritative path
- idle mobile connection does not noticeably slow the Mac
- trust and approval flows are correct
- all e2e validation passes against real Codex data and runtime behavior
