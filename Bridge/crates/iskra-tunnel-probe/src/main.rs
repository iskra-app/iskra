//! `iskra-tunnel-probe [homeserver] [path]`
//!
//! One real HTTPS request through the bridge, made the way the Matrix SDK makes it: reqwest with
//! its own TLS, pointed at an `http://` proxy that is a stream underneath. Prints what came back.
//! If this prints a Matrix version list, the bridge works — and it worked without seeing a byte of
//! what it carried.
//!
//! ```sh
//! BRIDGE_PUBKEY=npub1… RELAY_LIST=wss://relay.snort.social,wss://nostr.wine \
//!   iskra-tunnel-probe matrix-client.matrix.org /_matrix/client/versions
//! ```

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_probe::StreamClient;
use nostr_sdk::prelude::{Keys, PublicKey};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()))
        .init();

    let mut args = std::env::args().skip(1);
    let homeserver = args
        .next()
        .unwrap_or_else(|| "matrix-client.matrix.org".into());
    let path = args
        .next()
        .unwrap_or_else(|| "/_matrix/client/versions".into());

    let bridge =
        std::env::var("BRIDGE_PUBKEY").map_err(|_| anyhow!("BRIDGE_PUBKEY is required"))?;
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

    // A throwaway identity unless one is given: the probe is not a session. A closed bridge needs
    // a key it knows, which is what PROBE_PRIVKEY is for.
    let keys = match std::env::var("PROBE_PRIVKEY") {
        Ok(secret) => Keys::parse(&secret).map_err(|_| anyhow!("PROBE_PRIVKEY is not a key"))?,
        Err(_) => Keys::generate(),
    };
    eprintln!("probe pubkey: {}", keys.public_key());

    let client = Arc::new(StreamClient::connect(keys, bridge, &relays).await?);
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let secret = nostr_sdk::prelude::Keys::generate().public_key().to_hex();
    tokio::spawn(Arc::clone(&client).serve_connect(listener, Some(secret.clone())));

    let http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all(format!(
            "http://iskra:{secret}@127.0.0.1:{port}"
        ))?)
        .timeout(Duration::from_secs(60))
        .build()?;
    let url = format!("https://{homeserver}{path}");

    // `PROBE_REPEAT` exists because the first request is not the interesting one: it pays for
    // the relay connections, the stream's `open` and a TLS handshake through the tunnel, and
    // quoting that number as "the latency of the bridge" would be off by most of itself. Later
    // requests ride the same kept-alive connection, which is what the SDK does.
    let repeat: usize = std::env::var("PROBE_REPEAT")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(1);

    let mut last = None;
    let mut timings = Vec::with_capacity(repeat);
    for attempt in 1..=repeat {
        let started = std::time::Instant::now();
        let response = http.get(&url).send().await?;
        let status = response.status();
        let body = response.bytes().await?;
        let elapsed = started.elapsed();
        timings.push(elapsed);
        eprintln!(
            "#{attempt} HTTP {status} — {} bytes in {elapsed:?}",
            body.len()
        );
        last = Some(body);
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

    if let Some(body) = last {
        println!("{}", String::from_utf8_lossy(&body));
    }
    Ok(())
}
