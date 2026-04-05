# Codex Bridge + Mobile Overhaul Master Plan

Date: 2026-04-05
Scope: full rewrite of the Codex path across `crates/bridge-core` and `apps/mobile`
Compatibility stance: no backward compatibility inside this repo; optimize for the correct architecture, not for preserving current behavior

## 1. Executive Summary

The current Codex integration is failing for structural reasons, not because of one bad merge rule or one bad mobile spinner condition.

The root problem is that the bridge currently tries to derive the same conversation truth from too many places at once:

- live Codex notifications
- `thread/read` RPC snapshots
- archive JSONL on disk
- bridge-synthesized timeline/status events
- mobile-local optimistic prompts and reconciliation heuristics

Those sources disagree in timing, completeness, and shape. The bridge then normalizes, merges, filters, compacts, snapshots, diffs, replays, and rehydrates them through multiple parallel pipelines. The mobile app adds another layer of heuristics on top. The result is a system that can appear healthy at one layer while losing or delaying canonical history at another.

The rewrite should not be another round of targeted fixes. It should replace the current design with a Codex-native architecture built around these principles:

1. One canonical source per concern.
2. Active turns are finalized from the live stream, not from an end-of-turn snapshot refresh.
3. Archive is the canonical source of settled history and cold-start reconstruction.
4. `thread/read` is metadata/bootstrap only, not timeline truth.
5. The bridge owns a persistent event log and materialized projections.
6. Mobile reconciles by exact IDs, not by fuzzy text/time matching.
7. Plan mode and approvals become explicit workflows, not hidden-message parsing hacks.

This document proposes the full replacement plan.

## 1.1 Progress Update

Completed in the current rewrite track:

- [x] exact `client_message_id` correlation from mobile submit through bridge canonical user-message settlement
- [x] removal of fuzzy mobile pending-prompt reconciliation by body/time matching
- [x] additive external snapshot application so weaker refreshes no longer erase richer live data
- [x] archive-first selection for settled Codex history, with RPC kept as a running-turn supplement instead of final timeline truth
- [x] completion-path change so self-sufficient live streamed turns can skip immediate completion snapshot refresh
- [x] live event stream now carries bridge-managed `bridge_seq` and resumes by `after_seq` from the event hub
- [x] thread-detail reconnect now attempts replay-first websocket recovery and only falls back to snapshot catch-up on replay gap or active-turn recovery needs
- [x] bridge event replay now survives bridge restart via a persisted append-only event log under the bridge state root
- [x] thread snapshots now carry `latest_bridge_seq` and preserve it across weaker external refreshes
- [x] bridge bootstrap now rehydrates materialized snapshots from the persisted event log after summary bootstrap
- [x] timeline pages now carry `latest_bridge_seq` and mobile catch-up paths seed replay cursors from fetched history
- [x] pending user-input payloads now carry bridge workflow metadata, including plan `original_prompt`, so restart recovery no longer depends on timeline archaeology in the common case
- [x] thread snapshots and timeline pages now carry explicit bridge workflow state for plan intake/questionnaire lifecycle, replacing the runtime-only `awaiting_plan_question_prompts` cache
- [x] workflow-state transitions now persist through the bridge event log via `thread_metadata_changed`, so `awaiting_questions` survives bridge restart and replay
- [x] stale provider approvals now degrade into explicit `expired` workflow state on restart, and Flutter consumes `workflowState` instead of treating bridge workflow as invisible metadata
- [x] Codex plan turns now start with native `collaborationMode=plan` instead of the bridge-owned hidden intake prompt
- [x] live Codex `item/tool/requestUserInput` requests now become first-class bridge `pending_user_input` state and resolve on the same in-flight turn
- [x] stale native Codex plan questionnaires now degrade into explicit `plan_questionnaire / expired` workflow state on restart instead of looking answerable after the transport is gone
- [x] Flutter now allows in-flight plan-question responses for native Codex `requestUserInput` and surfaces expired plan-questionnaire workflow state explicitly
- [x] legacy hidden-plan questionnaire reconstruction has been removed from bridge production snapshot/restart paths; old hidden protocol messages are filtered but no longer recreate pending workflow state
- [x] replayed canonical live events now semantically merge with earlier live fragments on mobile, so reconnect replay replaces partial assistant output instead of duplicating it
- [x] Codex gateway archive summary/snapshot fallback no longer instantiates `ThreadApiService`; it now maps raw archive snapshot records directly into bridge DTOs
- [x] replay/timeline merge rules in Flutter have been extracted out of `thread_detail_controller.dart` into a dedicated helper module as the first controller-split step
- [x] pending local prompt reconciliation and failure-settlement helpers are now extracted out of `thread_detail_controller.dart` into a dedicated helper module
- [x] active-turn decision rules for live reload, refreshed-detail acceptance, transient lifecycle filtering, and meaningful live activity are now extracted out of `thread_detail_controller.dart` into a dedicated helper module
- [x] `thread_detail_controller.dart` is now split across focused loading/live/mutation/tracking modules, and the reconnect-focused Flutter suite still passes on the rewritten controller shape
- [x] bridge per-thread transient turn/runtime state is now centralized in one runtime store instead of being spread across separate global maps for active turn ids, stream activity, pending prompts, pending user input, resumable subscriptions, and interruption flags
- [x] Codex thread-scoped operations now run through a per-thread actor/worker instead of a shared reserved-transport map on `CodexGateway`
- [x] resumable Codex notification subscriptions now run through the per-thread actor model too; the old shared Codex notification forwarder no longer owns live projection updates
- [x] the last shared Codex notification-resume queue has been removed; `request_notification_thread_resume` now subscribes actor-owned Codex streams directly and only forwards resume intent to the separate desktop IPC path
- [x] the rewritten Codex gateway path now owns its own live notification stream/normalizer module instead of importing the legacy `thread_api` notification types
- [x] a baseline Codex replay harness now replays raw upstream-style notification fixtures through the Codex normalizer and materialized projection path for act and plan turns
- [x] the Codex thread actor now owns the active-turn completion accumulator and returns stream sufficiency directly on stream finish instead of relying on a bridge-state runtime activity cache
- [x] the raw Codex replay fixture corpus now covers message-only, plan, and tool-heavy turn shapes through the live notification normalizer and projection pipeline
- [x] workflow transitions for plan questionnaires and provider approvals now run through an explicit reducer module instead of ad-hoc string builder helpers spread across turn handlers
- [x] Codex active-turn and stream lifecycle ownership now lives behind the actor/gateway instead of bridge-state `stream_active` and `pending_bridge_owned_turn` caches
- [x] the replay harness now covers upstream-shaped mixed streams with server-initiated `requestUserInput` and approval requests, including ignored `serverRequest/resolved` cleanup notifications, using repo-local app-server protocol examples as the fixture source
- [x] provider thread identity helpers have been moved out of `thread_api` into a dedicated module so the new bridge path no longer depends on legacy thread-service code for basic provider-thread addressing
- [x] bridge-owned git-status/mutation response DTOs and timeline-envelope helpers now live under `server` instead of `thread_api`, so the live bridge path no longer imports legacy service types for basic API behavior
- [x] the old crate-root synchronous bridge runtime, local stream router, and legacy compatibility entrypoint have been deleted; the async Axum server under `server::run_from_env()` is now the only bridge runtime entrypoint
- [x] the remaining live Codex dependency on `thread_api` is now isolated behind a real gateway legacy-archive adapter module with explicit wrapper functions instead of being spread across server modules or hidden in gateway preludes
- [x] `thread_api` now reuses the server-owned git/mutation response contracts instead of defining duplicate DTO structs for the old service path
- [x] the legacy `thread_api` module tree has been deleted completely; the remaining archive compatibility code now lives under `server/gateway/legacy_archive`
- [x] bridge and Flutter tests adjusted for the new `start_turn` contract shape

