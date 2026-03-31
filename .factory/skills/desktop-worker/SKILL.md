---
name: desktop-worker
description: Build the SwiftUI macOS shell, menu bar/status behavior, QR presentation, bridge supervision, and Codex.app compatibility actions.
---

# Desktop Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for the macOS shell, menu bar/background behavior, QR presentation, bridge supervision, paired-device status, and best-effort Codex.app integration.

## Work Procedure

1. Read the mission artifacts plus `.factory/library/architecture.md`, `environment.md`, and `user-testing.md`.
2. Inspect the existing macOS shell structure before changing it; preserve the agreed role of the shell as a companion and supervisor, not the primary control plane.
3. Write failing tests first where practical:
   - Swift unit tests for shell state models and supervision logic
   - small integration checks for desktop actions and state transitions
4. Implement the smallest coherent desktop slice.
5. Verify shell states manually: unpaired, paired-idle, paired-active, bridge-offline, and Codex.app failure cases where relevant.
   - If manual shell-state walkthroughs are not possible in the current run, capture explicit automated evidence for the state transitions you are claiming and record the skipped manual steps as deviations.
6. For Codex.app compatibility, keep behavior best-effort and fail gracefully; do not fall back to UI automation.
7. Record exactly what the user sees when bridge supervision recovers or a desktop action fails.

## Example Handoff

```json
{
  "salientSummary": "Built the menu bar shell state model, QR/status surface, and best-effort open-on-Mac action with graceful failure messaging.",
  "whatWasImplemented": "Added shell UI for pairing QR, bridge health, paired phone state, and active session summaries; wired the open-on-Mac action through supported deep-link behavior; and showed clear feedback when Codex.app could not be opened.",
  "whatWasLeftUndone": "Mobile notification deep links and cross-platform release checks are handled by later integration work.",
  "verification": {
    "commandsRun": [
      {
        "command": "xcodebuild test -project /repo/apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS'",
        "exitCode": 0,
        "observation": "Shell state and supervision tests passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Closed the launching terminal, inspected the menu bar shell, and exercised both successful and failing open-on-Mac flows.",
        "observed": "The shell stayed alive, status remained visible, and Codex.app failures produced clear user-facing feedback without breaking mobile state."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "apps/mac-shell/Tests/ShellStateTests.swift",
        "cases": [
          {
            "name": "maps runtime conditions into explicit shell states",
            "verifies": "The shell differentiates unpaired, paired-idle, paired-active, and degraded states."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- The feature would require unsupported or brittle Codex.app UI automation.
- The macOS packaging or lifecycle requirement conflicts with the planned project structure.
- Desktop behavior depends on missing backend/mobile capabilities that cannot be stubbed safely.
