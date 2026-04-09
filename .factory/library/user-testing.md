# User Testing

Testing surface notes, launch paths, and validation guidance for this mission.

**What belongs here:** how to start the app, what surfaces can be tested, device/simulator notes, and known quirks.

When sections in this file conflict, prefer the most recent mission-specific section for the active mission over older archival validation notes.

---

- Start localhost-first. Validate the bridge on `127.0.0.1:3110` before enabling Tailscale Serve.
- Early manual validation surfaces:
  - `curl` / websocket clients for bridge API behavior
  - Flutter on macOS or iOS simulator
  - SwiftUI macOS shell directly on the host
- Android parity is required; use the shared `android-repair` command first if emulator definitions drift, then use `android-validate` from `.factory/services.yaml` before starting Android-specific validation.
- Use iOS simulators and Android emulators for validation; do not rely on physical phones or tablets for this mission unless the user explicitly changes that rule.
- Important lifecycle checks:
  - background resume
  - reconnect and catch-up deduplication
  - offline cached thread readability
- Notification scope is foreground-only for this mission. Do not require true background or terminated-app notification delivery during validation.
- `Codex.app` validation is best-effort compatibility only; never use desktop UI automation as the primary test path.
- Pairing-security local setup confirmed on 2026-03-18:
  - `"/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/.factory/init.sh"` completes successfully.
  - `cargo run --manifest-path "/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/Cargo.toml" -p bridge-core --bin bridge-server -- --host 127.0.0.1 --port 3110 --admin-port 3111` starts the bridge locally.
  - `curl -sf http://127.0.0.1:3110/health` reported a reachable pairing route with advertised base URL `https://macbook-pro.taild54ede.ts.net`.
  - `tailscale serve status --json` showed the verified HTTPS MagicDNS front door proxying `/` to `http://127.0.0.1:3110`.

## Validation Concurrency

- `flutter-widget-tests`: max concurrent validators `1`.
  - Reason: Flutter test runs share the same build cache and test fixture workspace under `apps/mobile`; overlapping runs are needlessly expensive and can create flaky lock/contention behavior.
- `native-shell-and-bridge`: max concurrent validators `1`.
  - Reason: these checks share the live bridge process, Tailscale Serve mapping, and the canonical mission ports `3110`/`3111`.
- Combined ceiling for pairing-security: at most `2` validators at once, with only one validator on each surface above.

## Validation Concurrency: desktop-shell

- `native-shell-and-bridge`: max concurrent validators `1`.
  - Reason: desktop-shell runtime assertions share the live bridge process, Tailscale Serve mapping, trust state, and the reserved localhost ports `3110`/`3111`.
- `flutter-mobile-widget-tests`: max concurrent validators `1`.
  - Reason: desktop-shell mobile affordance checks reuse the same `apps/mobile` Flutter workspace, secure-store fixtures, and generated artifacts.
- Combined ceiling for desktop-shell: at most `1` validator at once.
  - Reason: this host currently has active IDE and droid processes, and the desktop-shell assertions overlap on shared trust/runtime state, so serial validation is the safest isolation boundary.

## Flow Validator Guidance: flutter-widget-tests

- Use `apps/mobile/test/features/pairing/pairing_flow_test.dart` and related pairing widget tests as the pairing user-surface harness.
- For pairing-security specifically, expired-QR coverage currently lives in `apps/mobile/test/features/pairing/pairing_qr_validator_test.dart`; malformed/reused/cancel/confirm flows live in `pairing_flow_test.dart`.
- Run Flutter commands from `apps/mobile` or with `flutter --directory`; do not run overlapping `flutter test` processes.
- Stay inside test-owned state only; do not write ad hoc files outside your assigned evidence/report directories.
- Do not kill or restart the shared bridge or Tailscale services from this surface.

## Flow Validator Guidance: native-shell-and-bridge

- Reuse the already running bridge on `127.0.0.1:3110` and the existing Tailscale Serve mapping instead of starting another instance.
- Do not reset Tailscale Serve, revoke live trust, or kill the shared bridge unless your assigned steps explicitly require it.
- Prefer read-only API checks (`/health`, `/pairing/session`) plus targeted native/Rust test commands for trust-conflict and reconnect invariants.
- Save any decoded payloads or command outputs needed as evidence under your assigned evidence directory.
- For desktop-shell assertions, use targeted `xcodebuild test` invocations for `CodexMobileCompanionTests` cases that cover unpaired, paired-idle, paired-active, degraded, launch-time supervision, and desktop trust revocation.
- Pair native-shell coverage with read-only live bridge checks such as `/health` and `POST /threads/:id/open-on-mac` so the response can prove best-effort desktop compatibility and matching thread identity without driving the Codex.app UI directly.

## Validation Concurrency: mobile-app

- `flutter-mobile-widget-tests`: max concurrent validators `1`.
  - Reason: all widget flows share the same `apps/mobile` Flutter build cache, provider-backed test fixtures, and generated artifacts; overlapping runs are prone to cache contention and slower than serialized execution.