Still not completed:

- [x] replay harness based on captured upstream fixtures
- [x] persistent event store with sequence-cursor replay
- [x] dedicated `CodexThreadActor`
  Codex threads now run through a per-thread worker for snapshot reads, turn starts, active-turn resolution, interrupts, renames, live turn-stream processing, resumable notification subscriptions, completion accumulation, and active-turn/stream lifecycle ownership. Bridge state no longer owns separate `stream_active` or `pending_bridge_owned_turn` flags for Codex turns; only a narrow fallback `active_turn_id` cache remains for non-actor test/setup cases.
- [x] full explicit workflow state machine for plan/user-input/approval persistence
  Plan intake/questionnaire phases now persist through replayable workflow-state events, live provider approvals participate in the same explicit workflow contract while active, native Codex `requestUserInput` is now the primary plan-question transport, stale requests downgrade to explicit expired state on restart, bridge production code no longer reconstructs plan workflow from hidden transcript payloads, and workflow transitions are now centralized in an explicit reducer module instead of scattered string-state helpers.
- [x] full mobile controller split and reconnect rewrite
  The thread-detail controller is now split across focused loading/live/mutation/tracking modules, the main file is back under 1000 lines, replay-first reconnect remains the normal path, and the reconnect-focused Flutter suite passes on the rewritten controller.
- [x] legacy `thread_api` path deletion
  The old `thread_api` service/sync/archive stack is gone. The async server path is the only runtime, Codex live notifications are gateway-owned, archive compatibility lives under `server/gateway/legacy_archive`, and the `thread_api` module name no longer exists in production code.

## 2. Ground Truth From Upstream Codex

The repo-local `tmp/codex/codex-rs/app-server` implementation gives us the constraints we should design around.

### 2.1 App-server facts we can trust

