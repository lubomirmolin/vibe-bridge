# Mobile App

Flutter companion app for Codex on iOS simulators and Android emulators.

## Features

- QR/manual pairing with trusted Mac bridge
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

## Notes

- Use simulators/emulators only for this mission.
- Do not run the live bridge approval E2E on a physical Android device.
- Notifications are foreground-only in this build.
