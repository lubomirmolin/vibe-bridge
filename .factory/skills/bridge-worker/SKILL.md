---
name: bridge-worker
description: Fix Rust bridge-core error handling, resource management, HTTP status code differentiation, and write unit tests.
---

# Bridge Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE.

## When to Use This Skill

Use for Rust bridge-core fixes including: replacing bare `StatusCode` returns with `ErrorEnvelope` in `api.rs`, fixing resource management (actor eviction, notification backoff, auto-mode transport lifecycle), adding proper HTTP status code differentiation across endpoints, and writing Rust unit tests for all bridge behavior changes.

## Required Skills

None.

## Work Procedure

1. Read the mission artifacts and `.factory/library/api.md`, `architecture.md`, and `security.md` before implementing.
2. Audit `crates/bridge-core/src/server/api.rs` to identify all handler functions that return bare `Result<Json<T>, StatusCode>` instead of `Result<Json<T>, (StatusCode, Json<ErrorEnvelope>)>`.
   - Known candidates: `thread_snapshot`, `create_thread`, `thread_history` (timeline page).
   - Each bare `StatusCode` return must be replaced with a structured `ErrorEnvelope` using the existing `error_response()` helper.
3. Fix resource management issues in the gateway and state modules:
   - **Actor eviction**: inspect `crates/bridge-core/src/server/gateway/codex/actor.rs` for stale actor cleanup paths; ensure evicted actors release their transport and subscriptions.
   - **Notification backoff**: inspect `crates/bridge-core/src/server/gateway/codex/notifications.rs` for retry/backoff logic on failed notification delivery; add bounded backoff if missing.
   - **Auto-mode transport**: inspect `crates/bridge-core/src/server/gateway/codex/transport.rs` for the `--codex-mode auto` transport lifecycle; ensure transports are lazily spawned, health-checked, and torn down on bridge shutdown.
4. Add proper HTTP status code differentiation:
   - `404 Not Found` for missing threads/resources.
   - `409 Conflict` for duplicate or already-resolved mutations.
   - `422 Unprocessable Entity` for semantically invalid payloads that pass basic deserialization.
   - `502 Bad Gateway` for upstream Codex failures.
   - `503 Service Unavailable` for transient unavailability (pairing route, auth).
   - Follow the patterns already established in `thread_usage_error_response()`, `turn_error_response()`, and `git_diff_error_response()`.
5. Write Rust unit tests for every fix:
   - For `ErrorEnvelope` conversions: test that each formerly-bare-StatusCode endpoint now returns a JSON body with `error`, `code`, and `message` fields and the expected HTTP status.
   - For actor eviction: test that evicted actors are removed from the active set and their transport is dropped.
   - For notification backoff: test that backoff delay increases on repeated failures and resets on success.
   - For auto-mode transport: test that transport is created on first use and that shutdown cleans up.
   - Place tests in `crates/bridge-core/src/server/gateway/tests.rs` or `crates/bridge-core/src/server/state/tests.rs` as appropriate.
6. Run validation:
   - `cargo fmt --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --all --check`
   - `cargo clippy --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --all-targets -- -D warnings`
   - `cargo test --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --jobs 5`
7. All three commands must exit 0 before marking work complete.

## Example Handoff

```json
{
  "salientSummary": "Replaced all bare StatusCode returns in api.rs with structured ErrorEnvelope responses and fixed actor eviction/notification backoff in the bridge gateway.",
  "whatWasImplemented": "Converted thread_snapshot, create_thread, and thread_history handlers from bare StatusCode to (StatusCode, Json<ErrorEnvelope>). Added bounded exponential backoff to notification delivery. Ensured evicted actors release their Codex transport. Added unit tests for all three areas.",
  "whatWasLeftUndone": "Integration-level HTTP tests against a live bridge were not run; that belongs to the integration-test-worker.",
  "verification": {
    "commandsRun": [
      {
        "command": "cargo fmt --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --all --check",
        "exitCode": 0,
        "observation": "All files formatted correctly."
      },
      {
        "command": "cargo clippy --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --all-targets -- -D warnings",
        "exitCode": 0,
        "observation": "No clippy warnings."
      },
      {
        "command": "cargo test --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "All unit tests passed including new ErrorEnvelope, eviction, and backoff tests."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Called GET /threads/nonexistent-id on a running bridge.",
        "observed": "Response was 404 with JSON body {\"error\": \"...\", \"code\": \"thread_not_found\", \"message\": \"...\"} instead of bare 404."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "crates/bridge-core/src/server/gateway/tests.rs",
        "cases": [
          {
            "name": "thread_snapshot_returns_error_envelope_on_missing_thread",
            "verifies": "Bare StatusCode NOT_FOUND replaced with structured ErrorEnvelope."
          },
          {
            "name": "create_thread_returns_error_envelope_on_upstream_failure",
            "verifies": "Bare StatusCode BAD_GATEWAY replaced with structured ErrorEnvelope."
          },
          {
            "name": "evicted_actor_drops_transport",
            "verifies": "Evicted actors release their Codex transport handle."
          },
          {
            "name": "notification_backoff_increases_on_repeated_failures",
            "verifies": "Backoff delay grows exponentially and resets on success."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- The upstream `codex app-server` transport API changes in a way that breaks the auto-mode lifecycle logic beyond what can be inferred from the codebase.
- A resource management fix requires changes to shared contracts (`crates/shared-contracts`) that could affect other workers.
- Validation commands fail due to environment issues outside the bridge crate (e.g., missing system dependencies).
