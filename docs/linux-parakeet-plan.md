# Linux Parakeet Speech-to-Text Support

## Problem
Speech transcription only works on macOS via FluidAudio (CoreML). Linux gets `UnsupportedSpeechBackend` from the bridge.

## Approach: sherpa-onnx backend

Use [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — a cross-platform C++ library with Rust bindings that runs NeMo/Parakeet models on Linux via ONNX runtime. Keeps FluidAudio on macOS (ANE acceleration).

## Model
- Source: `nvidia/parakeet-tdt-0.6b-v3` (ONNX export from HuggingFace)
- Store under: `<state_dir>/../FluidAudio/Models/parakeet-tdt-0.6b-v3-onnx/`
- Separate from macOS CoreML model to avoid collisions

## Changes

### 1. `crates/bridge-core/Cargo.toml`
- Add `sherpa-onnx` or `sherpa-onnx-sys` dependency (conditional on `target_os = "linux"`)

### 2. `crates/bridge-core/src/server/speech.rs`
- New `LinuxSpeechBackend` struct implementing `SpeechBackend` trait
- Methods: `status()`, `ensure_model()`, `remove_model()`, `transcribe_file()`
- `ensure_model()` downloads ONNX weights from HuggingFace on demand
- `transcribe_file()` runs inference in-process (no child helper needed)
- Update `SpeechService::from_config()` platform match:
  ```rust
  let backend = if cfg!(target_os = "macos") {
      MacSpeechBackend::new(...)
  } else if cfg!(target_os = "linux") {
      LinuxSpeechBackend::new(...)
  } else {
      UnsupportedSpeechBackend
  };
  ```

### 3. `apps/linux-shell/lib/src/shell_controller.dart`
- Remove hardcoded "not available from the Linux shell yet" messages
- Enable install/remove actions (set `isReadOnly: false` for ready/notInstalled states)

### 4. `apps/linux-shell/lib/src/bridge_shell_api_client.dart`
- Add `PUT /speech/models/parakeet` (install model)
- Add `DELETE /speech/models/parakeet` (remove model)
- Add `POST /speech/transcriptions` (transcribe)

### 5. `apps/linux-shell/lib/src/shell_presentation.dart`
- Remove hardcoded `isReadOnly: true` from speech panel

### 6. Tests
- `crates/bridge-core/src/server/speech.rs` — unit tests for `LinuxSpeechBackend` model lifecycle
- Verify existing API route tests still pass (they test via `SpeechBackend` trait)
- `apps/linux-shell/test/` — update speech panel presentation expectations

## Out of scope
- Speech recording from Linux shell (needs `record` package + mic permissions — separate work)
- Windows support
- Sharing model weights between macOS and Linux (different formats)

## Verification
```bash
cargo check --workspace
cargo test --workspace
cd apps/linux-shell && flutter analyze && flutter test
```
