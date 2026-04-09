Here is a breakdown of the core issues and observations:

1. Massive "God" Files
There are several files that are excessively large, which in Rust usually indicates missing module boundaries and tight coupling:

src/lib.rs is roughly 133 KB (approx. 4,000+ lines).
src/server/gateway.rs is roughly 149 KB.
src/server/api.rs is roughly 102 KB.
In idiomatic Rust, libraries are typically broken down into distinct, focused modules. A lib.rs of this size means almost everything is getting dumped into the crate root, making the codebase very difficult to navigate, test, and maintain.

2. The BridgeAppStateInner God Object
Looking at src/server/state.rs, the BridgeAppStateInner struct is acting as a monolithic catch-all for the entire application's state. It currently holds roughly 25 distinct fields managing entirely unrelated domains:

UI State & Threads (interrupted_threads, active_turn_ids, pending_user_inputs)
Git Operations (git_controls)
External Services & Hardware (speech, pairing_sessions, codex_health)
Communications (event_hub, legacy_ipc, gateway)
This tight coupling means that any module needing access to one piece of state receives access to everything, breaking the principle of least privilege and making mocking/testing extremely tedious.

3. Concurrency Footguns & Lock Contention
The state struct utilizes a mix of async locks (tokio::sync::RwLock) and synchronous locks (std::sync::Mutex).

Every individual field is wrapped in its own lock rather than grouping related state or using actors/channels.
Mixing std::sync::Mutex and tokio::sync::RwLock is a frequent source of performance bottlenecks or deadlocks in async Rust. If a std::sync::MutexGuard is accidentally held across an .await boundary anywhere in those massive gateway/api files, the executor will block or panic.
Having 20+ independent locks in a single central struct usually leads to difficult-to-trace deadlocks if two systems try to acquire locks in different orders.
4. Domain Logic Leaking
The system handles extremely granular state structures like inflight_thread_title_generations or awaiting_plan_question_prompts inside the global App State rather than scoped down to a specific "ThreadManager" or "TitleGenerator" service. The global state shouldn't need to know the minutiae of individual string IDs for prompts.

Summary
The code appears to have grown organically and very rapidly. While the logic itself likely works and uses strong typing effectively, it desperately needs an architectural refactor.

To improve the quality, I would highly recommend:

Extracting domains into separate modules/crates (e.g. separating Speech Service, Git Controls, and Thread Management).
Moving away from shared-state concurrency (massive structs of RwLock) toward an Actor model (using tokio::sync::mpsc) where independent services own their state and communicate via message passing.
Splitting up lib.rs and gateway.rs into smaller, focused modules.
