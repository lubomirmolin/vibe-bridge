# Validated Bridge Feedback

Reviewed on 2026-04-09 against the current `crates/bridge-core` code. Source inputs were:

- `crates/bridge-core/sonnet.md`
- `crates/bridge-core/opus.md`
- `crates/bridge-core/gemini.md`

This document keeps only the issues that are confirmed by the current codebase or are clearly defensible as real maintenance debt. A few original claims were overstated or incorrect and are intentionally not carried forward here.

## Validation Summary

- Not all external feedback was valid.
- The old sync/legacy server concern has been resolved: that code was deleted after this review.
- The strongest remaining confirmed problems are predictable pairing/session identifiers, large-file violations, the no-op config flag (`--admin-port`), and broad code duplication.
- The current async server already uses real timestamps for approval flows (`src/server/state/approvals.rs`).

## Active Async-Server Issues

### P0: Predictable pairing/session/bridge identifiers

Evidence:

- Pairing token uses timestamp + sequence: `src/pairing.rs:69`
- Session token uses timestamp + sequence math: `src/pairing.rs:168`
- Bridge ID uses FNV-style hash of current time + PID: `src/pairing.rs:926`

Why this is valid:

- None of these values are generated with cryptographic randomness.
- These values are part of trust establishment and session continuity, so predictability is a real security weakness.

Fix steps:

1. Replace pairing token generation with CSPRNG-backed random bytes or `Uuid::new_v4()`.
2. Replace session token generation the same way.
3. Generate the initial `bridge_id` randomly once, persist it, and reuse it across restarts.
4. Add tests that assert format and uniqueness, not timestamp-derived structure.

### P0: `--admin-port` is parsed but ignored in the async server

Evidence:

- Parsed in `src/server/config.rs:77`
- Explicitly discarded in `src/server/config.rs:153`

Why this is valid:

- The flag is advertised in help output but has no effect in the active server stack.
- That creates misleading runtime behavior in the only remaining server stack.

Fix steps:

1. Decide whether the async server still needs a separate admin listener.
2. If yes, implement it in `src/server/mod.rs`.
3. If no, remove the flag from parsing and help text in both stacks.
4. Add a config test that prevents future silent no-op flags.

### P1: Plaintext trust/session data is persisted and `SecureStore` is not integrated

Evidence:

- Trust registry persists to `trust-registry.json`: `src/pairing.rs:30`
- Active sessions include `session_token` in serialized state: `src/pairing.rs:843`
- `SecureStore` and `InMemorySecureStore` exist only in `src/secure_storage.rs`, and there are no runtime call sites using `write_secret` / `read_secret` / `remove_secret`

Why this is valid:

- Session tokens are stored on disk in plaintext.
- The secure-store abstraction exists, but it is not part of the active pairing/session flow.

Fix steps:

1. Decide whether bridge trust should remain file-based or move secrets into OS-backed secure storage.
2. At minimum, split public trust metadata from sensitive session secrets.
3. Wire a real `SecureStore` implementation into the active pairing path.
4. Add migration logic for existing `trust-registry.json` files.

### P1: Logging still relies heavily on `eprintln!` instead of a crate-wide logging facade

Evidence:

- `rg -n "eprintln!" crates/bridge-core/src` returns 78 matches.
- Active async paths use `eprintln!`, for example `src/server/mod.rs:38` and `src/server/gateway.rs:640`.

Why this is valid:

- There is no consistent crate-wide `tracing`/`log`-style instrumentation layer.
- Operational logs, warnings, stdout/stderr dumps, and debug output are mixed together.

Fix steps:

1. Introduce `tracing` with structured fields and log levels.
2. Replace direct `eprintln!` calls in async-server code first.
3. Reserve raw stderr writes for process-level fatal startup failures only.
4. Add spans around pairing, turn lifecycle, gateway provider calls, and desktop IPC.

### P1: Large files violate the repository's own size limits

Evidence:

- `src/server/gateway.rs`: 4169 lines
- `src/server/api.rs`: 2935 lines
- `src/thread_api/archive.rs`: 2573 lines
- `src/server/gateway/legacy_archive/archive.rs`: 2570 lines
- `src/server/projection.rs`: 1588 lines

Why this is valid:

- `AGENTS.md` sets `1500` lines as the hard limit.
- The largest files are also the most complex and cross-cutting parts of the bridge.

Fix steps:

