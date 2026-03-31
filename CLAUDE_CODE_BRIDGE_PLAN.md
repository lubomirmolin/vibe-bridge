# Claude Code Bridge Integration Plan

## Goal

Extend the bridge so the mobile app can work with **Claude Code and Codex at the same time**, not by switching the whole bridge into one backend mode.

The intended UX is:

- a unified thread list for a workspace or repository
- each thread carries an **origin/provider** marker such as Codex or Claude Code
- the mobile app continues to consume the bridge's normalized thread and timeline DTOs
- provider-specific behavior is handled in the bridge, not pushed into Flutter

This is a **multi-provider aggregation** problem, not a simple `--backend codex|claude-code` toggle.

---

## What We Validated Locally

This plan is based on the current repository plus local Claude Code behavior observed on this machine on **March 31, 2026**.

### Claude Code facts confirmed locally

- Installed CLI: `claude 2.1.87 (Claude Code)`
- Public CLI flags include:
  - `-p`
  - `--input-format stream-json`
  - `--output-format stream-json`
  - `--include-partial-messages`
  - `--replay-user-messages`
  - `--session-id`
  - `--permission-mode`
- Public permission modes currently exposed:
  - `acceptEdits`
  - `bypassPermissions`
  - `default`
  - `dontAsk`
  - `plan`
  - `auto`
- `claude remote-control --help` confirms a persistent remote-control mode exists.
- The installed binary also contains hidden/internal strings for:
  - `--sdk-url`
  - `control_request`
  - `set_permission_mode`
  - `stream_event`
  - `attachment`
  - `tombstone`
  - `/v1/sessions`

### Claude Code persistence confirmed locally

- Local sessions exist under `~/.claude/projects/.../*.jsonl`
- Directory names are sanitized workspace paths, not necessarily hashes
- Real transcript entries include:
  - `user`
  - `assistant`
  - `progress`
  - `system`
  - `file-history-snapshot`
  - `last-prompt`
- Real entries include:
  - `uuid`
  - `parentUuid`
  - `sessionId`
  - `cwd`
  - `gitBranch`
  - `slug`
  - `timestamp`
- Assistant message content blocks seen locally include:
  - `text`
  - `thinking`
  - `tool_use`
- Tool results are represented as `user` messages with `tool_result` payloads.

### Important correction to the earlier plan

The previous plan assumed:

- a single active bridge backend
- Claude session storage at `~/.claude/projects/<hash>/<id>.jsonl`
- a smaller permission-mode set
- a likely safe post-hoc rename path

Those assumptions are not solid enough for the architecture we actually want.

---

## Current Repository Reality

The bridge today is strongly Codex-shaped.

Relevant code:

- [gateway.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/gateway.rs)
- [state.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/state.rs)
- [config.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/server/config.rs)
- [thread_api.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api.rs)
- [archive.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/archive.rs)
- [lib.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/shared-contracts/src/lib.rs)

Important observations:

- `BridgeAppState` holds a concrete `CodexGateway`
- the server expects Codex-specific capabilities beyond simple thread CRUD
- thread DTOs currently have no provider identity on summaries
- `ThreadDetailDto.source` exists, but today it means things like `cli` or `vscode`, not provider origin
- the codebase already has a useful merge model in `thread_api/archive.rs` for combining multiple thread views into one coherent snapshot

That merge pattern should be reused for provider aggregation.

---

## Product Model

We should explicitly model three different concepts that are currently conflated:

1. **Provider**
   Examples: `codex`, `claude_code`

2. **Client origin**
   Examples: `cli`, `vscode`, `remote_control`, `archive`

3. **Native thread/session id**
   The provider's own identifier

The bridge should expose a normalized thread identity such as:

```rust
pub struct ThreadOrigin {
    pub provider: ProviderKind,
    pub client: ThreadClientKind,
    pub native_id: String,
}
```

And a bridge-global thread id such as:

```text
codex:thread-123
claude:0a1cfac0-79b9-4ddc-86c8-9137eb21e19b
```

This avoids collisions and gives the Flutter app exactly what it needs for origin badges/icons.

---

## Architecture Direction

## 1. Replace single backend selection with provider aggregation

Do **not** add a bridge-wide runtime flag like:

```text
--backend codex
--backend claude-code
```

That would force the whole bridge into one provider at a time, which conflicts with unified mixed-origin thread lists.

