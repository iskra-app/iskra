//! `iskra-tunnel-probe GET /_matrix/client/versions`
//!
//! Prints what came back through the tunnel, and nothing about how. If this prints a Matrix
//! version list, the bridge works.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_probe::TunnelClient;
use nostr_sdk::prelude::{Keys, PublicKey};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()))
        .init();

    let mut args = std::env::args().skip(1);
    let method = args.next().unwrap_or_else(|| "GET".into());
    let path = args
        .next()
        .unwrap_or_else(|| "/_matrix/client/versions".into());

    let bridge = std::env::var("BRIDGE_PUBKEY")
        .map_err(|_| anyhow!("BRIDGE_PUBKEY is required"))?;
    let bridge = PublicKey::parse(&bridge).map_err(|_| anyhow!("BRIDGE_PUBKEY is not a key"))?;

    let relays: Vec<String> = std::env::var("RELAY_LIST")
        .map_err(|_| anyhow!("RELAY_LIST is required"))?
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    if relays.is_empty() {
        return Err(anyhow!("RELAY_LIST is empty"));
    }

    // A throwaway identity unless one is given: the probe is not a session.
    let keys = match std::env::var("PROBE_PRIVKEY") {
        Ok(secret) => Keys::parse(&secret).map_err(|_| anyhow!("PROBE_PRIVKEY is not a key"))?,
        Err(_) => Keys::generate(),
    };
    eprintln!("probe pubkey: {}", keys.public_key());

    let client = TunnelClient::connect(keys, bridge, &relays).await?;
    let response = client
        .request(
            &method,
            &path,
            BTreeMap::new(),
            Vec::new(),
            Duration::from_secs(30),
        )
        .await?;
    client.shutdown().await;

    eprintln!("HTTP {}", response.status);
    println!("{}", String::from_utf8_lossy(&response.body));
    Ok(())
}