- `flutter-mobile-integration-tests`: max concurrent validators `1`.
  - Reason: the reconnect/offline integration harness reuses the same Flutter workspace, secure-store fixtures, and integration test runtime, so it should not overlap with other Flutter validation work.
- Combined ceiling for mobile-app: at most `1` validator at once.
  - Reason: both surfaces exercise the same Flutter project and local caches, and serial execution gives the cleanest isolation for assertion synthesis.

## Flow Validator Guidance: flutter-mobile-widget-tests

- Run Flutter commands from `apps/mobile`; do not overlap `flutter test` processes with any other Flutter validation command.
- Reuse the existing mobile user-surface harnesses in `test/features/threads`, `test/features/approvals`, and `test/features/settings` to drive the real Flutter widgets through visible user interactions.
- Prefer targeted `flutter test <file> --plain-name "<test name>"` invocations so each assertion group leaves readable evidence tied to the observed user-facing behavior.
- Stay within test-owned state only; do not create ad hoc fixtures outside your assigned evidence/report directories.
- Treat the Flutter UI as the source of truth for user-visible pass/fail decisions, even when backing APIs are faked inside the harness.
- For desktop-shell assertions, use `test/features/threads/thread_detail_page_test.dart` for open-on-Mac success/failure and desktop integration affordance coverage, and `test/features/settings/settings_page_test.dart` for desktop integration persistence across relaunch.
- Desktop-shell mobile affordance checks should stay within provider/test-fixture state only; do not revoke live trust or mutate the shared bridge from Flutter widget tests.

## Flow Validator Guidance: flutter-mobile-integration-tests

- Run `integration_test/reconnect_offline_cache_test.dart` from `apps/mobile` and keep it serialized with all other Flutter validation work.
- Use the integration harness for reconnect, offline cache, and restoration assertions because it exercises the app shell, navigation, cache restore, and reconnect controls together.
- Save command output for each targeted integration test case under the assigned evidence directory so reconnect/offline observations remain traceable.
- Do not restart shared bridge or Tailscale services from this surface; these flows validate the mobile UI lifecycle harness rather than live network teardown.

## Validation Concurrency: hardening

- `hardening-mobile-integration`: max concurrent validators `1`.
  - Reason: the hardening flows reuse the same Flutter workspace, live bridge on mission ports `3110`/`3111`, iOS simulator, and Android emulator/adb state; overlapping runs have already proven brittle and would contend on caches plus device runtimes.
- `hardening-build-artifacts`: max concurrent validators `1`.
  - Reason: Flutter APK, Rust workspace, and macOS shell builds are resource-heavy on this host and should not overlap with simulator/emulator integration runs.
- Combined ceiling for hardening: at most `1` validator at once.
  - Reason: current machine load already includes Android Studio, an active Android emulator, IDE processes, and multiple droid workers, so serialized validation is the safest boundary.

## Flow Validator Guidance: hardening-mobile-integration

- Reuse the existing bridge at `http://127.0.0.1:3110`; do not kill or restart the shared bridge, admin port, or Tailscale Serve mapping from this surface.
- Run hardening integration tests from `apps/mobile` and keep all `flutter test ... -d <target>` runs serialized.
- Use `integration_test/reconnect_offline_cache_test.dart` for `VAL-CROSS-001`; the targeted case name is `first-run pairing lands directly in a live usable thread list`.
- Use `integration_test/notification_deep_links_and_dedup_test.dart` for `VAL-CROSS-002`, `VAL-CROSS-008`, and `VAL-CROSS-010`; notification scope for this milestone is foreground-only, so do not require true background or terminated-app delivery.
- Use `integration_test/live_bridge_approval_flow_test.dart` plus the reconnect/notification suites on both iOS simulator and Android emulator as the parity-critical mobile evidence for `VAL-PLATFORM-001`.
- Android runs rely on the test harness fallback to `http://10.0.2.2:3110`; if adb reports `Can't find service: activity/package`, repair or cold-boot the emulator via the shared Android validation harness before retrying.
- Save per-command logs under the assigned evidence directory so the synthesis can attribute each assertion to a concrete simulator/emulator run.

## Flow Validator Guidance: hardening-build-artifacts

- Use the shared build path from `.factory/services.yaml` or the equivalent explicit commands: `flutter build apk --debug` from `apps/mobile`, `cargo build --manifest-path Cargo.toml --workspace`, and `xcodebuild -project apps/mac-shell/CodexMobileCompanion.xcodeproj -scheme CodexMobileCompanion -destination 'platform=macOS' build`.
- Record the produced artifact locations or successful build output so `VAL-PLATFORM-002` has traceable evidence.
- Do not overlap build validation with any Flutter simulator/emulator integration run on this host.

## Validation Surface: timeline-hydration-and-android-live-validation

- Mission focus is the Flutter mobile thread timeline plus a debug-only pairing helper for deterministic Android emulator validation.
- Required user-surface sequence for final validation: unpaired debug build -> manual JSON pairing input -> trust review -> paired/home -> thread list -> thread detail -> thread switch -> upward pagination.
- When validating the timeline fix, capture evidence that mixed non-message items are present before new live pushes arrive; do not let stream activity mask an initial hydration regression.
- When validating pagination, include at least one case where the next older page contains only rows that remain hidden/collapsed in the rendered timeline.