Instead:

- enable Codex provider
- optionally enable Claude Code provider
- aggregate both into one projection store

High-level shape:

```rust
BridgeAppState
  -> ProviderRegistry
      -> CodexProvider
      -> ClaudeCodeProvider
  -> ThreadAggregator
  -> ProjectionStore
  -> EventHub
```

## 2. Use provider roles instead of one giant `Gateway` trait

The original `Gateway` trait is too thin for what `state.rs` actually needs, and the current state logic is coupled to Codex-only behaviors like:

- bootstrap
- live notification streams
- active turn resolution
- synthetic title generation
- desktop IPC

Instead split provider responsibilities:

### `ProviderArchive`

Read persisted sessions/threads and timeline history.

```rust
trait ProviderArchive {
    async fn list_threads(&self) -> Result<Vec<UpstreamThreadRecord>, String>;
    async fn read_thread(&self, bridge_thread_id: &str) -> Result<ThreadSnapshotDto, String>;
}
```

### `ProviderRuntime`

Optional live runtime operations.

```rust
trait ProviderRuntime {
    async fn start_thread(&self, request: StartThreadRequest) -> Result<ThreadSnapshotDto, String>;
    async fn start_turn(&self, request: StartTurnRequest) -> Result<TurnStartHandle, String>;
    async fn interrupt_turn(&self, request: InterruptTurnRequest) -> Result<TurnMutationAcceptedDto, String>;
    async fn subscribe_live_events(&self) -> Result<ProviderEventStream, String>;
}
```

### `ProviderCapabilities`

Bridge-facing capability description.

```rust
struct ProviderCapabilities {
    provider: ProviderKind,
    supports_live_streaming: bool,
    supports_interrupt: bool,
    supports_thread_rename: bool,
    supports_images: bool,
    supports_plan_mode: bool,
    supports_model_catalog: bool,
}
```

This gives us enough flexibility to support Claude incrementally.

---

## Provider Design

## Codex provider

Codex remains the primary fully interactive provider for now.

Responsibilities:

- current `CodexGateway` behavior
- desktop IPC integration
- model catalog from Codex
- existing approval and thread control behavior

This should be refactored behind the new provider interfaces, but functionally remain as-is.

## Claude Code provider

Claude support should be built in two layers.

### Layer A: archive/import

Read local Claude sessions from `~/.claude/projects/**.jsonl` and expose them as normalized threads and timeline entries.

This is the safest first step and unlocks:

- origin icons in thread list
- Claude thread detail rendering
- mixed project history
- thread merge behavior by workspace/repository

### Layer B: runtime control

Start/resume Claude sessions and stream normalized live events back into the bridge.

This should start conservatively and be version-gated.

---

## Claude Code Integration Strategy

## Phase 1: Read-only import

First deliverable should be:

- discover Claude sessions
- parse transcript chains
- normalize them into bridge timeline events
- show them in the same thread list as Codex

This phase does not require hidden SDK behavior.

### Discovery

Scan:

```text
~/.claude/projects/*/*.jsonl
```

Extract from transcript entries:

- `sessionId`
- `cwd`
- `gitBranch`
- `slug`
- timestamps
- latest visible assistant/user activity

Bridge thread id:

```text
claude:<sessionId>
```

### Metadata mapping

Claude thread summary/detail should map to:

- `provider = claude_code`
- `client = cli` by default unless better evidence is available
- `workspace = cwd`
- `branch = gitBranch`
- `title = slug` or derived fallback
- `updated_at = latest visible event timestamp`
- `source` should remain client-ish, not provider-ish

### Timeline mapping

Normalize Claude transcript entries into existing event kinds first:

- assistant text -> `MessageDelta`
- user text -> `MessageDelta` with `role=user`
- tool use -> `CommandDelta`
- tool result with patch/file update -> `FileChange` or `CommandDelta`
- plan-mode shaped data -> `PlanDelta` where possible
- permission/tool approval -> `ApprovalRequested`
- turn completion/system events -> `ThreadStatusChanged`

Important rule:

Do not add new event kinds unless normalization proves impossible. The Flutter timeline is already generic enough to tolerate provider-specific payload shapes.

---

## Phase 2: Unified mixed-origin thread list

This is the first visible UX milestone.

### Contract changes

