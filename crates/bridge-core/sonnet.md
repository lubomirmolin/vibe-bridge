Overall Verdict: Functional but Structurally Concerning

The code works and has some genuinely good patterns, but it carries serious structural debt. Here's the breakdown:

Critical Issues

1. Two Live Server Stacks

The biggest problem. src/lib.rs (~3,833 lines) is a complete sync TCP/tungstenite server. server/ is a complete async axum server. The production binary uses the axum stack, but the legacy stack is still compiled, still has pub fn run_from_env(), and still has tests. Every security fix must be applied to both or it's incomplete.

2. Hardcoded Fake Timestamps in Production

lib.rs:901 and thread_api/service.rs:1064 both generate timestamps like:

format!("2026-03-17T23:{minute:02}:{second:02}Z")
These are not test utilities — they run on real request paths for approval records and mutation events. Real wall-clock helpers exist (current_timestamp_string() in timeline.rs) but aren't used here.

3. Weak Cryptographic Token Generation

Pairing tokens, session tokens, and bridge IDs are generated from hex-encoded epoch timestamps + monotonic counters / FNV-1a over timestamp+PID. All predictable. The uuid crate is already in Cargo.toml and unused for this purpose.

4. File Size Violations (Your Own Rules)

AGENTS.md sets a 1,500-line hard limit. Several files blow past it severely:

File	Lines	Violation
server/gateway.rs	4,169	2.8×
src/lib.rs	3,833	2.6×
server/api.rs	2,935	2.0×
thread_api/archive.rs	2,573	1.7×
High Issues

Debug eprintln! on every HTTP request — lib.rs:1249, unconditional, no level flag
No structured logging — 69 eprintln! calls in production code, no tracing/log integration
send_request infinite loop — codex_ipc.rs:228, spins forever on IPC timeout with no backoff or max retries
route_thread_request is 450+ lines — single function mixing routing, parsing, policy, business logic, and serialization
Medium Issues

Duplicate CLI arg parser in lib.rs and server/config.rs (~150 lines each)
Duplicate git diff logic in service.rs and server/state/git_diff.rs
20+ bare .unwrap() in server/api.rs production handlers
u64 as i64 silent truncation in codex_ipc.rs:757
Session tokens stored plaintext in trust-registry.json on disk; InMemorySecureStore exists but is unused
--admin-port is parsed then immediately let _ = admin_port discarded (config.rs:153)
What's Done Well

Result<T, String> with descriptive messages throughout
expect() with invariant documentation over unwrap() on mutex locks
Dependency injection via closures for testability (health_with<F>, etc.)
CodexJsonTransport correctly buffers interleaved notifications during request/response cycles
policy.rs is pure, side-effect-free, and fully tested
StreamRouter avoids long lock holds during publish
incremental_text.rs handles UTF-8 boundaries correctly
shared-contracts is clean and minimal
Priority Fix Order

Priority	Action
P0	Gate or delete the legacy lib.rs server
P0	Replace hardcoded date strings with chrono::Utc::now()
P0	Remove the debug eprintln! at lib.rs:1249
P1	Use uuid::Uuid::new_v4() for pairing/session tokens
P1	Add timeout/retry cap to send_request in codex_ipc.rs
P1	Add tracing and remove eprintln! from production paths
P1	Split gateway.rs, lib.rs, api.rs along responsibility boundaries
P2	Deduplicate CLI parser and git diff logic
P2	Fix u64 as i64 cast
P3	Encrypt session tokens at rest, add doc comments, fix .gitignore
The bones are solid — the architectural concepts (policy engine, stream router, dependency-injected testability) are well thought out. The debt is primarily accumulated from an incomplete migration off the legacy stack and insufficient attention to file size discipline.
