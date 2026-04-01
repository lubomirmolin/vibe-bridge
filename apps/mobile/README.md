# Mobile App

Flutter Vibe bridge companion app for Codex on iOS simulators, Android emulators, desktop
Flutter targets, and a browser-localhost shell.

## Features

- QR/manual pairing with trusted Mac bridge
- Localhost startup that connects directly to the current machine over
  `http://127.0.0.1:3110` when the bridge is available
- Thread list/detail, live updates, offline cache, and reconnect recovery
- Turn controls, approvals, git actions, and settings
- Foreground notification routing and deduplication
- Open on Mac compatibility flow

## Run

From this directory:

```bash
flutter pub get
flutter devices
flutter run -d <simulator-or-emulator-id>
```

On macOS and in the browser, the app probes the local bridge first and opens
the current-machine thread UI directly when `http://127.0.0.1:3110` is
reachable.

For Flutter web:

```bash
flutter run -d chrome
```

The current browser implementation is a localhost-first thread shell. It skips
QR pairing and expects the bridge server to allow loopback browser origins.

If Android debug builds fail inside Rust-backed Flutter plugins, use the repo
wrapper so `flutter run` always gets the expected Rust environment:

```bash
./tool/run_android_debug.sh -d <android-device-id>
```

## Test

```bash
flutter test --concurrency=5

```

Integration tests should be pinned to an explicit simulator or emulator:

```bash
./tool/run_integration_suite.sh <simulator-or-emulator-id>
```

This runner executes each integration file serially. The raw
`flutter test integration_test -d ...` aggregate form is unreliable on Android
because Flutter rebuilds and reinstalls between files in one device session.

The live bridge approval E2E is Android-emulator-only because it talks to the
local bridge through the emulator loopback host:

```bash
./tool/run_integration_suite.sh <android-emulator-id>
```

It defaults to `http://10.0.2.2:3110`. Override `LIVE_BRIDGE_BASE_URL` only
when you need a different emulator-reachable bridge URL.

For agent-oriented guidance on building and running real emulator E2Es, see
[integration_test/README.md](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/integration_test/README.md).

## Notes

- Use simulators/emulators only for this mission.
- Do not run the live bridge approval E2E on a physical Android device.
- Notifications are foreground-only in this build.
