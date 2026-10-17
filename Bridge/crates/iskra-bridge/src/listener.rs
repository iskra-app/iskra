//! The nostr half: frames in, frames out.

use std::sync::Arc;

use anyhow::Result;
use iskra_tunnel_proto::{open_frame, KIND_STREAM_CLIENT};
use nostr_sdk::prelude::*;
use tokio::sync::{broadcast, Mutex};

use crate::blind::Destinations;
use crate::config::Config;
use crate::ratelimit::RateLimit;
use crate::stream::Streams;

/// How far an event's `created_at` may be from the bridge's clock. The `since` in the subscription
/// is only a request to the relay; a hostile one ignores it and replays frames recorded days ago.
/// A replayed `open` cannot do much — the TLS inside it is to a server that will not finish a
/// handshake recorded last week — but it would still make the bridge connect somewhere on a
/// stranger's say-so. Within the window, a replay is a duplicate event id, and nostr-sdk drops
/// those.
const MAX_CLOCK_SKEW_SECS: u64 = 120;

/// How often the ceilings forget clients that have gone quiet.
const FORGET_QUIET_CLIENTS: std::time::Duration = std::time::Duration::from_secs(60);

pub struct Bridge {
    config: Arc<Config>,
    /// Events per client key, charged before decrypting, when nothing is known yet about what an
    /// event belongs to.
    events: RateLimit,
    streams: Streams,
    client: Client,
    /// Taken by `run`. Held here because the order of the two lines that create it matters —
    /// see `start`.
    notifications: Mutex<Option<broadcast::Receiver<RelayPoolNotification>>>,
}

impl Bridge {
    /// Connect to every relay **and subscribe**, before returning.
    ///
    /// Subscribing belongs to startup rather than to `run`, and the reason is that tunnel events
    /// are ephemeral: a relay does not store them, so an `open` that arrives in the window between
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
        let client = Client::new(config.keys.clone());
        for relay in &config.relays {
            client.add_relay(relay).await?;
        }
        client.connect().await;

        let notifications = client.notifications();

        let filter = Filter::new()
            .kind(Kind::Custom(KIND_STREAM_CLIENT))
            .pubkey(config.keys.public_key())
            // Relays are not supposed to store ephemeral events, but one that does would otherwise
            // replay its whole backlog here.
            .since(Timestamp::now());
        client.subscribe(filter, None).await?;

        // An open bridge is a decision, and one whose consequences land on the operator's bandwidth
        // and reputation, so it is said out loud at every startup rather than left in a config file
        // somebody set up once.
        if config.upstreams.is_open() {
            tracing::warn!(
                "ALLOWED_UPSTREAMS=* — this bridge will carry streams to any public Matrix server; \
                 set ALLOWED_PUBKEYS or a list of homeservers to narrow it"
            );
        } else {
            tracing::info!(homeservers = ?config.upstreams.listed(), "serving");
        }
        if config.allowed_pubkeys.is_none() {
            tracing::warn!(
                "ALLOWED_PUBKEYS is empty — anyone who knows this bridge's address can use it; \
                 list your devices' keys to close it"
            );
        }

        tracing::info!(
            pubkey = %config.keys.public_key(),
            relays = config.relays.len(),
            "bridge is listening"
        );
        // The line somebody who set the bridge up is actually looking for, in the form the app's
        // "Bridge address" field expects. `pubkey=` above stays hex for whoever already greps it.
        let Ok(npub) = config.keys.public_key().to_bech32();
        tracing::info!("bridge address for Iskra: {npub}");

        let streams = Streams::new(
            config.keys.clone(),
            client.clone(),
            Destinations::new(&config.upstreams),
            config.streams.clone(),
            config.segment_bytes,
            config.pow_bits,
        );

