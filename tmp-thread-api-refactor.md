# Thread API Refactor Note

Temporary note for the `crates/bridge-core/src/thread_api.rs` cleanup.

## Goal

Reduce `thread_api.rs` size and responsibility overlap without changing behavior or the public API.

## Target Split

1. `thread_api/patch_diff.rs`
   Contains `apply_patch` parsing and unified diff reconstruction helpers.
2. `thread_api/rpc.rs`
   Contains `CodexRpcClient`, wire DTOs, resume helpers, and model parsing helpers.
3. `thread_api/notifications.rs`
   Contains `CodexNotificationStream`, `CodexNotificationNormalizer`, and realtime delta helpers.
4. `thread_api/archive.rs`
   Contains archive discovery, session parsing, and archived event mapping.
5. `thread_api/timeline.rs`
   Contains DTO mapping, summarization, annotations, and shared timestamp/status conversion helpers.
6. `thread_api/sync.rs`
   Contains thread refresh receipts, snapshot signatures, and archive index reuse logic.
7. `thread_api/tests.rs`
   Holds the legacy integration-style `thread_api` test surface outside the production module.
8. `thread_api/service.rs`
   Future end state for `ThreadApiService` orchestration if we decide to split the remaining 1k-line parent file.

## Current Slice

- Extract `patch_diff`
- Extract `rpc`
- Extract `notifications`
- Extract `archive`
- Extract `timeline`
- Extract `sync`
- Move the giant inline `thread_api` test module into `thread_api/tests.rs`
- Keep focused tests in extracted modules
- Run `cargo fmt`, `cargo check`, `cargo test`, and `cargo clippy`

## Current State

- `thread_api.rs` is down to the public service/orchestration surface plus module wiring.
- The parent file is now 1082 lines instead of being a single 7k-line mixed-responsibility file.
- Validation is green after the latest split.

## Next Slice

- Decide whether `ThreadApiService` should stay in `thread_api.rs` or move into `thread_api/service.rs`.
- If we keep the current layout, the main remaining cleanup is splitting `tests.rs` into smaller test modules by concern.

## Constraints

- Preserve all current behavior and public interfaces.
- Keep callers unchanged.
- Favor moving cohesive helper families before changing service orchestration.
