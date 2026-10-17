//! A whole tunnel in one process: relays, bridge and a homeserver with real TLS, none of them on
//! the network.

// Each test binary uses its own slice of this; what one does not call, another does.
#![allow(dead_code)]

pub mod tls;

use std::collections::BTreeSet;
use std::num::NonZeroU32;
use std::sync::Arc;

use iskra_bridge::config::StreamLimits;
use iskra_bridge::upstream::{parse_origin, Allowed, Upstreams};
use iskra_bridge::{Bridge, Config};
use iskra_tunnel_probe::StreamClient;
use nostr_relay_builder::builder::RateLimit;
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use nostr_sdk::prelude::Keys;

use tls::TlsServer;

pub struct Harness {
    _relays: Vec<LocalRelay>,
    /// The homeserver, listed in `ALLOWED_UPSTREAMS` as `https://localhost:<port>`.
    pub server: TlsServer,
    pub bridge: Arc<Bridge>,
    pub bridge_keys: Keys,
    /// The first relay — what most tests need.
    pub relay_url: String,
    /// All of them, for the tests about what several relays do to one stream.
    pub relay_urls: Vec<String>,
}

/// `ALLOWED_UPSTREAMS` with these origins.
pub fn listed(origins: &[String]) -> Upstreams {
    let set: BTreeSet<String> = origins.iter().map(|o| parse_origin(o).unwrap()).collect();
    Upstreams::new(Allowed::These(set)).unwrap()
}

impl Harness {
    pub async fn start() -> Self {
        Self::start_with(|config| config).await
    }

    pub async fn start_with(tweak: impl FnOnce(Config) -> Config) -> Self {
        Self::start_on(1, tweak).await
    }

    /// Several relays, bridge and client both on all of them — which is how it runs in life, and
    /// the only way to see what happens when every relay delivers its own copy of an event.
    pub async fn start_on(relays: usize, tweak: impl FnOnce(Config) -> Config) -> Self {
        // `RelayBuilder::default()` caps a connection at 60 events a minute, and that default is
        // worth knowing rather than just raising: it is a plausible setting for a real relay, and a
        // stream spends an event per 24 KiB segment. Here it is scaffolding in the way of measuring
        // the bridge, so it goes up — but on public relays it is a real ceiling.
        let mut local_relays = Vec::new();
        let mut relay_urls = Vec::new();
        for _ in 0..relays.max(1) {
            let relay = LocalRelay::new(RelayBuilder::default().rate_limit(RateLimit {
                max_reqs: 100_000,
                notes_per_minute: 10_000_000,
            }));
            relay.run().await.expect("relay");
            relay_urls.push(relay.url().await.to_string());
            local_relays.push(relay);
        }
        let relay_url = relay_urls[0].clone();
        let server = TlsServer::start().await;
        let bridge_keys = Keys::generate();

        let config = tweak(Config {
            // Listed rather than open, which also means the server's loopback address is allowed:
            // an operator naming a homeserver has vouched for it, and only an open bridge has to
            // refuse private addresses.
            upstreams: listed(&[format!("https://localhost:{}", server.port)]),
            keys: bridge_keys.clone(),
            relays: relay_urls.clone(),
            client_relays: relay_urls.clone(),
            events_per_min: NonZeroU32::new(1_000_000).unwrap(),
            allowed_pubkeys: None,
            segment_bytes: iskra_tunnel_proto::DEFAULT_SEGMENT,
            streams: StreamLimits::default(),
        });

        let bridge = Arc::new(Bridge::start(config).await.expect("bridge starts"));
        let serving = Arc::clone(&bridge);
        tokio::spawn(async move {
            let _ = serving.run().await;
        });

        Self {
            _relays: local_relays,
            server,
            bridge,
            bridge_keys,
            relay_url,
            relay_urls,
        }
    }

    pub async fn stream_client(&self) -> StreamClient {
        self.stream_client_with(Keys::generate()).await
    }

    pub async fn stream_client_with(&self, keys: Keys) -> StreamClient {
        StreamClient::connect(keys, self.bridge.public_key(), &self.relay_urls)
            .await
            .expect("stream client connects")
    }
}
