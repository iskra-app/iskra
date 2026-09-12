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

    // Which homeserver to ask for. Optional: a bridge with a default serves a probe that names
    // nothing, which is how this was used before one bridge could front several homeservers.
    let upstream = std::env::var("PROBE_UPSTREAM").ok().filter(|s| !s.trim().is_empty());

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

    // `PROBE_REPEAT` exists because the first request is not the interesting one: it pays for
    // process start, three TLS handshakes and the websocket upgrades, and quoting that number as
    // "the latency of the tunnel" would be off by most of itself. What matters is the steady-state
    // round trip on a connection that is already open.
    let repeat: usize = std::env::var("PROBE_REPEAT")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(1);

    let mut last = None;
    let mut timings = Vec::with_capacity(repeat);
    for attempt in 1..=repeat {
        let started = std::time::Instant::now();
        let response = client
            .request(
                &method,
                &path,
                upstream.as_deref(),
                BTreeMap::new(),
                Vec::new(),
                Duration::from_secs(30),
            )
            .await?;
        let elapsed = started.elapsed();
        timings.push(elapsed);
        eprintln!(
            "#{attempt} HTTP {} — {} bytes in {:?}",
            response.status,
            response.body.len(),
            elapsed
        );
        last = Some(response);
    }
    client.shutdown().await;

    if timings.len() > 1 {
        timings.sort();
        let total: Duration = timings.iter().sum();
        eprintln!(
            "min {:?} · median {:?} · max {:?} · mean {:?}",
            timings[0],
            timings[timings.len() / 2],
            timings[timings.len() - 1],
            total / timings.len() as u32
        );
    }

    if let Some(response) = last {
        println!("{}", String::from_utf8_lossy(&response.body));
    }
    Ok(())
}