From `tmp/codex/codex-rs/app-server/README.md`, `message_processor.rs`, `thread_state.rs`, `thread_status.rs`, `transport/mod.rs`, and `in_process.rs`:

- Every connection must perform `initialize`, then send `initialized`.
- Requests before initialization are rejected with `"Not initialized"`.
- Repeating `initialize` is rejected with `"Already initialized"`.
- `thread/start` auto-subscribes that connection to the new thread’s events.
- `thread/resume` is how an existing thread becomes active on a connection.
- `turn/start` returns quickly, then the same connection emits:
  - `turn/started`
  - `item/started`
  - item delta notifications such as `item/agentMessage/delta`
  - `item/completed`
  - `turn/completed`
- `thread/read` with `includeTurns=true` is rollout-backed and can be unavailable before the thread is materialized by the first user message.
- The app-server already tracks active-turn state and pending user-input/approval request counts in `thread_status.rs`.
- The websocket listener in app-server is explicitly described as experimental/unsupported; our bridge should not depend on app-server websocket semantics for correctness.

### 2.2 Design implications

- The live turn stream is first-class protocol, not a preview.
- If the bridge starts a turn on a connection, that connection already has the canonical event stream for that turn.
- `thread/read` is not the right place to define the final truth of a just-completed turn.
- Upstream already has real request/approval/user-input concepts. We should prefer those over inventing hidden-message protocols where possible.

## 3. Current-State Analysis

### 3.1 What the bridge does today

Relevant current files:

- `crates/bridge-core/src/server/gateway/codex.rs`
- `crates/bridge-core/src/server/gateway/codex/rpc.rs`
- `crates/bridge-core/src/server/gateway/codex/archive.rs`
- `crates/bridge-core/src/server/gateway/mapping/snapshot.rs`
- `crates/bridge-core/src/server/state/turns.rs`
- `crates/bridge-core/src/server/state/streams.rs`
- `crates/bridge-core/src/server/projection.rs`
- `crates/bridge-core/src/server/gateway/legacy_archive/*`

Current behavior:

- Turn starts over bridge HTTP.
- Bridge starts a live Codex turn stream.
- Bridge normalizes live notifications into bridge event envelopes.
- Bridge compacts live deltas.
- Bridge mutates in-memory projections.
- Bridge also synthesizes its own events such as `turn_started` and visible user prompts.
- When the stream finishes, bridge fetches a fresh snapshot from the gateway.
- That snapshot is currently built from a mix of:
  - RPC `thread/read`
  - archive-derived timeline
- Then the bridge diffs the previous snapshot against the refreshed snapshot and publishes status events.

This means the bridge has both:

- an event-stream pipeline
- a snapshot-reconciliation pipeline

and neither fully owns correctness.

### 3.2 What the mobile app does today

Relevant files:

- `apps/mobile/lib/features/threads/application/thread_detail_controller.dart`
- `apps/mobile/lib/features/threads/data/thread_detail_bridge_api.dart`
- `apps/mobile/lib/features/threads/data/thread_live_stream.dart`
- `apps/mobile/lib/features/threads/presentation/thread_detail_page.dart`

Current behavior:

- Mobile starts turns by HTTP.
- Mobile listens for bridge websocket events.
- Mobile tracks optimistic local prompts separately from canonical timeline items.
- Mobile tries to reconcile those local prompts to canonical prompts using body/time matching.
- Mobile has background detail refresh and snapshot refresh timers.
- Mobile reconnect logic fetches thread detail and timeline pages, then reattaches websocket with `after_seq`.
- Mobile decides between `start` and `steer` partly from local state and partly by fetching thread detail again.

This means the mobile app has become a second protocol interpreter. It is not just rendering bridge truth; it is compensating for bridge ambiguity.

### 3.3 Measured code-shape problems

Current file sizes already show architectural strain:

- `apps/mobile/lib/features/threads/application/thread_detail_controller.dart`: 3386 lines
- `apps/mobile/lib/features/threads/presentation/thread_detail_page.dart`: 2773 lines
- `apps/mobile/lib/features/threads/data/thread_detail_bridge_api.dart`: 1446 lines
- `crates/bridge-core/src/server/gateway/legacy_archive/archive.rs`: 2570 lines
- `crates/bridge-core/src/server/gateway/legacy_archive.rs`: 54 lines

These are not just “large files.” They are evidence that responsibilities are too blended.

### 3.4 Proven failure mode from recent debugging

We already proved a specific production bug:

- bridge accepted and completed the turn
- phone received terminal websocket status events
- archive JSONL already contained the canonical user and assistant messages
- bridge-served snapshot/history for that turn contained only status events
- mobile never received the canonical prompt/answer items
- optimistic local prompt stayed stuck in `sending`

That bug was caused by bridge snapshot/timeline materialization preferring incomplete RPC shape over archive-backed truth.

