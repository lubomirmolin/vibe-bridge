---
name: bridge-worker
description: Implement the Rust bridge core, Codex adapter, stable API surface, and stream routing behavior.
---

# Bridge Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for the Rust bridge core, `codex app-server` adapter, REST/WebSocket endpoints, thread/turn/git backend behavior, stream normalization, and other bridge-owned runtime features.

## Work Procedure

1. Read the mission artifacts plus `.factory/library/api.md`, `architecture.md`, and `security.md` before implementing.
2. Inspect existing bridge modules and extend the established patterns instead of inventing a parallel API shape.
3. Write failing tests first:
   - unit tests for adapters, DTO mapping, and policy helpers
   - integration tests for HTTP/WS endpoints and event routing
   - when touching timeline paging, add tests for mixed event ordering, stable before-cursor page boundaries, and hidden-only older pages that should not strand user-visible history
4. Implement the backend behavior needed to make those tests pass.
5. Verify the bridge with both automated checks and manual API smoke tests using the commands in `.factory/services.yaml`.
6. When working on streaming features, verify thread scoping, deduplication, and lifecycle transitions with explicit observations.
7. For the real-data thread-detail parity mission, use thread `019d0d0c-07df-7632-81fa-a1636651400a` as the canonical regression input and compare `/threads/:id` against `/threads/:id/timeline` freshness whenever detail metadata is involved.
8. For thread timeline features, prefer fixing stable event identity/order/cursor semantics in the bridge instead of relying on mobile-only workarounds when the root cause is server page composition.
9. Do not expose raw `codex app-server` surfaces directly to clients; keep the product API normalized and stable.

## Example Handoff

```json
{
  "salientSummary": "Implemented normalized thread timeline and stream routing endpoints on the Rust bridge, backed by the local Codex adapter.",
  "whatWasImplemented": "Added bridge handlers for thread list/detail/timeline plus websocket subscription routing for message, plan, and command events. The adapter now maps upstream app-server notifications into stable mobile-facing events and scopes them by thread.",
  "whatWasLeftUndone": "Mobile UI for these events is not part of this feature; only bridge-side behavior and tests were completed.",
  "verification": {
    "commandsRun": [
      {
        "command": "cargo test --manifest-path /repo/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "Adapter and endpoint tests passed."
      },
      {
        "command": "curl -sf http://127.0.0.1:3110/threads",
        "exitCode": 0,
        "observation": "Bridge returned normalized thread payloads."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Subscribed a websocket client to a live thread and triggered upstream activity.",
        "observed": "Only the subscribed thread emitted normalized events and no duplicate deltas were observed."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "crates/bridge-core/tests/thread_streams.rs",
        "cases": [
          {
            "name": "thread subscriptions only receive matching thread events",
            "verifies": "The bridge does not leak live events across thread boundaries."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- Upstream `codex app-server` behavior is ambiguous enough that the stable bridge API cannot be designed safely.
- A feature requires UI or shell changes beyond small bridge-owned diagnostics.
- A service or runtime dependency outside the repo cannot be restored.
