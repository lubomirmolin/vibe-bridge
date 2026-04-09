#[tokio::main]
async fn main() -> Result<(), String> {
    bridge_core::server::run_from_env().await
}