The recent merge fix corrects that specific bridge bug, but it does not solve the underlying architecture problem.

## 4. Structural Problems To Eliminate

### 4.1 Competing truth sources

The same “final thread history” is currently inferred from:

- live stream
- RPC `thread/read`
- archive JSONL
- bridge synthetic metadata

That must end.

### 4.2 End-of-turn refresh as a correctness dependency

Current system behavior is effectively:

- live stream = partial/in-progress
- post-turn snapshot refresh = real truth

This is the wrong shape. The stream must be good enough to finalize a turn that the bridge itself started.

### 4.3 Synthetic timeline pollution

Examples:

- bridge-generated visible user prompt events
- bridge-generated `turn_started` status history entries
- hidden mobile plan protocol prompts embedded in assistant/user messages

Some bridge-owned state is valid, but today it is mixed directly into the same timeline as upstream canonical items without clear ownership rules.

### 4.4 Two separate history stacks in the bridge

There is old `thread_api` logic and newer gateway/projection logic, with shared pieces crossing between them.

That creates:

- duplicate archive parsing responsibilities
- duplicate timeline merge semantics
- duplicate tests pinning conflicting expectations

### 4.5 Mobile heuristics for exactness problems that should be solved by the contract

Examples:

- fuzzy prompt reconciliation by text and timestamps
- local active-turn verification fallback to `steer`
- snapshot/detail refresh timers to settle live ambiguity
- pending prompt failure grace windows

These are symptoms of an insufficient bridge contract.

### 4.6 Plan mode is implemented as a protocol hack

Current plan flow relies on:

- hidden prompt strings
- hidden XML-like wrappers
- timeline filtering
- later reconstruction of `pending_user_input` by reparsing hidden message content

That is brittle and hard to reason about.

## 5. Rewrite Goals

### 5.1 Primary goals

- Codex active-turn streaming must be reliable and self-sufficient.
- The bridge must never lose canonical user/assistant/tool history for a turn it actively streamed.
- Mobile should render from one coherent bridge contract, not from local recovery heuristics.
- Plan mode and approvals must become explicit workflows.
- Reconnect and replay must be deterministic.
- Tests must verify protocol and state-machine behavior using real traces, not fragile local assumptions.

### 5.2 Secondary goals

- Reduce file size and module coupling.
- Keep Claude support isolated so Codex work stops paying abstraction tax for Claude-specific behavior.
- Preserve the ability to recover cold state from archive.

### 5.3 Non-goals

- Preserving current bridge event wire shapes.
- Preserving current mobile controller state structure.
- Preserving legacy tests that encode today’s accidental behavior.

## 6. Target Architecture

## 6.1 Ownership model

The rewrite should adopt this strict source-of-truth table.

### A. Active turn truth

Owner: live Codex notifications on the connection that owns the turn.

Used for:

- `turn/started`
- user message creation
- assistant message deltas/finalization
- tool call start/output/finalization
- approvals
- request-user-input events
- `turn/completed`

Rule:

- If the bridge started the turn, it must be able to finalize the visible turn result from the live stream alone.

### B. Settled history truth

Owner: archive JSONL parsed into canonical thread history.

Used for:

- cold start
- older timeline pagination
- bridge restart recovery
- validating or backfilling any streamed turn

Rule:

- Archive is the canonical persisted history for settled turns.

### C. Bootstrap metadata

Owner: RPC `thread/read`, `thread/list`, and other non-history reads.

Used for:

- thread existence
- model/workspace/branch/title bootstrap if archive lacks it
- loaded/running presence hints

Rule:

- RPC never gets to overwrite fresher visible history entries.

### D. Bridge-owned workflow state

Owner: bridge persistent state store.

Used for:

- plan/questionnaire workflow
- approval workflow UI state
- bridge-local metadata such as generated titles if we keep that feature

Rule:

- bridge-owned workflow data lives beside the conversation timeline, not disguised as hidden conversation content.

## 6.2 Bridge core design: thread actors

Replace the current global mix of reserved transports, projection mutations, and snapshot diffs with a thread-actor model.

Each active or watched Codex thread gets a `CodexThreadActor` that owns:

- one Codex transport connection
- initialization state
- resume/subscription state
- current loaded thread metadata
- active turn accumulator
- pending approval/user-input state
- bridge event sequence
- persisted event/apply cursor

Actor responsibilities:

- start/resume the thread on its transport
- start/steer/interrupt turns serially
- consume notifications in order
- convert upstream notifications into canonical bridge events
- append those events to bridge persistent storage
- materialize the current thread snapshot from stored canonical state

This eliminates the “reserved transport” hack and most cross-thread global coordination.

## 6.3 Bridge persistent model

Introduce a bridge-owned persistent store, likely SQLite, with at least:

- `threads`
- `thread_events`
- `thread_cursors`
- `pending_requests`
- `workflows`