        Ok(Self {
            events: RateLimit::per_minute(config.events_per_min),
            streams,
            config: Arc::new(config),
            client,
            notifications: Mutex::new(Some(notifications)),
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.config.keys.public_key()
    }

    /// Streams open right now. For tests and for whoever is watching the bridge.
    pub fn open_streams(&self) -> usize {
        self.streams.open_count()
    }

    /// Serve until the relay connections close or the process is told to stop.
    pub async fn run(&self) -> Result<()> {
        let mut notifications = self
            .notifications
            .lock()
            .await
            .take()
            .ok_or_else(|| anyhow::anyhow!("run was called twice"))?;

        let mut forget = tokio::time::interval(FORGET_QUIET_CLIENTS);

        loop {
            let received = tokio::select! {
                received = notifications.recv() => received,
                _ = forget.tick() => {
                    self.events.retain_recent();
                    self.streams.tidy();
                    continue;
                }
            };
            let notification = match received {
                Ok(notification) => notification,
                // Lagging is not the end of the bridge, and treating it as one is a trap worth
                // naming: notifications arrive on a bounded broadcast channel, and the obvious
                // `while let Ok(..) = recv().await` exits the loop when the channel overflows. The
                // bridge would then go silent **permanently** after one burst of traffic, while
                // still connected, still subscribed, and still looking healthy in the logs.
                Err(broadcast::error::RecvError::Lagged(missed)) => {
                    tracing::warn!(missed, "fell behind the relay stream; frames were dropped");
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            };
            let RelayPoolNotification::Event { event, .. } = notification else {
                continue;
            };
            if event.kind == Kind::Custom(KIND_STREAM_CLIENT) {
                self.frame(&event);
            }
        }

        Ok(())
    }

    /// One frame: allow list, freshness and the event ceiling, all before decrypting — and then
    /// straight to its stream, in the relay loop and in arrival order. Decrypting one frame is
    /// cheap, and handing frames to tasks of their own would only shuffle an order the receiver
    /// then has to put back.
    fn frame(&self, event: &Event) {
        let sender = event.pubkey;
        if !self.config.allows(&sender) {
            tracing::debug!(client = %sender, "not on the allow list");
            return;
        }
        if !is_fresh(event.created_at, Timestamp::now()) {
            tracing::info!(client = %sender, "dropped a stale or future event");
            return;
        }
        // Before decrypting, so it can only be silent: without the frame there is no stream id to
        // answer on. It is set far above anything honest, so silence here means a flood.
        if !self.events.allow(&sender) {
            tracing::info!(client = %sender, "too many events");
            return;
        }
        match open_frame(self.config.keys.secret_key(), &sender, &event.content) {
            Ok(frame) => self.streams.deliver(sender, frame, proof_of_work(event)),
            // Anyone may tag an event at the bridge's public key. Undecryptable is ordinary.
            Err(error) => tracing::debug!(client = %sender, %error, "dropped an unreadable frame"),
        }
    }

    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }
}

/// The NIP-13 work an event carries: the leading zero bits of its id, but no more than the target
/// its `nonce` tag committed to. The commitment is what keeps a flood of cheap events from being
/// mined to nothing and passing whenever one happens, by luck, to start with zeros.
fn proof_of_work(event: &Event) -> u8 {
    let committed = event
        .tags
        .iter()
        .find_map(|tag| {
            let tag = tag.as_slice();
            (tag.first().map(String::as_str) == Some("nonce"))
                .then(|| tag.get(2).and_then(|bits| bits.parse::<u8>().ok()))
                .flatten()
        })
        .unwrap_or(0);
    let bits = nostr_sdk::nips::nip13::get_leading_zero_bits(event.id.as_bytes());
    bits.min(committed)
}

/// Whether an event was made close enough to now to be a frame somebody is waiting on.
fn is_fresh(created_at: Timestamp, now: Timestamp) -> bool {
    created_at.as_secs().abs_diff(now.as_secs()) <= MAX_CLOCK_SKEW_SECS
}

#[cfg(test)]
mod freshness {
    use super::*;

    #[test]
    fn work_counts_only_up_to_what_the_nonce_committed_to() {
        let keys = Keys::generate();
        let mined = EventBuilder::new(Kind::Custom(KIND_STREAM_CLIENT), "x")
            .pow(8)
            .sign_with_keys(&keys)
            .unwrap();
        assert!(proof_of_work(&mined) >= 8);
        let unmined = EventBuilder::new(Kind::Custom(KIND_STREAM_CLIENT), "x")
            .sign_with_keys(&keys)
            .unwrap();
        assert_eq!(proof_of_work(&unmined), 0, "no nonce, no work, however lucky the id");
    }

    #[test]
    fn an_event_from_just_now_is_fresh_and_a_recording_is_not() {
        let now = Timestamp::from(1_800_000_000);
        assert!(is_fresh(now, now));
        assert!(is_fresh(Timestamp::from(now.as_secs() - 60), now));
        assert!(is_fresh(Timestamp::from(now.as_secs() + 60), now));
        assert!(!is_fresh(Timestamp::from(now.as_secs() - 3600), now));
        assert!(!is_fresh(Timestamp::from(now.as_secs() + 3600), now));
    }
}