1. Split `src/server/gateway.rs` by provider/domain boundaries first.
2. Split `src/server/api.rs` by route group.
3. Split `src/thread_api/archive.rs` and `src/server/gateway/legacy_archive/archive.rs` along archive-loading vs mapping boundaries.
4. Add a simple CI guard for file-size limits.

### P1: Duplication hotspots are real and currently active

Evidence:

- Thread identity helpers duplicated in `src/thread_api.rs:46` and `src/thread_identity.rs:3`
- Git diff resolution/parsing duplicated in `src/thread_api/service.rs:1100` and `src/server/state/git_diff.rs:31`

Why this is valid:

- These are near-copy implementations of core behavior.
- Duplicate logic increases drift risk and slows fixes.

Fix steps:

1. Keep thread identity helpers in one module only and re-export if needed.
2. Move git diff parsing/resolution into a shared module used by both thread/archive and server state code.
3. Review `server/gateway/legacy_archive/*` naming and ownership because it now represents archive compatibility logic, not a second server stack.
4. Add focused tests around the shared implementations before deleting copies.

### P2: Error handling is still stringly typed across much of the crate

Evidence:

- `rg -n "Result<[^>]+, String>" crates/bridge-core/src` returns 239 matches.
- Pairing already demonstrates a better pattern with typed errors in `src/pairing.rs`.

Why this is valid:

- String errors are easy to start with but weak for matching, mapping, and API-level reporting.
- The crate already has examples of better typed errors, so the gap is real rather than theoretical.

Fix steps:

1. Introduce crate-level typed error enums by subsystem.
2. Convert API/gateway/config/pairing boundaries first.
3. Keep `String` only at the final presentation boundary if necessary.
4. Add `From` conversions where that meaningfully reduces boilerplate.

### P2: Small but real correctness/robustness issues remain

Evidence:

- Desktop IPC request loop waits forever on repeated timeouts: `src/codex_ipc.rs:228`
- `u64` timestamps are cast to `i64` without bounds checking: `src/codex_ipc.rs:755`
- Live handlers still use `expect` for serialization in the async API: `src/server/api.rs:831`, `src/server/api.rs:857`, `src/server/api.rs:1067`, `src/server/api.rs:1099`

Why this is valid:

- These are not purely stylistic.
- The IPC loop can stall indefinitely, the cast can mis-handle extreme values, and `expect` in handlers can still panic the server.

Fix steps:

1. Add bounded retry/backoff or deadline behavior to desktop IPC request waiting.
2. Replace the lossy cast with `i64::try_from`.
3. Replace handler `expect` calls with proper error responses.
4. Add targeted regression tests around those failure cases.

### P3: Public API documentation is effectively absent

Evidence:

- `rg -n "^\s*///" crates/bridge-core/src | wc -l` returns `0`

Why this is valid:

- The crate exposes important entrypoints and domain types with no doc comments.
- Onboarding and architectural review both require reading implementation details directly.

Fix steps:

1. Add doc comments to public entrypoints and central DTOs first.
2. Document bridge responsibilities, provider routing, and pairing invariants.
3. Add module-level docs where a subsystem spans many files.

## Resolved Since Review

### Legacy server stack removed

Status:

- Resolved after the original review.

What changed:

- The old sync server implementation was deleted.
- `src/lib.rs` is now only the async-server crate surface.
- The only remaining runtime entrypoint is `src/bin/bridge_server.rs` -> `src/server/mod.rs`.

Impact:

- The prior concern about “two live server stacks” is no longer active.
- Legacy-only findings tied to deleted `src/lib.rs` server code are no longer open work.

## Deferred Architectural Concern

### P3: `BridgeAppStateInner` is still a broad coordination object

Evidence:

- `src/server/state.rs:98`

Why this is only a lower-priority carry-forward:

- The concern is directionally fair: the state object still centralizes many domains.
- I did not validate a concrete deadlock or await-while-holding-`std::sync::Mutex` bug from this alone.

Fix steps:

1. Keep extracting per-domain behavior into `server/state/*` modules.
2. Reduce the number of unrelated responsibilities owned by the root state object.
3. Revisit lock ownership after the larger duplication cleanup is done.

## Suggested Fix Order

1. Replace predictable pairing/session/bridge identifiers with cryptographically random values.
2. Resolve the `--admin-port` no-op and decide the real config surface.
3. Move secrets out of plaintext trust state and wire in a real secure store.
4. Introduce crate-wide structured logging.
5. Split oversized files while collapsing duplicated helpers/modules.
6. Tighten IPC retry/cast/panic edges.
7. Add typed errors and minimal public docs.
