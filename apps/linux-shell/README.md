# Codex Linux Shell

Linux host shell for the Codex Mobile Companion bridge runtime.

## What It Does

- Supervises a local `bridge-server`
- Shows runtime health, pairing status, active session, and running thread count
- Generates pairing QR payloads for the mobile app
- Supports best-effort Linux tray integration
- Bundles `bridge-server` into the Linux desktop artifact

## Run

```bash
flutter run -d linux
```

## Validate

```bash
flutter analyze
flutter test
```

## Build

```bash
flutter build linux
./tool/build_appimage.sh
```

`build_appimage.sh` requires `appimagetool`.
