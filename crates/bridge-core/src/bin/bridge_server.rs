fn main() -> Result<(), String> {
    // The bridge has previously aborted with a Tokio worker stack overflow on
    // production traffic. Build the runtime explicitly so workers have a
    // larger stack budget than Tokio's default.
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("bridge-tokio-worker")
        .thread_stack_size(8 * 1024 * 1024)
        .build()
        .map_err(|error| format!("failed to build tokio runtime: {error}"))?
        .block_on(bridge_core::server::run_from_env())
}
