//! The client side of the tunnel, in as little code as it can be written.
//!
//! This exists so the bridge can be proven end to end before a line of Swift is written, and so
//! the integration and stress suites have a real client rather than a mock of one. When the iOS
//! transport is built it does what happens here, with a keypair from the Keychain instead of a
//! generated one — including the dispatch loop below, which is not an optimisation but the only
//! shape that survives more than one request in flight.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_proto::{open, seal, HttpRequest, HttpResponse, KIND_REQUEST, KIND_RESPONSE};
use nostr_sdk::prelude::*;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<HttpResponse>>>>;

pub struct TunnelClient {
    keys: Keys,
    bridge: PublicKey,
    client: Client,
    pending: Pending,
    dispatch: JoinHandle<()>,
}

impl TunnelClient {
    /// Connect, subscribe once, and start one dispatch task for the life of the connection.
    ///
    /// One subscription, not one per request: a subscription per request leaves the Nth call with
    /// N live subscriptions on every relay, each delivering its own copy of every answer, and
    /// relays are entitled to start refusing them.
    ///
    /// One reader, not one per request, for a sharper reason. Notifications arrive on a bounded
    /// broadcast channel. Give every in-flight request its own receiver and each one sees *every*
    /// other request's traffic, so the work is quadratic in requests in flight and the channel
    /// overflows under load — at which point a receiver is handed `Lagged`, and an answer that did
    /// arrive is never matched to the request waiting for it. Here one reader drains the stream and
    /// hands each response to the one caller waiting on its id.
    pub async fn connect(keys: Keys, bridge: PublicKey, relays: &[String]) -> Result<Self> {
        let client = Client::new(keys.clone());
        for relay in relays {
            client.add_relay(relay).await?;
        }
        client.connect().await;

        let notifications = client.notifications();

        let filter = Filter::new()
            .kind(Kind::Custom(KIND_RESPONSE))
            .author(bridge)
            .pubkey(keys.public_key())
            .since(Timestamp::now());
        client.subscribe(filter, None).await?;

        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let dispatch = tokio::spawn(dispatch(
            notifications,
            keys.secret_key().clone(),
            bridge,
            Arc::clone(&pending),
        ));

        Ok(Self {
            keys,
            bridge,
            client,
            pending,
            dispatch,
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.keys.public_key()
    }

    /// Send one request through the tunnel and wait for its answer.
    ///
    /// - `upstream` names the homeserver it is for, as an origin. `None` leaves the choice to the
    ///   bridge's configured default, which is all a bridge fronting one homeserver ever needed.
    pub async fn request(
        &self,
        method: &str,
        path: &str,
        upstream: Option<&str>,
        headers: BTreeMap<String, String>,
        body: Vec<u8>,
        timeout: Duration,
    ) -> Result<HttpResponse> {
        let mut request = HttpRequest::new(method, path);
        request.upstream = upstream.map(str::to_string);
        request.headers = headers;
        request.body = body;
        let id = request.id.clone();

        // Registered before publishing. The other order is a race the bridge wins often enough on
        // a fast relay to make the bug look intermittent.
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .expect("pending map")
            .insert(id.clone(), tx);

        let envelope = request.into_single_envelope();
        let content = seal(self.keys.secret_key(), &self.bridge, &envelope)?;
        let event = EventBuilder::new(Kind::Custom(KIND_REQUEST), content)
            .tag(Tag::public_key(self.bridge))
            .sign_with_keys(&self.keys)?;

        if let Err(error) = self.client.send_event(&event).await {
            self.pending.lock().expect("pending map").remove(&id);
            return Err(error.into());
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(_)) => Err(anyhow!("the relay connection closed before an answer arrived")),
            Err(_) => {
                self.pending.lock().expect("pending map").remove(&id);
                Err(anyhow!("no answer within {timeout:?}"))
            }
        }
    }

    pub async fn shutdown(&self) {
        self.dispatch.abort();
        self.client.disconnect().await;
    }
}

impl Drop for TunnelClient {
    fn drop(&mut self) {
        self.dispatch.abort();
    }
}

async fn dispatch(
    mut notifications: tokio::sync::broadcast::Receiver<RelayPoolNotification>,
    secret: SecretKey,
    bridge: PublicKey,
    pending: Pending,
) {
    loop {
        let notification = match notifications.recv().await {
            Ok(notification) => notification,
            // Falling behind costs us the answers that overflowed, and those callers time out. It
            // must not cost us the loop: `while let Ok(..)` would end it here and every later
            // request would time out too, against a connection that is still perfectly alive.
            Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                tracing::warn!(missed, "fell behind the relay stream");
                continue;
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        };

        let RelayPoolNotification::Event { event, .. } = notification else {
            continue;
        };
        if event.kind != Kind::Custom(KIND_RESPONSE) || event.pubkey != bridge {
            continue;
        }
        let Ok(reply) = open(&secret, &bridge, &event.content) else {
            continue;
        };
        let Ok(body) = reply.body() else {
            continue;
        };
        let Ok(response) = HttpResponse::from_head(&reply, body) else {
            continue;
        };

        // Relays fan out, so the same answer arrives once per relay. Removing the waiter makes the
        // duplicates harmless: the second copy finds nothing and is dropped.
        let waiting = pending.lock().expect("pending map").remove(&response.id);
        if let Some(tx) = waiting {
            let _ = tx.send(response);
        }
    }
}
