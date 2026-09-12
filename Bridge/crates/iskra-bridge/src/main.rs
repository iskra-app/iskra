use anyhow::Result;
use iskra_bridge::{Bridge, Config};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let config = Config::from_env()?;
    let bridge = Bridge::start(config).await?;

    tokio::select! {
        result = bridge.run() => result?,
        _ = tokio::signal::ctrl_c() => tracing::info!("stopping"),
    }

    bridge.shutdown().await;
    Ok(())
}
