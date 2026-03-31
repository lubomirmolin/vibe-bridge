---
name: integration-worker
description: Close end-to-end gaps across mobile, bridge, and desktop, including reconnect, notifications, offline cache, parity, and release readiness.
---

# Integration Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for cross-system features that span bridge, mobile, and desktop boundaries: reconnect/catch-up, offline cache behavior, deep links, notification routing, platform parity, first-run journeys, and release/build closure.

## Work Procedure

1. Read all current mission artifacts plus the relevant `.factory/library/*.md` notes for every touched surface before starting, including `.factory/library/user-testing.md` and any matching contract/reference files such as `.factory/library/api.md`, `.factory/library/security.md`, or `.factory/library/architecture.md`.
2. Identify every surface this feature spans and list the prerequisites before editing.
3. Write failing end-to-end or integration tests first whenever the feature can be exercised automatically.
4. Implement the minimum coordinated change across components.
5. Run the targeted tests plus the shared validators that cover each touched surface.
   - When running Flutter integration tests, select an explicit simulator/emulator target first (for example via `flutter devices`) instead of relying on the default target selection.
   - Run Flutter `test` and `integration_test` suites in separate commands; current Flutter tooling does not support combining them in one invocation.
   - For Android live validation, start from an explicitly unpaired/empty-store state and do not count pre-seeded secure-store trust or out-of-band trusted-session setup as evidence.
   - For the real-data thread-detail parity mission, include `GET /policy/access-mode` in the evidence whenever visible control state depends on access mode.
6. Manually verify the full flow across lifecycle edges such as backgrounding, reconnect, cold start, offline mode, and platform switching.
   - In non-interactive Exec mode, explicit simulator/emulator integration evidence may satisfy this step when direct manual gesture-driven validation is not feasible, but you must state that fallback clearly in the handoff.
   - For this mission's Android live flow, capture proof of the reviewed pairing host/base URL, the mixed timeline snapshot before new live pushes, and active-thread-only updates after a thread switch.
   - For this mission's thread-switch hardening, include an in-flight HTTP response race (older-history or detail fetch) from the previous thread, not only a websocket update race.
7. Record detailed observations about what happened at each transition so gaps are obvious in the handoff.
8. If any required interactive lifecycle check cannot be run, record it as a deviation with the exact blocker and do not claim the procedure was fully followed.

## Example Handoff

```json
{
  "salientSummary": "Completed background and cold-start notification routing for approvals and live activity, with deduplicated reconnect behavior across the mobile and bridge layers.",
  "whatWasImplemented": "Added notification payload routing, deep-link restoration, offline-safe stale-notification handling, reconnect deduplication, and cross-component tests covering background resume, cold start, and repeated subscription recovery.",
  "whatWasLeftUndone": "Release packaging polish for all platforms remains for the later parity/build feature.",
  "verification": {
    "commandsRun": [
      {
        "command": "flutter test --concurrency=5 /repo/apps/mobile/integration_test",
        "exitCode": 0,
        "observation": "Notification and reconnect integration tests passed."
      },
      {
        "command": "cargo test --manifest-path /repo/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "Bridge-side deduplication checks passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Backgrounded and terminated the app, then opened approval and live-activity notifications across reconnect cycles.",
        "observed": "Both notification types opened the correct context, restored state once, and did not create duplicate items or duplicate actionable notifications."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "apps/mobile/integration_test/notification_reconnect_test.dart",
        "cases": [
          {
            "name": "cold-start approval notification restores the correct approval and thread",
            "verifies": "Notification deep links restore the right context after app termination."
          },
          {
            "name": "reconnect does not duplicate approval items or live notifications",
            "verifies": "Lifecycle restoration is deduplicated across repeated resumes."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- A cross-system flow cannot be validated because a prerequisite surface is still missing or broken.
- The change would require altering mission boundaries, credentials, or platform assumptions.
- Release-readiness work reveals a major architecture gap that should be decomposed into smaller features.
