# Environment

Environment variables, external dependencies, and setup notes.

**What belongs here:** required local tools, SDKs, platform notes, dependency quirks, and environment constraints.
**What does NOT belong here:** service ports and commands from `.factory/services.yaml`.

---

- Mission uses a local-only stack: Flutter/Dart, Rust/Cargo, Swift/Xcode, Tailscale, and the local `codex` CLI.
- Existing local findings during planning:
  - Flutter, Dart, Rust, Cargo, Swift, Xcode, Tailscale, and `codex app-server` are installed.
  - iOS/macOS validation path is available.
  - Android SDK exists, and a dry run successfully launched the Android emulator validation path; use the repair tooling only if emulator drift recurs.
- Android emulator repair is now scripted through `.factory/services.yaml` commands: use `android-repair` to recreate missing AVD payloads from checked-in definitions and `android-validate` to verify Flutter can enumerate Android targets afterward.
- For this mission's live validation, Android emulator runs should use the host bridge through `http://10.0.2.2:3110` unless `LIVE_BRIDGE_BASE_URL` is explicitly overridden for the emulator target.
- For the real-data thread-detail parity mission, treat `~/.codex` as read-only input. The primary regression thread is `019d0d0c-07df-7632-81fa-a1636651400a` (`Investigate thread detail sync`).
- Android live validation must begin from an unpaired/empty-store state when proving first-run manual pairing; seeded secure-store trust does not count as evidence for this mission.
- No external backend accounts or cloud services are part of v1.
- Sensitive material belongs in platform secure storage or macOS Keychain, never in repo-tracked plaintext files.
- Mobile secure storage is now backed by `PersistedSecureStore()`: `apps/mobile/lib/foundation/storage/secure_store_provider.dart` returns the persisted implementation so trusted-session and related secure values can survive real app process death/relaunch instead of living only in memory.
