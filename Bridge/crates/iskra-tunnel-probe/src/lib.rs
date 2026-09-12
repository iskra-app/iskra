//! The client side of the tunnel, in as little code as it can be written.
//!
//! This exists so the bridge can be proven end to end before a line of Swift is written, and so
//! the integration test has a real client rather than a mock of one. When the iOS transport is
//! built it does exactly what happens here, with a keypair from the Keychain instead of a
//! generated one.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_proto::{
    open, seal, HttpRequest, HttpResponse, KIND_REQUEST, KIND_RESPONSE,
};
use nostr_sdk::prelude::*;

pub struct TunnelClient {
    keys: Keys,
    bridge: PublicKey,
    client: Client,
}

impl TunnelClient {
    pub async fn connect(keys: Keys, bridge: PublicKey, relays: &[String]) -> Result<Self> {
        let client = Client::new(keys.clone());
        for relay in relays {
            client.add_relay(relay).await?;
        }
        client.connect().await;
        Ok(Self {
            keys,
            bridge,
            client,
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.keys.public_key()
    }

    /// Send one request through the tunnel and wait for its answer.
    ///
    /// The subscription is opened *before* the request goes out. Opening it afterwards is a race
    /// the bridge wins often enough on a fast relay to make the bug look intermittent.
    pub async fn request(
        &self,
        method: &str,
        path: &str,
        headers: BTreeMap<String, String>,
        body: Vec<u8>,
        timeout: Duration,
    ) -> Result<HttpResponse> {
        let mut request = HttpRequest::new(method, path);
        request.headers = headers;
        request.body = body;
        let id = request.id.clone();

        let filter = Filter::new()
            .kind(Kind::Custom(KIND_RESPONSE))
            .author(self.bridge)
            .pubkey(self.public_key())
            .since(Timestamp::now());
        self.client.subscribe(filter, None).await?;
        let mut notifications = self.client.notifications();

        let envelope = request.into_single_envelope();
        let content = seal(self.keys.secret_key(), &self.bridge, &envelope)?;
        let event = EventBuilder::new(Kind::Custom(KIND_REQUEST), content)
            .tag(Tag::public_key(self.bridge))
            .sign_with_keys(&self.keys)?;
        self.client.send_event(&event).await?;

        let wait = async {
            while let Ok(notification) = notifications.recv().await {
                let RelayPoolNotification::Event { event, .. } = notification else {
                    continue;
                };
                if event.kind != Kind::Custom(KIND_RESPONSE) || event.pubkey != self.bridge {
                    continue;
                }
                let Ok(reply) = open(self.keys.secret_key(), &self.bridge, &event.content) else {
                    continue;
                };
                // Relays fan out to everyone; an answer to somebody else's request is not ours.
                if reply.id != id {
                    continue;
                }
                let body = reply.body()?;
                return HttpResponse::from_head(&reply, body).map_err(anyhow::Error::from);
            }
            Err(anyhow!("the relay connection closed before an answer arrived"))
        };

        tokio::time::timeout(timeout, wait)
            .await
            .map_err(|_| anyhow!("no answer within {timeout:?}"))?
    }

    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }
}