Recommended event schema:

- monotonically increasing bridge event sequence per thread
- immutable append-only event rows
- explicit `source` field: `codex_stream`, `archive_import`, `bridge_workflow`
- explicit `provider_item_id`, `provider_turn_id`, `client_message_id` when available
- raw upstream payload snapshot for debugging
- normalized payload used by mobile/UI

Snapshots become a materialized view of the event log, not a parallel truth source.

## 6.4 Contract redesign

The current contract overloads `BridgeEventKind.messageDelta` and friends too heavily. The new contract should be more explicit.

Recommended normalized event families:

- `turn_started`
- `turn_completed`
- `turn_failed`
- `user_message_created`
- `assistant_message_delta`
- `assistant_message_completed`
- `plan_updated`
- `command_started`
- `command_output_delta`
- `command_completed`
- `file_change_started`
- `file_change_completed`
- `approval_requested`
- `approval_resolved`
- `user_input_requested`
- `user_input_resolved`
- `thread_status_changed`
- `thread_metadata_changed`

For mobile reconciliation, every locally submitted message must include a stable bridge-visible correlation field:

- mobile generates `client_message_id`
- HTTP `start_turn` includes it
- bridge stores it
- canonical user message event carries it

This removes fuzzy text/time matching completely.

## 6.5 Event replay model

Replace `after_event_id` replay from the current in-memory snapshot with a real cursor model.

Recommended behavior:

- every thread event gets an integer `bridge_seq`
- websocket subscriptions resume with `after_seq`
- bridge replays persisted canonical events from storage
- if replay gap exceeds retention window, client falls back to snapshot reload

This is much safer than replaying from a mutable in-memory snapshot list by event id.

## 6.6 Snapshot model

Snapshots should be built from:

- archive-imported settled history
- live active-turn journal for any active turn
- bridge workflow state overlays

Snapshots should not be built by diffing a previous snapshot against a newly fetched mixed-source snapshot.

For turns the bridge actively streamed:

- completion should finalize from the event journal immediately
- archive import can happen afterward as verification/backfill
- RPC `thread/read` must not be the finalizer

## 6.7 Mobile model

Mobile should consume:

- one canonical thread snapshot shape
- one canonical paginated history shape
- one canonical thread event stream with sequence cursor

Mobile should keep only minimal local ephemeral state:

- draft input
- local pending submit state keyed by `client_message_id`
- transient UI flags

Mobile should not:

- infer canonical history
- fuzzy-match pending prompts to history
- use thread-detail refreshes to settle normal turn completion
- decide `start` vs `steer` from stale local status without bridge help

If steering remains supported, the bridge should expose an explicit authoritative turn-control response, not require mobile to rediscover truth by fetching detail.

## 6.8 Plan mode redesign

There are two viable directions.

### Preferred direction

Adopt upstream-native request-user-input where the pinned Codex app-server version is stable enough.

Why:

- it is a first-class upstream concept
- request lifecycle already exists
- thread-status accounting already understands pending user input
- it reduces hidden-message protocol hacks

### Fallback direction

If `tool/requestUserInput` is still too unstable for production, keep a bridge-owned plan workflow, but make it explicit:

- do not encode bridge workflow state in hidden timeline messages
- do not reconstruct questionnaires by reparsing hidden content during normal operation
- persist workflow state in bridge storage
- expose `pending_user_input` as first-class workflow state

Either way, the current hidden XML wrapper flow should be treated as legacy to remove.

## 7. What To Remove

This section is intentionally blunt. These removals are the point of the rewrite.

### 7.1 Remove as normal-path correctness dependencies

- `refresh_snapshot_after_bridge_turn_completion()` as a required completion step
- RPC/archive mixed-source finalization for active turns
- mobile fuzzy prompt reconciliation
- mobile background snapshot/detail timers as the main turn-settlement mechanism

### 7.2 Remove bridge-generated visible prompt history entries

Delete the normal-path use of:

- `build_visible_user_message_event`
- bridge-owned user prompt injection for Codex turns

Reason:

- mobile can show local optimistic state
- canonical upstream user message should arrive via the actual turn stream
- exact reconciliation should happen through `client_message_id`

### 7.3 Remove legacy thread API stack

Plan to delete or fully replace:

- `crates/bridge-core/src/thread_api/service.rs`
- `crates/bridge-core/src/thread_api/sync.rs`
- most of `crates/bridge-core/src/thread_api/archive.rs`
- `crates/bridge-core/src/thread_api/tests/*`

What may survive:

- small reusable archive-parsing helpers, but moved into a new Codex-specific module under `server/gateway/codex/` or a new `server/codex/` package

### 7.4 Remove snapshot diffing as primary event synthesis

Reduce or remove reliance on:

- `diff_thread_snapshots(...)` as the way to discover what happened to a streamed turn
- `apply_external_snapshot_update(..., events)` with event lists synthesized from snapshot differences

