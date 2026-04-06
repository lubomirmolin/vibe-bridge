---
name: integration-test-worker
description: Run live integration tests on the Android emulator against a real bridge and Codex, diagnose failures, and fix issues in either layer.
---

# Integration Test Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for running live integration tests against a real bridge server and Codex instance on the Android emulator. This worker is the primary worker for milestones 3 and 4. It handles bridge lifecycle, adb port forwarding, running integration tests via `flutter drive`, diagnosing failures with full output, and fixing issues in either the bridge OR the mobile app discovered during testing.

## Required Skills

None.

## Work Procedure

1. Read the mission artifacts and `.factory/services.yaml` for service start/stop/healthcheck commands before beginning.
2. Verify the bridge server is running and healthy:
   - Run healthcheck: `curl -sf http://127.0.0.1:3210/healthz`
   - If unhealthy or not running, start it: `cargo run --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml -p bridge-core -- --host 127.0.0.1 --port 3210 --codex-mode auto --state-directory /tmp/codex-mobile-companion-local-bridge`
   - Wait for healthcheck to pass before proceeding.
   - If the bridge fails to start, diagnose the error (check port conflicts, stale PID files, Cargo build errors) and fix before continuing.
3. Verify the Android emulator is running:
   - Run healthcheck: `$HOME/Library/Android/sdk/platform-tools/adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | grep -q 1`
   - If not running, start it: `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_6_Pro_API_34 -no-snapshot -no-boot-anim -gpu swiftshader_indirect &`
   - Wait for boot to complete.
4. Set up adb port forwarding so the emulator can reach the bridge:
   - `adb -s emulator-5554 reverse tcp:3210 tcp:3210`
   - Verify with: `adb -s emulator-5554 reverse --list`
5. Run the specified integration test(s):
   - Command pattern: `cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/<test_file>.dart -d emulator-5554`
   - If the mission specifies multiple tests, run them sequentially.
   - Capture full stdout/stderr for each test run.
6. Diagnose failures:
   - If a test fails, analyze the full output for the failure reason.
   - Categorize the failure:
     - **Bridge issue**: 5xx errors, WebSocket disconnects, missing data, wrong event format. Fix in `crates/bridge-core/`.
     - **App issue**: assertion failures, missing widgets, wrong state, timeout waiting for UI. Fix in `apps/mobile/`.
     - **Infrastructure issue**: emulator not ready, bridge not started, port forwarding missing. Fix infrastructure setup and retry.
   - For bridge fixes: follow the bridge-worker conventions (ErrorEnvelope, typed errors, unit tests).
   - For app fixes: follow the flutter-worker conventions (shared utilities, typed errors, widget tests).
7. After fixing, re-run the failing test(s) to confirm the fix.
8. Run full validation after all fixes:
   - `cargo test --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --jobs 5`
   - `cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter analyze`
   - `cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter test --concurrency=5`
9. Report results with full test output for every test run (pass or fail).

## Example Handoff

```json
{
  "salientSummary": "Ran live integration tests for thread creation, streaming, and approval flow against a real bridge + Codex on the Android emulator. Fixed a bridge notification ordering issue discovered during testing.",
  "whatWasImplemented": "Started bridge and emulator, set up adb reverse port forwarding, ran 3 integration tests. Discovered that bridge was emitting turn/started before item/started events reached the mobile WebSocket client due to a missing flush in the notification path. Fixed the flush ordering in crates/bridge-core/src/server/gateway/codex/notifications.rs and added a regression test.",
  "whatWasLeftUndone": "The live_codex_model_switch_history_test was skipped because the test requires a model not available in the current Codex configuration.",
  "verification": {
    "commandsRun": [
      {
        "command": "curl -sf http://127.0.0.1:3210/healthz",
        "exitCode": 0,
        "observation": "Bridge was healthy before test runs."
      },
      {
        "command": "adb -s emulator-5554 reverse tcp:3210 tcp:3210",
        "exitCode": 0,
        "observation": "Port forwarding established."
      },
      {
        "command": "cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_thread_creation_test.dart -d emulator-5554",
        "exitCode": 0,
        "observation": "Thread creation test passed. Thread appeared in list and detail loaded correctly."
      },
      {
        "command": "cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_thread_streaming_test.dart -d emulator-5554",
        "exitCode": 0,
        "observation": "Streaming test passed after notification ordering fix."
      },
      {
        "command": "cd /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_bridge_approval_flow_test.dart -d emulator-5554",
        "exitCode": 0,
        "observation": "Approval flow test passed. Approve and reject paths both worked."
      },
      {
        "command": "cargo test --manifest-path /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "All Rust tests passed including new notification ordering test."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Watched live WebSocket traffic during streaming test.",
        "observed": "Events arrived in correct order: turn/started → item/started → item/agentMessage/delta → item/completed → turn/completed."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "crates/bridge-core/src/server/gateway/codex/notifications.rs",
        "cases": [
          {
            "name": "notification_events_flush_in_order",
            "verifies": "Notifications are flushed to WebSocket clients in the order they were received from Codex."
          }
        ]
      }
    ]
  },
  "discoveredIssues": [
    {
      "severity": "medium",
      "description": "live_codex_model_switch_history_test requires a model (o3) not available in the current Codex configuration.",
      "suggestedFix": "Add a test precondition check that skips the test if the required model is unavailable, or configure Codex with the model before running."
    }
  ]
}
```

## When to Return to Orchestrator

- The bridge cannot start due to a Cargo build error or missing system dependency that requires investigation beyond code fixes.
- The Android emulator cannot boot or adb cannot connect despite standard troubleshooting.
- A test failure reveals a design-level issue in the API contract between bridge and mobile that requires architectural discussion.
- All specified tests pass and no new issues were discovered.
