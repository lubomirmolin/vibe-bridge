---
name: mobile-worker
description: Build Flutter mobile flows for pairing, threads, approvals, git controls, and settings across iOS and Android.
---

# Mobile Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for Flutter app screens, navigation, state management, local cache wiring, secure storage integration, and user-facing mobile flows on both iOS and Android.

## Work Procedure

1. Read the mission artifacts and the relevant library notes before changing UI code.
2. Match the planned Flutter architecture: feature folders, Riverpod-based state flow, DTO mapping, and dense coding-tool UX.
   - if a baseline test conflicts with the newer intended UX, update the test contract instead of restoring outdated UI behavior unless you confirm a real user-visible regression
3. Write failing tests first:
   - widget tests for rendering and interaction states
   - integration tests for navigation and cross-screen behavior
   - for the real-data thread-detail parity mission, any new thread-detail widget fixture must be seeded from captured live bridge payloads for thread `019d0d0c-07df-7632-81fa-a1636651400a`; synthetic-only fixtures are not enough
   - if a cross-layer Flutter slice needs minimal controller/interface scaffolding before meaningful failing tests can compile, add only that minimal scaffolding first, then immediately add failing tests before continuing deeper implementation
   - when fixing thread timeline behavior, add tests that prove mixed non-message items are present before live pushes arrive and that stale cards from a previous thread are absent after switching
   - when adding debug pairing affordances, add tests that prove the affordance is debug-only, scan-state-only, and still routes through the existing trust-review/confirm flow
4. Implement the smallest vertical slice needed for the feature.
5. Run targeted Flutter tests first, then broader analyzers/tests from `.factory/services.yaml`.
6. Manually verify the flow on the best available local target (prefer macOS/iOS simulator during early work, include Android when the feature depends on parity-sensitive behavior).
   - for pagination work, verify that rows hidden at render time do not falsely count as newly visible content
   - for this mission's real failing thread, verify the initial slice and older-history pagination against captured live bridge payloads before claiming parity
   - for pairing work, verify that invalid/cancelled/finalize-failed attempts persist no trust in secure storage
7. If a headless or non-interactive worker session prevents live simulator/device verification, explicitly record that deviation and provide the strongest available widget/integration-test evidence for the user-visible states you could not inspect manually.
8. Record exact visible behavior for loading, empty, error, offline, and permission-gated states.

## Example Handoff

```json
{
  "salientSummary": "Built the Flutter thread list and detail flow with repo context, mixed-item rendering, and retryable thread-detail fallback states.",
  "whatWasImplemented": "Added thread list search, status/context rows, detail navigation, item rendering for prompts/assistant/plan/terminal/file changes, and explicit empty/error/retry states for both list and thread detail screens.",
  "whatWasLeftUndone": "Realtime reconnect deduplication and notification deep links are covered by later integration features.",
  "verification": {
    "commandsRun": [
      {
        "command": "cd /repo/apps/mobile && flutter test --concurrency=5 test",
        "exitCode": 0,
        "observation": "Widget and integration tests for the thread flows passed."
      },
      {
        "command": "flutter analyze /repo/apps/mobile",
        "exitCode": 0,
        "observation": "No analyzer errors remained."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Ran the Flutter app locally and opened multiple threads while simulated live events were arriving.",
        "observed": "The selected thread stayed correct, mixed item types rendered distinctly, and unavailable threads showed retryable fallback UI."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "apps/mobile/test/features/threads/thread_detail_test.dart",
        "cases": [
          {
            "name": "renders prompts, assistant text, plan, terminal, and file changes distinctly",
            "verifies": "Thread detail preserves event type distinctions."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- The required mobile behavior depends on missing backend contracts or ambiguous API semantics.
- A feature cannot be validated on both platforms because the environment is blocked in a way you cannot repair.
- The UI requirement conflicts with the mission’s architecture or access-control model.