Update shared contracts to add provider identity to both summary and detail.

Recommended additions:

```rust
pub enum ProviderKind {
    Codex,
    ClaudeCode,
}

pub enum ThreadClientKind {
    Cli,
    Vscode,
    RemoteControl,
    Archive,
    Unknown,
}
```

Extend:

- `ThreadSummaryDto`
- `ThreadDetailDto`
- optionally `BootstrapDto`

Recommended fields:

```rust
pub provider: ProviderKind,
pub client: ThreadClientKind,
pub native_thread_id: String,
```

Do **not** overload existing `source` with provider.

### Mobile changes

The mobile app should stay mostly unchanged, but:

- thread list cards need origin badge/icon support
- thread detail header can show provider/client metadata
- filtering/grouping can later include provider if useful

Current thread summaries do not include origin metadata in [bridge_contracts.dart](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/lib/foundation/contracts/bridge_contracts.dart), so the contract must move first.

---

## Phase 3: Claude runtime MVP

After read-only import works, add interactive Claude turns.

### Recommended first runtime path

Use the public CLI streaming path first:

```text
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --include-partial-messages \
  --replay-user-messages \
  --session-id <uuid> \
  --permission-mode <mode>
```

For new sessions:

- create bridge-owned session ids
- launch Claude with that session id
- persist/resume using Claude's own session store

For existing sessions:

- use the session id from imported Claude threads

### Why this path first

- publicly visible flags exist today
- lower coupling to hidden remote-control internals
- enough to prove message normalization, threading, and approvals

### Important limitation

This subprocess model may be turn-scoped rather than daemon-scoped. That is acceptable for MVP if the bridge preserves unified thread identity and timeline continuity.

---

## Phase 4: Claude live control experimental path

Only after the MVP is solid should we add an experimental transport that relies on hidden/internal SDK behavior.

Possible future transport:

- hidden `--sdk-url`
- remote-control/session-style live channel
- explicit control messages like `control_request`

This should be:

- optional
- version-gated
- clearly marked as experimental in the bridge logs

Do not make this the only supported Claude transport.

---

## Permissions and approvals

Claude permission modes are not the same concept as bridge trust/access mode.

Current bridge concepts:

- pairing trust
- `AccessMode`
- approval gating

Claude concepts:

- session permission mode
- per-tool permission checks

Recommended separation:

- keep bridge trust model as the security boundary for remote mobile control
- map Claude tool permission requests into existing approval DTOs
- store Claude session permission mode separately from bridge `AccessMode`

### Contract additions

If the mobile app needs Claude session controls, add:

```rust
pub enum ClaudeCodePermissionMode {
    Default,
    Plan,
    AcceptEdits,
    DontAsk,
    BypassPermissions,
    Auto,
}
```

But do not replace `AccessMode` with it.

---

## Thread naming and metadata

Codex has explicit thread naming support.

Claude is less clear:

- `--name` is a startup option
- a safe rename-after-creation path was not validated

Recommendation:

- do not depend on post-hoc rename support for Claude
- derive display title from:
  - explicit name if present
  - slug if present
  - last user prompt
  - workspace fallback

If later we find a supported rename path, we can add it.

Do not patch Claude transcript files directly to fake rename support.

---

## Merging threads across providers

There are two different merge needs:

1. **Identity-preserving merge**
   One provider, multiple views of the same thread
   Example: live Codex RPC plus archived Codex session

2. **Project aggregation**
   Different providers, same workspace/repository
   Example: Codex thread and Claude thread both from the same repo

These must stay distinct.

### What not to do

Do not merge a Codex thread and Claude thread into one synthetic thread record just because they share a workspace.

That would destroy provider provenance and make turn continuation ambiguous.

### What to do

- keep one bridge thread record per provider-native thread/session
- group mixed-origin threads by workspace/repository in the list UI
- show origin badge on each thread

The existing merge logic in [archive.rs](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/crates/bridge-core/src/thread_api/archive.rs) remains useful for same-thread multi-view reconciliation, but should not be reused to fuse different-provider threads into one.

---

## Proposed File Layout

New provider-oriented modules:

