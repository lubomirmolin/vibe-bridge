---
name: foundation-worker
description: Bootstrap and stabilize the greenfield workspace, tooling, shared contracts, and local validation environment.
---

# Foundation Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for workspace bootstrap, repo structure, shared contracts, validation harnesses, emulator repair, environment setup, and other foundational tasks that unblock later bridge, mobile, or desktop features.

## Work Procedure

1. Read `mission.md`, `AGENTS.md`, `.factory/services.yaml`, and relevant `.factory/library/*.md` notes before changing anything.
2. For bootstrap features, inspect the current tree and decide the smallest viable scaffold that matches the mission architecture.
3. Write tests or executable checks first whenever possible:
   - config/schema tests for shared contracts
   - smoke scripts for workspace layout or generated files
   - validation harness checks for emulator/tooling repair
4. Implement the scaffold or environment change in the smallest coherent slice.
5. Run the minimum targeted checks first, then the shared commands from `.factory/services.yaml` that are applicable.
6. Manually verify the foundation outcome the next worker depends on, for example:
   - generated project layout exists
   - Android emulator path works
   - shared contract files can be consumed by dependent components
7. Leave the repo in a clean, deterministic state. Do not leave half-generated projects or broken placeholder files behind.

## Example Handoff

```json
{
  "salientSummary": "Bootstrapped the monorepo skeleton, added shared contract definitions, and repaired the local Android emulator path so later workers can validate both mobile platforms.",
  "whatWasImplemented": "Created the initial workspace layout for apps/mobile, apps/mac-shell, and crates/bridge-core; added shared DTO contract stubs plus a validation harness; recreated the missing Android AVD assets so emulator-based checks can run locally.",
  "whatWasLeftUndone": "SwiftUI app logic and Flutter feature screens are not implemented yet; only the scaffold and validation environment are ready.",
  "verification": {
    "commandsRun": [
      {
        "command": "cd /repo/apps/mobile && flutter test --concurrency=5 test",
        "exitCode": 0,
        "observation": "Bootstrap smoke tests passed."
      },
      {
        "command": "cargo test --manifest-path /repo/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "Shared contract and workspace checks passed."
      },
      {
        "command": "flutter emulators",
        "exitCode": 0,
        "observation": "Android emulator definitions are now available."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Verified the workspace directories and generated config files exist in the expected locations.",
        "observed": "The scaffold matches the planned architecture and later workers can target stable paths."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "apps/mobile/test/bootstrap_smoke_test.dart",
        "cases": [
          {
            "name": "workspace bootstrap exposes expected directories",
            "verifies": "The greenfield project scaffold exists and is internally consistent."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- Required toolchains or SDKs are missing or broken in ways you cannot repair from the repo.
- The requested scaffold shape conflicts with an earlier architectural decision.
- A foundational dependency would force violating mission boundaries or ports.
