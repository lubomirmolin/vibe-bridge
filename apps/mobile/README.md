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
flutter test integration_test -d <simulator-or-emulator-id>
```

## Notes

- Use simulators/emulators only for this mission.
- Notifications are foreground-only in this build.