Snapshots should be outputs, not event discovery inputs.

### 7.5 Remove hidden-message plan protocol

Delete after replacement:

- `build_hidden_plan_question_prompt`
- `build_hidden_plan_followup_prompt`
- hidden-plan timeline filtering as normal workflow logic
- reparsing hidden history to reconstruct active questionnaire state during normal operation

### 7.6 Remove Codex/Claude false-sharing where it hurts Codex correctness

Keep a provider-neutral API boundary if useful, but stop forcing Codex runtime logic through abstractions that mainly exist for Claude.

Codex needs a first-class implementation path. Claude can remain a separate adapter.

## 8. Bridge Rewrite Plan

## Phase 0: Freeze current behavior and capture truth

Before replacing code:

- stop adding new heuristics to current paths unless required to unblock local development
- capture real raw traces for:
  - normal act turn
  - plan turn
  - command approval
  - file-change approval
  - reconnect during active turn
  - bridge restart recovery

Artifacts to persist as fixtures:

- raw upstream JSON-RPC notifications in order
- raw `thread/read` responses at key points
- archive JSONL for the same thread/turn
- current bridge normalized events
- expected final mobile-visible snapshot

Deliverable:

- replay fixture corpus under a new test fixture directory, separate from legacy tests

## Phase 1: Build a Codex protocol replay harness

Implement a new replay-focused test harness that can:

- feed captured upstream notifications into the new Codex normalizer/actor
- import archive files
- assert resulting canonical event log
- assert resulting snapshot and history pages

Mandatory assertions:

- no lost canonical user/assistant items
- deterministic event ordering
- deterministic terminal turn settlement
- explicit approval/user-input lifecycle

This harness must become the core safety net of the rewrite.

## Phase 2: Implement the new Codex archive parser

Build a new Codex archive parser in a new module tree, not by extending the current 2590-line `thread_api/archive.rs`.

Requirements:

- parse settled history into canonical bridge event rows
- preserve provider item ids and turn ids
- preserve annotations needed for UI grouping
- parse tool calls and outputs cleanly
- parse plan/tool events without overloading them into ad-hoc shapes
- import pending workflow-related state only if explicitly persisted

Output:

- canonical archive import events
- canonical thread metadata snapshot

## Phase 3: Implement `CodexThreadActor`

This is the heart of the rewrite.

Capabilities:

- initialize transport once
- resume/subscription management
- serialized `start_turn`, `steer_turn`, `interrupt_turn`
- notification processing loop
- active-turn accumulator
- append-only event persistence
- lifecycle/workflow persistence

Key invariant:

- every notification from upstream is processed exactly once in-order by one owner

This phase should replace:

- reserved transport map behavior
- global turn-finalization dependence on snapshot refresh
- ad-hoc tracking of active turn ids in several separate maps

## Phase 4: Make live-streamed turns canonical

For turns started by the bridge:

- [x] `turn/start` response creates bridge turn context
- [x] upstream `turn/started` confirms running state
- [x] upstream item notifications create canonical message/tool events
- [x] upstream `turn/completed` finalizes the live turn state without requiring immediate snapshot refresh in the self-sufficient case

When `turn/completed` arrives:

- [x] actor closes active-turn accumulator
- [x] actor persists terminal turn result in a real event store
- [x] actor publishes terminal bridge events
- [x] actor updates the in-memory materialized snapshot directly from live state

Only after that:

- [x] optionally import archive to verify/backfill anything missing

If archive differs:

- [x] only additive reconciliation is allowed unless a strong correctness rule says otherwise
- [x] archive must never erase a stronger streamed result from the same completed turn

## Phase 5: Rebuild approval and user-input flows

Codex approvals should map directly from upstream approval requests and resolution events.

Plan/user-input flow must become one of:

- [x] upstream-native `tool/requestUserInput`
- [x] explicit bridge workflow state machine for persisted workflow metadata and restart semantics

Requirements:

- pending requests must survive reconnect and bridge restart
- pending requests must be scoped by thread and turn
- request lifecycle resolution must be explicit
- [x] bridge-owned workflow state now persists through replayable metadata events instead of hot projection state only
- [x] live provider approvals now set and clear explicit workflow state instead of existing only as a pending-input side effect
- [x] stale provider approvals now surface as explicit expired workflow state instead of silently disappearing after restart
- [x] plan questionnaire discovery no longer depends on a bridge-runtime prompt cache; it now resolves against explicit projection workflow state
- [x] workflow transitions are now expressed through an explicit reducer module instead of string-builder helpers spread across turn handlers
- [x] mobile no longer needs to parse hidden text blobs to know what is pending
- [x] Codex native `requestUserInput` now drives plan clarification instead of bridge-injected hidden prompt turns
- [x] native plan questionnaires clear via same-turn response payloads instead of starting a hidden follow-up turn
- [x] stale native plan questionnaires now surface as explicit expired workflow state after restart