```text
crates/bridge-core/src/
├── providers/
│   ├── mod.rs
│   ├── types.rs
│   ├── registry.rs
│   ├── codex/
│   │   ├── mod.rs
│   │   ├── archive.rs
│   │   └── runtime.rs
│   └── claude_code/
│       ├── mod.rs
│       ├── archive.rs
│       ├── runtime.rs
│       ├── transport.rs
│       └── transcript.rs
├── aggregation/
│   ├── mod.rs
│   └── thread_aggregator.rs
```

Suggested existing files to refactor:

```text
crates/bridge-core/src/server/state.rs
crates/bridge-core/src/server/config.rs
crates/bridge-core/src/server/api.rs
crates/bridge-core/src/server/gateway.rs
crates/shared-contracts/src/lib.rs
apps/mobile/lib/foundation/contracts/bridge_contracts.dart
apps/mobile/lib/features/threads/presentation/thread_list_page.dart
apps/mobile/lib/features/threads/presentation/thread_detail_page_header.dart
```

`gateway.rs` should likely shrink and become Codex-specific implementation detail, not remain the central abstraction.

---

## Implementation Plan

## Phase A: Contract and identity groundwork

Deliverables:

- add provider/client/native id fields to thread summary/detail DTOs
- add bridge-global thread ids with provider prefix
- add provider enums in Rust and Dart

Estimated effort:

- 1 to 2 days

## Phase B: Claude archive importer

Deliverables:

- scan `~/.claude/projects`
- parse transcript JSONL
- normalize into bridge summaries/details/timeline
- feed the projection store

Estimated effort:

- 2 to 4 days

## Phase C: Mixed-origin thread list UX

Deliverables:

- show origin icons/badges in thread list
- expose provider/client metadata in detail header
- preserve current timeline UI behavior

Estimated effort:

- 1 to 2 days

## Phase D: Claude runtime MVP

Deliverables:

- start/resume Claude sessions with public CLI streaming flags
- submit prompts
- stream partial assistant output
- normalize tool activity
- handle interrupt where feasible

Estimated effort:

- 3 to 5 days

## Phase E: Claude approvals and mode controls

Deliverables:

- map Claude permission prompts into approval flow
- expose Claude session permission mode separately from bridge access mode

Estimated effort:

- 2 to 3 days

## Phase F: Experimental hidden-SDK transport

Deliverables:

- optional `--sdk-url` transport
- version detection and fallback
- stronger live control handling

Estimated effort:

- 3 to 5 days

Total realistic path to a solid MVP:

- about 9 to 13 days without the experimental SDK transport

---

## Risks

## 1. Hidden Claude transport instability

Risk:

- hidden/internal flags may change without notice

Mitigation:

- make public CLI stream-json path the baseline
- gate hidden transport by CLI version
- keep importer and runtime loosely coupled

## 2. Incorrect provider/client/source modeling

Risk:

- provider identity gets mixed with client source and creates bad UX or bad thread continuation logic

Mitigation:

- separate `provider`, `client`, and `native_thread_id` explicitly in contracts

## 3. Overfitting Flutter to Claude payloads

Risk:

- mobile UI becomes provider-specific and hard to maintain

Mitigation:

- normalize at bridge layer
- add provider-specific event kinds only if normalization truly fails

## 4. False assumptions about rename/edit/session semantics

Risk:

- bridge starts mutating Claude persistence directly

Mitigation:

- avoid direct JSONL mutation
- treat unsupported operations as unsupported

## 5. Mixing provider threads too aggressively

Risk:

- Codex and Claude sessions get merged into one synthetic thread and become impossible to resume correctly

Mitigation:

- aggregate by project, not by cross-provider thread fusion

---

## Recommended MVP Definition

The MVP should be considered successful when:

- the bridge shows both Codex and Claude threads in one unified list
- each thread clearly shows its origin/provider
- Claude session history renders cleanly in the existing timeline UI
- a user can open a Claude thread and continue it from mobile
- the bridge still works normally for Codex

The MVP does **not** require:

- full Claude remote-control parity
- post-hoc thread rename
- provider-specific mobile screens
- hidden SDK transport

---

## Summary

The correct plan is:

- **not** "add a Claude backend switch"
- **yes** "add Claude as another provider inside a multi-provider bridge"

The bridge should become a provider aggregator with normalized thread identities and provider-aware DTOs. Claude support should begin with persisted-session import, then move to public CLI streaming, and only later experiment with hidden SDK transport.

That aligns with the product goal of merged project views with explicit thread origin and keeps Flutter mostly stable.
