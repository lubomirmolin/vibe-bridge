# Live E2E Exploratory Issues (April 6, 2026)

## Environment
- Repo: `/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion`
- Device: `emulator-5554`
- Bridge: `http://127.0.0.1:3310` (workspace bridge build)

## What I exercised
- `live_codex_thread_status_order_test.dart`
- `live_codex_turn_interrupt_test.dart`
- `live_codex_title_generation_test.dart`
- `live_codex_quick_action_consistency_test.dart`
- `live_codex_model_switch_history_test.dart`
- `live_codex_reopen_thread_send_diagnostics_test.dart`

## Issue 1 (High): Duplicate visible user prompts in bridge history for some flows

### Symptom
For some threads, bridge `/history` and `/snapshot` contain two visible user prompt entries for the same original prompt:
- one archive-backed `userMessage` entry carrying `delta`
- one canonical `message` entry carrying `text`

This reproduces duplicate user prompt ordering in quick-action and interrupt flows.

### Evidence
- Interrupt flow thread:
  - `codex:019d6350-3c7a-70e2-a0ec-f7cdfaf2bc05`
  - `/history?limit=200` user prompts show the same prompt twice.
  - Distinct event ids:
    - `codex:...-archive-2` (`payload.type=userMessage`, `delta=...`)
    - `019d...-<uuid>` (`payload.type=message`, `text=...`)

- Quick action flow thread:
  - `codex:019d6354-edc8-73e0-bab1-2977fc08ef22`
  - `/history?limit=200` prompts:
    - `Reply with READY...`
    - `Reply with READY...` (duplicate)
    - `Commit`
    - `Commit`
  - Archive/canonical duplicate pair appears for the first prompt.

### Why this matters
- This is user-visible ordering drift in the bridge history contract.
- It cascades into false prompt counts and turn-completion waits that key off prompt index.

## Issue 2 (High): Quick-action consistency live test fails from prompt duplication side effects

### Symptom
`live_codex_quick_action_consistency_test.dart` failed in exploratory run with:
- timeout waiting for commit turn completion
- repeated quick-action prompt order mismatch

### Failure outputs observed
- `real bridge Codex commit quick action keeps live snapshot and history prompts aligned`
  - timeout:
  - `expected_user_prompt_count=2`
  - observed prompts:
    - `Reply with READY...`
    - `Reply with READY...`
    - `Commit`
- `real bridge Codex repeated commit quick actions keep exact visible prompt counts`
  - expected:
    - `Reply with READY...`, `Commit`, `Commit`
  - actual:
    - `Reply with READY...`, `Reply with READY...`, `Commit`, `Commit`

### Likely root cause
- Same as Issue 1: archive-backed + canonical prompt duplication in bridge timeline/snapshot materialization.

## Issue 3 (Medium): Status-order live test appears flaky at thread-detail transition

### Symptom
`live_codex_thread_status_order_test.dart` failed once, then passed on immediate rerun.

### Failure
- Missing key:
  - `thread-detail-session-content`
  - expected one, found zero
  - failure site: `integration_test/live_codex_thread_status_order_test.dart:102`

### Notes
- Same bridge/emu setup passed on rerun.
- This looks like navigation/render timing flake rather than deterministic bridge logic failure.

## Non-issues from this pass
- `live_codex_turn_interrupt_test.dart`: PASS
- `live_codex_title_generation_test.dart`: PASS
- `live_codex_model_switch_history_test.dart`: PASS
- `live_codex_reopen_thread_send_diagnostics_test.dart`: PASS

## Suggested next fix order
1. Fix bridge history/snapshot prompt de-dup for archive userMessage vs canonical message pair.
2. Rerun quick-action consistency suite after that fix.
3. Stabilize status-order test transition checks (wait-for-detail-content before strict `expect`).

