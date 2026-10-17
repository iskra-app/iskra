//! A whole tunnel in one process: relay, bridge and homeserver, none of them on the network.

// Each test binary uses its own slice of this; what one does not call, another does.
#![allow(dead_code)]

pub mod tls;

use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Duration;

use iskra_bridge::upstream::Upstreams;
use iskra_bridge::{Bridge, Config};
use iskra_tunnel_probe::{StreamClient, TunnelClient};
use nostr_relay_builder::builder::RateLimit;
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use nostr_sdk::prelude::Keys;
use url::Url;
use wiremock::MockServer;

pub struct Harness {
    _relays: Vec<LocalRelay>,
    pub homeserver: MockServer,
    pub bridge: Arc<Bridge>,
    pub bridge_keys: Keys,
    /// The first relay — what most tests need.
    pub relay_url: String,
    /// All of them, for the tests about what several relays do to one message.
    pub relay_urls: Vec<String>,
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
        // worth knowing rather than just raising: it is a plausible setting for a real relay, and
        // at 60 events a minute a tunnel that spends two events per request is capped around 30
        // requests a minute. Here it is scaffolding in the way of measuring the bridge, so it goes
        // up — but on public relays it is a real ceiling, and one more reason the sync aggregator
        // matters more than raw request speed.
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
        let homeserver = MockServer::start().await;
        let bridge_keys = Keys::generate();

        let config = tweak(Config {
            // Listed rather than open, which also means the wiremock server's loopback address is
            // allowed: an operator naming a homeserver has vouched for it, and only an open bridge
            // has to refuse private addresses.
            upstreams: Upstreams::new(
                Some(Url::parse(&homeserver.uri()).expect("homeserver url")),
                None,
            )
            .expect("upstreams"),
            keys: bridge_keys.clone(),
            relays: relay_urls.clone(),
            client_relays: relay_urls.clone(),
            rate_limit_per_min: NonZeroU32::new(120).unwrap(),
            allowed_pubkeys: None,
            max_body_chunk: iskra_tunnel_proto::DEFAULT_MAX_BODY_CHUNK,
            request_timeout: Duration::from_secs(10),
            blind_only: false,
            streams: Default::default(),
        });

        let bridge = Arc::new(Bridge::start(config).await.expect("bridge starts"));
        let serving = Arc::clone(&bridge);
        tokio::spawn(async move {
            let _ = serving.run().await;
        });

        Self {
            _relays: local_relays,
            homeserver,
            bridge,
            bridge_keys,
            relay_url,
            relay_urls,
        }
    }

    pub async fn client(&self) -> TunnelClient {
        self.client_with(Keys::generate()).await
    }

    /// A v2 client — streams, not requests.
    pub async fn stream_client(&self) -> StreamClient {
        StreamClient::connect(Keys::generate(), self.bridge.public_key(), &self.relay_urls)
            .await
            .expect("stream client connects")
    }

    pub async fn client_with(&self, keys: Keys) -> TunnelClient {
        TunnelClient::connect(keys, self.bridge.public_key(), &self.relay_urls)
            .await
            .expect("client connects")
    }
}
