#[tokio::main]
async fn main() -> Result<(), String> {
    bridge_core::rewrite::run_from_env().await
}
