# GitHub Publishing And Releases

This repository now ships with GitHub Actions for validation and tagged release
packaging:

- `.github/workflows/ci.yml` runs Rust, Android/Flutter, Linux shell, and
  macOS shell validation on pushes and pull requests.
- `.github/workflows/release.yml` builds release artifacts for Android, Linux,
  macOS, and the standalone Rust bridge when you push `main` or a `v*` tag.

## Make The Repository Public

This checkout has no GitHub remote configured, so the final visibility change
still has to happen in GitHub itself.

1. Create the GitHub repository and add it as `origin`, or connect this repo to
   an existing private GitHub repository.
2. Rename the release branch to `main` and push `main`.
3. Add a root `LICENSE` file before switching visibility. I did not choose a
   license on your behalf.
4. In GitHub, open `Settings` for the repository.
5. Change repository visibility to `Public`.

## Release Artifacts

Pushing to `main` updates a rolling prerelease on the GitHub Releases page with
tag `main-latest`.

Pushing a tag like `v1.0.0` builds and publishes a versioned release:

- `codex-mobile-companion-android-universal-<version>.apk`
- `codex-mobile-companion-linux-<arch>-<version>.tar.gz`
- `codex-mobile-companion-linux-<arch>-<version>.AppImage` when
  `appimagetool` is present on the runner or local machine
- `codex-mobile-companion-macos-<arch>-<version>.zip`
- `bridge-server-linux-<arch>-<version>.tar.gz`
- `bridge-server-macos-<arch>-<version>.tar.gz`
- `SHA256SUMS`

The Linux tarball contains the relocatable Flutter desktop bundle. The macOS
zip contains the unsigned `.app` bundle.

## Required Secrets

Main and tagged GitHub releases are configured to require a real release
keystore. Add these repository secrets before pushing `main` or a release tag:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

`ANDROID_KEYSTORE_BASE64` should be the base64-encoded contents of your JKS or
PKCS12 signing file.

Without those secrets:

- regular CI still builds the Android app with the debug signing config
- manual `workflow_dispatch` release runs can still produce preview artifacts
- pushes to `main` and tagged release runs fail the Android job instead of
  publishing a debug-signed APK

## Cutting A Release

1. Merge the release-ready state to `main` for rolling release updates.
2. Update the version values you want to ship.
3. Push a tag in the form `vX.Y.Z` when you want a versioned release.
4. Wait for the `Release` workflow to finish.
5. Review the GitHub Release page and attached artifacts.

## Local Packaging

The same packaging commands used by GitHub Actions are available locally:

```bash
./scripts/release/package-android.sh
./scripts/release/package-linux-shell.sh
./scripts/release/package-macos-shell.sh
./scripts/release/package-bridge.sh linux
./scripts/release/package-bridge.sh macos
```

Artifacts are written to `dist/`.