## Validation Concurrency: timeline-hydration-and-android-live-validation

- `android-live-thread-validation`: max concurrent validators `1`.
  - Reason: Android emulator validation on this host uses roughly 4.2 GB RSS for the emulator plus roughly 493 MB peak for the Flutter launch path, and it shares the live bridge/trust state on ports `4222`, `3110`, and `3111`.
- `flutter-mobile-thread-tests`: max concurrent validators `1`.
  - Reason: thread-detail, pairing, and reconnect tests all share the same Flutter workspace/cache and are more reliable when serialized.
- Combined ceiling for this mission: at most `1` validator at once.
  - Reason: both automated and live validation paths share the same Flutter workspace, Android runtime, and trusted-session state.

## Flow Validator Guidance: timeline-hydration-and-android-live-validation

- Prefer `.factory/services.yaml` commands `mobile-thread-tests`, `mobile-pairing-tests`, and `android-live-debug-launch` when they match the needed evidence.
- For Android live runs, prove an initially unpaired/empty-store state before claiming first-run pairing success.
- Do not accept pre-seeded secure-store trust or out-of-band trusted-session setup as evidence for Android pairing assertions.
- Keep Android live runs serialized, and capture bridge/base-url proof showing the emulator reached the host bridge through `10.0.2.2` or the explicitly configured override.

## Validation Surface: real-data-thread-detail-parity

- Primary live validation target is the real Codex thread `019d0d0c-07df-7632-81fa-a1636651400a` (`Investigate thread detail sync`).
- Primary truth surface is the bridge/API path on `127.0.0.1:3110` using:
  - `GET /threads/:id`
  - `GET /threads/:id/timeline`
  - `GET /policy/access-mode`
- Flutter widget evidence only counts for this mission if fixtures are seeded from captured live bridge payloads for the target thread.
- Emulator validation is secondary and should be used to prove visible thread-detail parity once bridge and widget-test truth are in place.
- When validating thread-switch/reconnect fixes, include an in-flight older-history or detail response race from the previously selected thread; stream-only checks are insufficient.

## Validation Concurrency: real-data-thread-detail-parity

- `bridge-real-data-validation`: max concurrent validators `1`.
  - Reason: live bridge/API checks share the same running bridge, `codex app-server`, and the target thread's real local Codex state.
- `flutter-real-thread-validation`: max concurrent validators `1`.
  - Reason: Flutter widget/integration runs share the same workspace cache and, when emulator-backed, the same local device/runtime state.
- Combined ceiling for this mission: at most `1` validator at once.
  - Reason: current machine headroom is constrained by the active emulator, IDE processes, and live bridge/runtime services, and serialized validation avoids polluting the same real-thread state/evidence.

## Flow Validator Guidance: real-data-thread-detail-parity

- Use `.factory/services.yaml` commands `bridge-thread-tests`, `mobile-thread-tests`, `real-thread-detail-snapshot`, and `policy-access-mode` when they match the assigned evidence.
- Preserve `~/.codex` as read-only input throughout validation.
- For bridge assertions, compare target-thread detail/timeline responses directly against `~/.codex/sessions/...019d0d0c-07df-7632-81fa-a1636651400a.jsonl` when needed.
- After any bridge-core implementation feature completes, restart the shared bridge before live curl/manual validation so `127.0.0.1:3110` reflects the latest bridge binary rather than a stale long-running process.
- For Flutter assertions, prefer emulator screenshots plus explicit widget/integration assertions keyed to captured real-thread payloads; screenshots alone are not enough.
- For list/detail sync, prove the same target thread row and detail screen agree after detail refresh or reconnect catch-up.

## Validation Surface: thread-detail-performance

- Primary validation surface is live bridge/API timing on the canonical thread `019d0d0c-07df-7632-81fa-a1636651400a`.
- Measure both cold and warm sequential request pairs for:
  - `GET /threads/:id`
  - `GET /threads/:id/timeline?limit=80`
- Also measure a reconnect-style repeated pair on unchanged data to prove duplicate sync work is gone or reduced.
- Secondary validation surface is emulator-perceived initial-open speed only if backend changes materially affect the user-visible loading sequence.

## Validation Concurrency: thread-detail-performance

- `bridge-timing-validation`: max concurrent validators `1`.
  - Reason: timing evidence is only meaningful when the shared bridge and target thread are measured serially without overlapping requests from other validators.
- `emulator-perf-validation`: max concurrent validators `1`.
  - Reason: emulator timing and perceived-load checks share the same Flutter workspace, emulator runtime, and bridge process.
- Combined ceiling for this follow-up: at most `1` validator at once.
  - Reason: overlapping validators would pollute latency measurements and undermine cold-versus-warm timing comparisons.

## Flow Validator Guidance: thread-detail-performance

- Restart the shared bridge before collecting cold-start timing evidence for a new implementation round.
- Capture timings for detail-first then timeline, followed by an immediate repeated pair on unchanged data.
- If another thread is used to test interleaving, revisit the canonical target thread immediately afterward to prove the warm fast path survives the interleaved read.
