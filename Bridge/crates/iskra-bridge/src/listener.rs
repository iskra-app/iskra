//! The nostr half: events in, events out.

use std::sync::Arc;

use anyhow::Result;
use iskra_tunnel_proto::{
    log_path, open, seal, HttpRequest, HttpResponse, ProtoError, KIND_REQUEST, KIND_RESPONSE,
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
        let forwarder = Forwarder::new(config.request_timeout)?;
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

        // An open bridge is a decision, and one whose consequences land on the operator's bandwidth
        // and reputation, so it is said out loud at every startup rather than left in a config file
        // somebody set up once.
        if config.upstreams.is_open() {
            tracing::warn!(
                "ALLOWED_UPSTREAMS=* — this bridge will carry traffic to any public homeserver; \
                 set ALLOWED_PUBKEYS or a list of homeservers to narrow it"
            );
        } else {
            tracing::info!(homeservers = ?config.upstreams.listed(), "serving");
        }

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

        loop {
            let notification = match notifications.recv().await {
                Ok(notification) => notification,
                // Lagging is not the end of the bridge, and treating it as one is a trap worth
                // naming: notifications arrive on a bounded broadcast channel, and the obvious
                // `while let Ok(..) = recv().await` exits the loop when the channel overflows. The
                // bridge would then go silent **permanently** after one burst of traffic, while
                // still connected, still subscribed, and still looking healthy in the logs. The
                // stress suite found exactly that.
                Err(broadcast::error::RecvError::Lagged(missed)) => {
                    tracing::warn!(missed, "fell behind the relay stream; requests were dropped");
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            };
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

    // Where this one is going, and whether the bridge will take it there. The target comes from
    // the client — one bridge has to serve several homeservers, if only because discovery and the
    // API live at different names on the same account — so it is checked like anything else that
    // arrives from a stranger.
    let upstream = match config
        .upstreams
        .resolve(request.upstream.as_deref(), &request.path)
        .await
    {
        Ok(upstream) => upstream,
        Err(refusal) => {
            // The host is logged because an operator needs to know which homeserver to add; the
            // path is not, for the usual reason — it carries room and event ids.
            tracing::info!(
                client = %sender,
                %method,
                route,
                reason = refusal.as_str(),
                "refused"
            );
            let refusal = HttpResponse {
                id: request_id,
                status: 403,
                headers: Default::default(),
                body: Vec::new(),
            }
            .into_single_envelope();
            let content = seal(secret, &sender, &refusal)?;
            return publish(config, client, &sender, content).await;
        }
    };
    let host = upstream.host_str().unwrap_or("?").to_string();

    let response = match forwarder.forward(request, &upstream).await {
        Ok(response) => response,
        Err(error) => {
            tracing::warn!(client = %sender, %method, host, route, %error, "upstream failed");
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
        host,
        route,
        status = response.status,
        request_bytes,
        response_bytes = response.body.len(),
        "served"
    );

    let reply = response.into_single_envelope();
    let content = match seal(secret, &sender, &reply) {
        Ok(content) => content,
        // Too big for one NIP-44 payload. Until chunking lands the honest answer is a 502: the
        // alternative is returning an error here and sending nothing, and silence is the one thing
        // the bridge may never do — the client would sit out its own timeout with no way to tell a
        // huge response from a dead bridge.
        Err(ProtoError::TooLarge(bytes)) => {
            tracing::warn!(
                client = %sender,
                %method,
                route,
                bytes,
                "response does not fit one envelope; answering 502 until chunking lands"
            );
            let refusal = HttpResponse {
                id: reply.id.clone(),
                status: 502,
                headers: Default::default(),
                body: Vec::new(),
            }
            .into_single_envelope();
            seal(secret, &sender, &refusal)?
        }
        Err(error) => return Err(error.into()),
    };
    publish(config, client, &sender, content).await
}

/// Send one sealed reply back to the client that asked.
///
/// Extracted because a refusal is as owed an answer as a success is: silence would leave the SDK
/// waiting out its own timeout with no way to tell "this bridge will not serve that homeserver"
/// from "this bridge is dead".
async fn publish(
    config: &Config,
    client: &Client,
    to: &PublicKey,
    content: String,
) -> Result<()> {
    let out = EventBuilder::new(Kind::Custom(KIND_RESPONSE), content)
        .tag(Tag::public_key(*to))
        .sign_with_keys(&config.keys)?;
    client.send_event(&out).await?;
    Ok(())
}
