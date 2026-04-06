# User Testing

Testing surface, required testing skills/tools, and resource cost classification.

**What belongs here:** Testing surface findings, required tools, resource constraints, isolation notes.
**What does NOT belong here:** Service ports (use `services.yaml`), architecture (use `architecture.md`).

---

## Validation Surface

### Primary Surface: Android Emulator + Bridge Integration
- **Tool**: `flutter drive` for integration test execution
- **Description**: Live integration tests run on Android emulator against real bridge + Codex
- **Setup**: Start emulator → set up adb reverse → start bridge → run tests
- **Constraints**:
  - Single emulator instance at a time
  - Each test takes 3-10 minutes due to model latency
  - Tests must run sequentially (shared bridge state)
  - Android-only (`_requireAndroidLoopbackDevice` guard)

### Secondary Surface: Rust Unit Tests
- **Tool**: `cargo test`
- **Description**: Bridge unit tests for error handling, resource management, and API logic
- **Setup**: Build bridge binary
- **Constraints**: Can run in parallel (up to 5 workers)

### Secondary Surface: Flutter Unit Tests
- **Tool**: `flutter test`
- **Description**: Mobile app unit tests for transport, API clients, and controller logic
- **Setup**: `flutter pub get`
- **Constraints**: Can run in parallel (up to 5 workers)

## Validation Concurrency

### Integration Tests (Android Emulator)
- **Max concurrent validators: 1** (single emulator constraint)
- **Resource cost per validator**: ~300 MB (emulator) + ~200 MB (bridge/codex) = ~500 MB
- **Rationale**: Only one emulator instance can run tests at a time. Serial execution required.

### Unit Tests (Rust + Flutter)
- **Max concurrent validators: 3** (memory-constrained)
- **Resource cost per validator**: ~100 MB (compilation + test runner)
- **Rationale**: Machine has ~13.5 GB available. Each test runner uses ~100 MB. 3 concurrent leaves ample headroom.

## Isolation Notes

- Integration tests create new threads for each test — no shared thread state between tests
- Some tests require specific bridge state (e.g., `live_codex_large_thread_send_test.dart` needs 80+ entry threads)
- Approval tests reset trust state via `/pairing/trust/revoke` — this affects ALL concurrent sessions
- Tests should be run sequentially to avoid inter-test contamination
