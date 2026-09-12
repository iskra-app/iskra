//! The nostr half: events in, events out.

use std::sync::Arc;

use anyhow::Result;
use iskra_tunnel_proto::{
    log_path, open, seal, HttpRequest, HttpResponse, KIND_REQUEST, KIND_RESPONSE,
};
use nostr_sdk::prelude::*;
use tokio::sync::{broadcast, Mutex};

use crate::config::Config;
use crate::forwarder::Forwarder;
use crate::ratelimit::RateLimit;

pub struct Bridge {
    config: Arc<Config>,
    forwarder: Arc<Forwarder>,
    limit: Arc<RateLimit>,
    client: Client,
    /// Taken by `run`. Held here because the order of the two lines that create it matters —
    /// see `start`.
    notifications: Mutex<Option<broadcast::Receiver<RelayPoolNotification>>>,
}

impl Bridge {
    /// Connect to every relay **and subscribe**, before returning.
    ///
    /// Subscribing belongs to startup rather than to `run`, and the reason is that tunnel events
    /// are ephemeral: a relay does not store them, so a request that arrives in the window between
    /// "the bridge is up" and "the bridge has subscribed" is gone for good, and the client sits out
    /// its timeout for a bridge that was running the whole time. Once `start` returns, anything
    /// addressed to this key will be heard.
    ///
    /// The notification receiver is taken *before* subscribing for the same reason one step down:
    /// it is a broadcast channel, and a receiver created afterwards starts at the current position,
    /// missing whatever landed in between.
    ///
    /// Connecting is not the same as being *reachable*. nostr-sdk retries in the background, so
    /// `Ok` here means the relays were accepted, not that any of them answered.
    pub async fn start(config: Config) -> Result<Self> {
        let forwarder = Forwarder::new(config.homeserver.clone(), config.request_timeout)?;
        let limit = RateLimit::per_minute(config.rate_limit_per_min);
        let client = Client::new(config.keys.clone());

        for relay in &config.relays {
            client.add_relay(relay).await?;
        }
        client.connect().await;

        let notifications = client.notifications();

        let filter = Filter::new()
            .kind(Kind::Custom(KIND_REQUEST))
            .pubkey(config.keys.public_key())
            // Relays are not supposed to store ephemeral events, but one that does would otherwise
            // replay its whole backlog here and the bridge would re-issue requests answered days
            // ago.
            .since(Timestamp::now());
        client.subscribe(filter, None).await?;

        tracing::info!(
            pubkey = %config.keys.public_key(),
            relays = config.relays.len(),
            "bridge is listening"
        );

        Ok(Self {
            config: Arc::new(config),
            forwarder: Arc::new(forwarder),
            limit: Arc::new(limit),
            client,
            notifications: Mutex::new(Some(notifications)),
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.config.keys.public_key()
    }

    /// Serve until the relay connections close or the process is told to stop.
    pub async fn run(&self) -> Result<()> {
        let mut notifications = self
            .notifications
            .lock()
            .await
            .take()
            .ok_or_else(|| anyhow::anyhow!("run was called twice"))?;

        while let Ok(notification) = notifications.recv().await {
            let RelayPoolNotification::Event { event, .. } = notification else {
                continue;
            };
            if event.kind != Kind::Custom(KIND_REQUEST) {
                continue;
            }

            let config = Arc::clone(&self.config);
            let forwarder = Arc::clone(&self.forwarder);
            let limit = Arc::clone(&self.limit);
            let client = self.client.clone();

            // One task per request: a homeserver that takes thirty seconds to answer one call must
            // not stop the bridge from hearing the next.
            tokio::spawn(async move {
                if let Err(error) = serve(&config, &forwarder, &limit, &client, &event).await {
                    tracing::warn!(client = %event.pubkey, %error, "request failed");
                }
            });
        }

        Ok(())
    }

    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }
}

async fn serve(
    config: &Config,
    forwarder: &Forwarder,
    limit: &RateLimit,
    client: &Client,
    event: &Event,
) -> Result<()> {
    let sender = event.pubkey;

    if !config.allows(&sender) {
        tracing::debug!(client = %sender, "not on the allow list");
        return Ok(());
    }
    if !limit.allow(&sender) {
        tracing::info!(client = %sender, "rate limited");
        return Ok(());
    }

    let secret = config.keys.secret_key();
    let envelope = match open(secret, &sender, &event.content) {
        Ok(envelope) => envelope,
        Err(error) => {
            // Anyone may tag an event at the bridge's public key. Undecryptable is ordinary.
            tracing::debug!(client = %sender, %error, "dropped an unreadable event");
            return Ok(());
        }
    };

    // Stage 1 carries one chunk. Chunked requests arrive in stage 2; until then a multi-chunk
    // request is refused rather than half-served.
    if envelope.total != 1 {
        tracing::warn!(client = %sender, "chunked requests are not supported yet");
        return Ok(());
    }

    let body = envelope.body()?;
    let request = HttpRequest::from_head(&envelope, body)?;
    let request_id = request.id.clone();
    let method = request.method.clone();
    let route = log_path(&request.path);
    let request_bytes = request.body.len();

    let response = match forwarder.forward(request).await {
        Ok(response) => response,
        Err(error) => {
            tracing::warn!(client = %sender, %method, route, %error, "upstream failed");
            // 502 is the honest answer, and it has to reach the client: a silent drop leaves the
            // SDK waiting out its own timeout with nothing to explain it.
            HttpResponse {
                id: request_id,
                status: 502,
                headers: Default::default(),
                body: Vec::new(),
            }
        }
    };

    tracing::info!(
        client = %sender,
        %method,
        route,
        status = response.status,
        request_bytes,
        response_bytes = response.body.len(),
        "served"
    );

    let reply = response.into_single_envelope();
    let content = seal(secret, &sender, &reply)?;
    let out = EventBuilder::new(Kind::Custom(KIND_RESPONSE), content)
        .tag(Tag::public_key(sender))
        .sign_with_keys(&config.keys)?;
    client.send_event(&out).await?;

    Ok(())
}