## Phase 6: Rebuild snapshot/history APIs on top of event storage

New bridge API behavior:

- [x] snapshot endpoint reads materialized thread state
- history endpoint pages canonical persisted events
- [x] websocket endpoint replays from persisted sequence cursor

No API should depend on rebuilding truth ad hoc from a different source on each request.

## Phase 7: Delete legacy bridge code

After new path is passing replay and integration tests:

- remove legacy `thread_api` service/sync path
- remove old snapshot-diff driven turn completion logic
- remove bridge turn metadata overlay used only for compatibility
- remove legacy tests that assert old behaviors

## 9. Mobile Rewrite Plan

## Phase 1: Replace local reconciliation with exact IDs

Bridge contract changes required:

- [x] `start_turn` request accepts `client_message_id`
- [x] ack and canonical events carry `client_message_id`

Mobile changes:

- [x] optimistic local prompt keyed by `client_message_id`
- [x] remove fuzzy text/time reconciliation logic
- [x] settle prompt when matching canonical event arrives
- [x] if bridge returns hard failure, fail that exact local prompt

## Phase 2: Simplify controller state

Split `thread_detail_controller.dart` into smaller modules:

- thread page state model
- websocket/replay session manager
- send/turn controls
- timeline adapter
- pending request workflow coordinator

Goal:

- no single controller file above 1000 lines
- no timer-driven correctness logic spread across unrelated responsibilities

## Phase 3: Change reconnect semantics

Current reconnect does:

- fetch detail
- fetch timeline page
- merge items
- reopen websocket with `after_event_id`

New reconnect should do:

- [x] reconnect websocket with `after_seq`
- [x] replay bridge events from the in-memory event hub if available
- [x] only fall back to snapshot reload if replay gap cannot be satisfied

That makes reconnect deterministic and cheap.

## Phase 4: Remove mobile settlement heuristics

Delete once bridge contract supports exact reconciliation:

- body/time pending-prompt matching
- most pending prompt grace logic
- “silent turn watchdog” snapshot refresh as normal path
- detail refresh timers as normal turn-settlement path
- local `start` vs `steer` revalidation fetch unless bridge explicitly requires it

## Phase 5: Rebuild plan-mode UI on explicit workflow contract

The UI should render from explicit `pending_user_input` / `approval` state, not from hidden history interpretation.

Desired behavior:

- one clear workflow card
- exact lifecycle of request -> answer -> resolved
- reload/reconnect stays stable without timeline archaeology

## 10. Contract Changes

These are breaking changes and should be treated as such.

### 10.1 Turn start request

Add:

- [x] `client_message_id`
- [x] optional `client_turn_intent_id`

### 10.2 Turn mutation response

Include:

- bridge request id
- provider turn id if known
- explicit accepted mode: `start` or `steer`
- authoritative thread turn-control status

### 10.3 Event stream

Replace `after_event_id` with `after_seq`.

Every event should include:

- [x] `bridge_seq`
- `thread_id`
- `provider_turn_id` if relevant
- `provider_item_id` if relevant
- `client_message_id` if relevant
- source: `stream`, `archive`, or `bridge_workflow`

### 10.4 Snapshot/history

Snapshot should include:

- [x] latest `bridge_seq`
- active workflow state
- active turn summary if any

History pages should page by sequence/cursor, not just by event id string.

- [x] timeline pages expose latest known `bridge_seq` so reconnect can reuse a server-provided cursor after detail/history catch-up

## 11. Test Overhaul

The test rewrite is not optional. The current test suite encodes too much accidental behavior from the current architecture.

## 11.1 Remove or fully rewrite

Plan to delete or replace:

- `crates/bridge-core/src/thread_api/tests/*`
- mobile probe tests that exist mainly to study duplicate/status ordering under the current heuristic stack
- tests whose primary assertion is that snapshot refresh repairs live-stream ambiguity

Specifically suspect categories:

- archive/service/sync legacy tests
- duplicate/live probe tests that pin current compaction artifacts instead of desired contract
- mobile tests that rely on fuzzy pending-prompt settlement rules

## 11.2 Introduce new bridge test pyramid

### A. Unit tests

- event normalization from raw upstream notifications
- archive import normalization
- actor state machine transitions
- explicit approval/user-input workflow reducers

### B. Replay tests

- captured real upstream traces
- archive import parity fixtures
- failure regression corpus

### C. Persistence tests

- [x] event log append/replay
- [x] snapshot materialization from event log
- [x] reconnect with `after_seq`
- [x] bridge restart recovery

### D. Live integration tests

Keep a smaller number of high-value live tests:

- one normal act turn
- one plan flow
- one command approval
- one reconnect-during-turn flow

Those should validate the new architecture, not compensate for a missing replay harness.

