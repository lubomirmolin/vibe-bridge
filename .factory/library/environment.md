# Environment

Environment variables, external dependencies, and setup notes.

**What belongs here:** Required env vars, external dependencies, dependency quirks, platform-specific notes.
**What does NOT belong here:** Service ports/commands (use `.factory/services.yaml`).

---

## External Dependencies

- **Codex CLI**: Available via bun at `/Users/lubomirmolin/.bun/bin/codex`
- **Flutter SDK**: 3.38.9 stable (Dart 3.10.8)
- **Rust Toolchain**: 1.94.0
- **Android SDK**: At `$HOME/Library/Android/sdk/`
- **Emulators**: Pixel_6_Pro_API_34 (preferred for testing)

## Environment Variables

Integration tests accept these via `--dart-define`:
- `LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL` — bridge URL (default varies by test)
- `LIVE_CODEX_THREAD_CREATION_WORKSPACE` — workspace path
- `LIVE_CODEX_THREAD_CREATION_PROMPT_ONE/TWO` — custom prompts for duplicate text test
- `LIVE_CODEX_QUICK_ACTION_WORKSPACE` — workspace for quick action tests
- `LIVE_BRIDGE_BASE_URL` — bridge URL for approval flow tests
- `LIVE_THREAD_UI_BRIDGE_BASE_URL` — bridge URL for UI timing test
- `LIVE_THREAD_UI_THREAD_ID` — specific thread for UI timing test

Bridge server accepts:
- `BRIDGE_HOST` — bind host (default: 127.0.0.1)
- `BRIDGE_PORT` — bind port (default: 3210)
- `CODEX_DESKTOP_IPC_SOCKET` — desktop IPC socket path

## Platform Notes

- macOS (darwin 24.6.0), Apple M1 Pro, 32 GB RAM, 10 cores
- Codex authentication is handled by the codex binary (no extra env vars needed)
- Android emulator must have adb port forwarding set up for bridge access
- Physical device (Samsung SM_F966B) also connected but prefer emulator for testing

## Dependency Quirks

- `rg` (ripgrep) is NOT installed — use `grep` or the Grep/Glob tools
- `gh` (GitHub CLI) is NOT installed
- Emulator GPU: `swiftshader_indirect` for software rendering
- Bridge PID file (`bridge-server.pid`) may be stale — always verify process is running
