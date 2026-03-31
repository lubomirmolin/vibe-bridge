---
name: security-worker
description: Implement pairing, trust, policy enforcement, fail-closed reconnects, and audit/security behavior.
---

# Security Worker

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the work procedure.

## When to Use This Skill

Use for QR pairing protocol handling, trust registries, Tailscale-only connection enforcement, authorization modes, approval gating, revocation, identity mismatch handling, and audit/security event capture.

## Work Procedure

1. Read `mission.md`, `AGENTS.md`, `.factory/services.yaml`, and `.factory/library/security.md` before starting.
2. Identify the exact security contract this feature changes: trust creation, trust persistence, policy enforcement, revocation, or audit trail.
3. Write failing tests first, prioritizing negative cases:
   - malformed or reused tokens
   - unauthorized actions
   - stale or revoked trust
   - dangerous actions without approval
4. Implement the smallest secure change that makes the tests pass.
5. Manually verify fail-closed behavior in addition to success paths. Record what the user sees when access is denied or trust is invalid.
6. If a non-interactive session prevents the manual fail-closed walkthrough, explicitly record that as a deviation in the handoff and name the automated evidence you used instead. Do not claim `followedProcedure: true` if the manual fail-closed check was skipped.
7. In Exec mode, if positive-path infrastructure cannot be enabled locally (for example a missing or restricted Tailscale Serve mapping), record the exact environment blocker, capture automated success-path evidence where possible, and still perform a live fail-closed check against the degraded state.
8. Ensure sensitive actions generate audit/security records if the feature touches approvals, trust, or git mutations.
9. Never weaken the private-transport boundary or expose raw Codex credentials.

## Example Handoff

```json
{
  "salientSummary": "Implemented persisted trust records, single-device enforcement, and fail-closed reconnect checks for revoked or mismatched bridge identities.",
  "whatWasImplemented": "Added secure trust storage on both bridge and mobile abstractions, enforced one trusted phone per Mac, rejected reused pairing tokens, and blocked reconnect when trust was revoked or the stored bridge identity changed.",
  "whatWasLeftUndone": "Approval UI and settings surfaces that expose the policy state are handled by later mobile features.",
  "verification": {
    "commandsRun": [
      {
        "command": "cargo test --manifest-path /repo/Cargo.toml --workspace --jobs 5",
        "exitCode": 0,
        "observation": "Security unit and integration tests passed."
      }
    ],
    "interactiveChecks": [
      {
        "action": "Retried reconnect with revoked trust and with a mismatched bridge identity.",
        "observed": "Both attempts failed closed with a re-pair requirement instead of silently reconnecting."
      }
    ]
  },
  "tests": {
    "added": [
      {
        "file": "crates/bridge-core/tests/trust_fail_closed.rs",
        "cases": [
          {
            "name": "revoked trust cannot reconnect",
            "verifies": "A previously trusted phone is blocked until it re-pairs."
          },
          {
            "name": "reused pairing token is rejected",
            "verifies": "Replay attempts fail with a clear rejection path."
          }
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

- The security requirement conflicts with the accepted product model or mission boundaries.
- A change would require storing secrets insecurely or bypassing Tailscale/private transport constraints.
- The feature depends on mobile or desktop UX work beyond small diagnostics or policy messages.