## 11.3 New mobile test pyramid

- reducer/state tests against explicit bridge events
- websocket replay cursor tests
- one or two golden/UI flow tests per major workflow
- live emulator tests only for truly end-to-end guarantees

## 12. Recommended Module Layout

Suggested new bridge tree:

- `crates/bridge-core/src/server/codex/transport/`
- `crates/bridge-core/src/server/codex/actor/`
- `crates/bridge-core/src/server/codex/archive/`
- `crates/bridge-core/src/server/codex/events/`
- `crates/bridge-core/src/server/codex/materialize/`
- `crates/bridge-core/src/server/codex/workflows/`
- `crates/bridge-core/src/server/store/`

Suggested new mobile thread tree:

- `apps/mobile/lib/features/threads/application/session/`
- `apps/mobile/lib/features/threads/application/turns/`
- `apps/mobile/lib/features/threads/application/workflows/`
- `apps/mobile/lib/features/threads/application/timeline/`
- `apps/mobile/lib/features/threads/data/replay/`

The goal is to split by responsibility, not by arbitrary file count.

## 13. Migration Strategy

Because there is no backward-compatibility requirement inside this repo, the recommended migration strategy is:

1. Build the new Codex implementation beside the old one.
2. Feed real trace fixtures through both only long enough to compare.
3. Switch mobile and API routes to the new contract in one deliberate cutover.
4. Remove old code immediately after cutover, not “later”.

Do not leave both architectures half-alive for long.

## 14. Sequencing and Estimated Work Chunks

Recommended order:

1. Capture fixtures and build replay harness.
2. Build persistent event store.
3. Build archive importer v2.
4. Build `CodexThreadActor`.
5. Build new bridge contract and materialized snapshot/history APIs.
6. Build plan/approval workflow layer.
7. Rewrite mobile thread session stack.
8. Replace tests.
9. Delete legacy code.

This work is large enough that it should be treated as a dedicated rewrite track, not as incidental bugfixing around normal feature work.

## 15. Acceptance Criteria

The rewrite is done only when all of the following are true.

### Bridge correctness

- A turn actively streamed by the bridge never requires end-of-turn snapshot refresh to expose canonical user and assistant history.
- Archive import never removes fresher canonical streamed turn history.
- `thread/read` is no longer a normal-path source of final timeline truth for active streamed turns.
- Every event is replayable from persistent storage by sequence cursor.

### Mobile correctness

- No fuzzy prompt reconciliation remains.
- No spinner can stay alive solely because canonical prompt matching failed by body/time.
- Reconnect after a short drop resumes by replay cursor without snapshot catch-up in the common case.
- Plan and approval workflows survive reconnect without hidden-message parsing.

### Code health

- no giant controller files above 1000 lines in the rewritten mobile path
- no giant archive/service legacy file left doing unrelated work
- old `thread_api` service/sync legacy path deleted

### Test health

- replay harness exists and covers known historical failures
- live e2e coverage exists for act, plan, approval, reconnect
- legacy tests encoding current accidental architecture are removed or rewritten

## 16. Open Decisions To Make Early

These should be decided near the start of the rewrite, not halfway through.

### Decision 1: `tool/requestUserInput` for plan mode

Questions:

- Is it stable enough in the pinned Codex version?
- Can it cover the questionnaire UX we want?
- Does it work reliably across reconnect and turn restart?

If yes, adopt it.
If no, build explicit bridge workflow state and stop using hidden XML messages.

### Decision 2: persistent store format

SQLite is the most practical default. The rewrite should not use only in-memory event storage.

### Decision 3: event contract granularity

Choose between:

- more explicit per-item lifecycle events
- or fewer event kinds with structured payload metadata

Recommendation:

- favor explicit lifecycle over overloaded payload semantics

### Decision 4: whether bridge still synthesizes any timeline events

Recommendation:

- yes for bridge workflow state only when clearly marked as bridge-owned
- no for synthetic visible user prompts in the normal Codex act flow

## 17. Immediate Next Actions

The next work should start here:

1. Create a new branch for the rewrite track.
2. Capture a real fixture corpus from current failing and healthy turns.
3. Design the new canonical event schema and persistent store schema.
4. Implement the replay harness before implementing new runtime logic.
5. Finish removing the remaining hidden-plan legacy parsing and archive compatibility path.
6. Start the new Codex actor path without extending the old `thread_api` path any further.

## 18. Final Recommendation

Do not continue iterating on the current architecture except for temporary diagnostics needed to extract fixture truth.

The right move is:

- preserve the recent merge fix only as a stabilizer while the rewrite starts
- stop deepening current heuristics
- replace the bridge with a canonical event-log-and-actor model
- replace mobile reconciliation with exact correlation IDs and replay cursors
- replace hidden plan hacks with explicit workflow state

That is the shortest route to a system that is actually reliable.
