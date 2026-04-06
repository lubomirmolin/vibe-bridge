# Live E2E Regression Audit (April 6, 2026)

## Scope
- Validate and fix reported regressions after the streaming rewrite:
  - duplicate assistant output (`"Hello"` then `"Hello."`)
  - duplicate user prompts in a new thread
  - missing response on a submitted message
- Run real emulator E2E against the local workspace bridge, not bundled bridge.
- Add truth-backed coverage against Codex JSONL rollout/session index data.

## Environment
- Date: `2026-04-06`
- Repo: `/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion`
- Device: `emulator-5554`
- Local bridge: `127.0.0.1:3310` (workspace build)
- Local bridge admin: `127.0.0.1:3311`
- Codex truth sources:
  - `~/.codex/session_index.jsonl`
  - `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`

## Fixes Applied
1. Mobile submit reentry guard (primary duplicate user-prompt cause)
- File: `apps/mobile/lib/features/threads/application/thread_detail_controller_mutations.dart`
- Added in-flight mutation guards to prevent double-submit races:
  - `submitComposerInput`
  - `respondToPendingUserInput`
  - `submitCommitAction`
  - `interruptActiveTurn`

2. Bridge stale notification-resume backoff
- Files:
  - `crates/bridge-core/src/server/state.rs`
  - `crates/bridge-core/src/server/state/streams.rs`
  - `crates/bridge-core/src/server/state/desktop_ipc.rs`
- Added stale-rollout cooldown (`resumable_notifications_stale_until`) and actor-side backoff behavior so `thread/resume` stale-rollout races are bounded instead of repeatedly churned.

3. New tests
- Rust:
  - `stale_rollout_backoff_blocks_immediate_notification_resume_requests`
  - `stale_rollout_backoff_expires_and_allows_notification_resume_requests`
- Flutter unit:
  - `thread-detail suppresses duplicate composer submits while a start-turn mutation is in flight`
- Flutter live host-side truth validation:
  - Extended `apps/mobile/test/features/threads/live_bridge_two_turn_duplicate_test.dart` to assert:
    - native thread exists in `session_index.jsonl`
    - rollout JSONL file exists for the native thread id
    - both prompts appear exactly once in rollout and exactly once in bridge timeline
    - rollout assistant message sequence exactly matches bridge timeline assistant sequence

## Live Verification Runs
- `run_live_test.sh apps/mobile/integration_test/live_codex_thread_creation_test.dart emulator-5554` -> PASS
- `run_live_test.sh apps/mobile/integration_test/live_codex_two_turn_diagnostics_test.dart emulator-5554` -> PASS
- `flutter drive --target=integration_test/live_codex_duplicate_text_test.dart ... --dart-define LIVE_CODEX_THREAD_CREATION_*` -> PASS
- `flutter test test/features/threads/live_bridge_two_turn_duplicate_test.dart --dart-define=RUN_LIVE_BRIDGE_TWO_TURN_DUPLICATE=true --dart-define=LIVE_BRIDGE_TWO_TURN_DUPLICATE_BASE_URL=http://127.0.0.1:3310` -> PASS

## Truth Cross-Check Evidence
- Example validated thread:
  - thread id: `codex:019d6346-a5c3-71c1-a1c2-7a554679a5ff`
  - rollout path: `/Users/lubomirmolin/.codex/sessions/2026/04/06/rollout-2026-04-06T16-51-07-019d6346-a5c3-71c1-a1c2-7a554679a5ff.jsonl`
- Probe output confirmed:
  - `session_index_contains_thread=true`
  - `rollout_prompt_one_count=1`
  - `rollout_prompt_two_count=1`
  - `timeline_prompt_one_count=1`
  - `timeline_prompt_two_count=1`
  - `assistant_lists_match=true`

## Bridge/App Diagnostics Artifacts
- Bridge startup/log stream was captured in active run output and showed bounded stale-rollout events (not runaway loops).
- Screenshots:
  - Home screen capture: `tmp/live_e2e_audit_2026-04-06.png`
  - App splash capture: `tmp/live_e2e_audit_2026-04-06_app.png`
  - In-app timeline capture: `tmp/live_e2e_audit_2026-04-06_app_after6s.png`

## Findings
1. Duplicate user prompts regression
- Status: fixed by mobile mutation reentry guards and covered by unit + live tests.

2. Duplicate assistant output symptom
- Status: not reproduced in live emulator verification after fixes; duplicate-focused live tests passed.

3. Missing response after submit
- Status: not reproduced in current live verification set; two-turn and duplicate-text flows completed with expected assistant outputs.

4. Residual low-severity signal
- `no rollout found` can still appear once during early resume race, but backoff prevents repeated immediate churn and tests remain green.

