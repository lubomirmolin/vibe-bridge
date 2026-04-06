# Emulator E2E Guide

This guide is for agents adding or running real end-to-end mobile tests on an
Android emulator against the local bridge.

It is intentionally about the workflow, not one specific scenario.

## Goal

Use the mobile UI to drive a real thread against the real bridge, then verify
the outcome from outside the app as well.

For this repo, a good emulator E2E does all of the following:

- uses a real Android emulator, not a physical device
- talks to the real bridge process
- drives the real Flutter UI
- triggers a real provider or bridge action
- verifies the result through bridge state or workspace state, not only UI text

## Why Android Emulator

The mobile app talks to the bridge through emulator-reachable localhost. A
physical Android device cannot reliably use the same host loopback path.

Use an Android emulator and either:

- `http://10.0.2.2:3110`
- or `adb reverse tcp:3110 tcp:3110` plus `http://127.0.0.1:3110`

The second option is usually more stable in this repo.

## Recommended Test Shape

Build the test around a deterministic external side effect.

Good examples:

- edit one known file
- toggle one known color/token/string
- create one known bridge-visible thread action
- resolve one known approval prompt

Avoid open-ended prompts. The agent under test should be forced into one narrow
action that can be checked afterward.

## Pattern

### 1. Preflight the environment

Before pumping the app:

- ensure the bridge is reachable
- ensure the workspace you want exists in the bridge thread list
- ensure the emulator is booted
- prefer a clean, known probe target

If the bridge does not yet know the workspace, create a seed thread first.

### 2. Use a dedicated probe target

Use a disposable, obvious target in the repo.

Properties of a good probe target:

- isolated from unrelated product behavior
- easy to prompt against precisely
- easy to diff on disk afterward
- safe to toggle back and forth between two values

This matters because real provider flows are noisy. You want exactly one thing
to prove that the E2E completed.

### 3. Pump the real app

Instantiate the real page/widget tree with normal app providers, but keep local
test-only overrides minimal.

Typical safe overrides:

- in-memory secure storage

Avoid mocking the thread APIs in a real E2E. The bridge and provider should be
real.

### 4. Drive the UI only through stable keys

Every step in a real device test should use stable `Key` lookups.

Prefer:

- create-thread button keys
- composer input key
- submit button key
- approval option keys
- model/provider picker keys

Do not depend on fragile text matching when a keyed control exists.

### 5. Wait for bridge-visible state transitions

After submitting the prompt, wait for the selected thread id and then poll
bridge snapshot endpoints for the real thread.

Useful checkpoints:

- thread created with expected provider prefix
- pending user input appears
- pending user input resolves
- file change event appears
- thread status becomes `completed`

Do not rely only on `pumpAndSettle()` for long-running provider work.

### 6. For approvals, verify both UI and bridge

A real approval E2E should assert:

- the mobile approval card is visible
- normal input/send controls are hidden if the UX requires that
- tapping an option submits immediately
- bridge `pending_user_input` clears
- the downstream action actually happens

UI-only success is not enough. The approval can look tapped while the bridge
still rejects or ignores it.

### 7. Verify the final side effect outside the app

After the UI flow completes, verify one of:

- bridge snapshot contains the expected event
- workspace file content changed as expected
- git diff contains the expected mutation

The app UI is not the source of truth for a real E2E. The bridge/workspace is.

## Runner Choice

For long Android emulator flows in this repo, prefer `flutter drive` over raw
`flutter test integration_test/... -d ...`.

Reason:

- the raw device test runner can lose the app or VM service during teardown on
  Android
- `flutter drive` gives cleaner device attachment and better host-side control

Use a dedicated driver entrypoint in `test_driver/`.

## Host-Side Recovery

If the app completes the real work but the VM service disappears during teardown,
the host driver should verify outcome from the bridge/workspace before treating
the run as failed.

A practical recovery strategy:

1. Record baseline state before launch.
   Baseline examples:
   - latest Claude thread id for the workspace
   - current probe file contents
2. Run the device test normally.
3. If the driver loses the VM service at the end, poll the bridge and workspace.
4. Accept the run if:
   - a newer matching thread completed
   - pending approval is gone
   - expected file change event exists
   - probe file contents changed

This avoids false negatives caused by Android teardown races.

## Commands

### Start emulator

```bash
$HOME/Library/Android/sdk/emulator/emulator \
  -avd <avd-name> \
  -no-snapshot \
  -no-boot-anim \
  -gpu swiftshader_indirect
```

### Verify boot

```bash
$HOME/Library/Android/sdk/platform-tools/adb devices -l
$HOME/Library/Android/sdk/platform-tools/adb shell getprop sys.boot_completed
```

### Forward bridge port

```bash
$HOME/Library/Android/sdk/platform-tools/adb reverse tcp:3110 tcp:3110
```

### Run one live E2E

```bash
cd apps/mobile
flutter drive --keep-app-running \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/<test_file>.dart \
  -d <android-emulator-id> \
  --dart-define=LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL=http://127.0.0.1:3110 \
  --dart-define=LIVE_CODEX_THREAD_CREATION_WORKSPACE=/absolute/workspace/path
```

## Pitfalls

- Do not run the whole `integration_test/` directory in one Android session.
- Do not use a physical Android device for localhost bridge tests.
- Do not assert only on visible assistant text.
- Do not depend on provider behavior that edits multiple files.
- Do not use a probe target that a formatter or watcher may rewrite.
- Do not ignore bridge path construction bugs for nested routes like
  `user-input/respond`.

## What Good Looks Like

A strong emulator E2E leaves behind evidence that an agent can audit quickly:

- one created thread id
- one approval request id if applicable
- one explicit bridge-side resolution
- one concrete workspace mutation
- one passing runner command

If those five pieces are present, the flow is usually trustworthy.
