//! The nostr half: events in, events out.

use std::num::NonZeroU32;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;

use anyhow::Result;
use iskra_tunnel_proto::{
    log_path, open, seal, Accepted, HttpRequest, HttpResponse, Limits, ProtoError, Reassembler,
    KIND_REQUEST, KIND_RESPONSE,
};
use nostr_sdk::prelude::*;
use tokio::sync::{broadcast, Mutex, Semaphore};
use tokio::task::JoinSet;

/// Half-arrived requests, keyed by who is sending and which message it is.
///
/// Keyed by **both**, because the message id is chosen by the client: two clients that happen to
/// pick the same one would otherwise be assembled into each other's requests. A `std` mutex and
/// not tokio's — accepting a chunk is a memcpy and a hash lookup, and the guard is dropped before
/// anything is awaited.
type Partials = Arc<StdMutex<Reassembler<(PublicKey, String)>>>;

use crate::config::Config;
use crate::forwarder::Forwarder;
use crate::ratelimit::RateLimit;

/// How many events one request may spend before the *event* ceiling notices. A request is almost
/// always one event; an upload at the 8 MB reassembly ceiling is about 340. Sixty-four per request
/// per minute leaves every honest upload well clear and still bounds the decrypting a stranger can
/// make the bridge do. See `ratelimit` for why there are two ceilings at all.
const EVENTS_PER_REQUEST: u32 = 64;

/// Requests being served at once, across every client. The per-key ceilings do not bound this on
/// an open bridge — nostr keys cost nothing, so a flood can come from a fresh key per event — and
/// every one of these may hold an upstream connection and up to 8 MB for the whole timeout.
const MAX_CONCURRENT: usize = 256;

/// Half-arrived messages one client may have at once. `Limits::max_in_flight` is shared by
/// everybody, and without this one sender opening 64 messages and never finishing them locked
/// every other client's uploads out for as long as it kept doing so.
const MAX_IN_FLIGHT_PER_CLIENT: usize = 8;

/// How far an event's `created_at` may be from the bridge's clock. The `since` in the subscription
/// is only a request to the relay; a hostile one ignores it and replays a request recorded days
/// ago — a `/leave`, a `/logout` — with the victim's token still in it. Within the window, a
/// replay is a duplicate event id, and nostr-sdk drops those.
const MAX_CLOCK_SKEW_SECS: u64 = 120;

/// How often the rate limiters forget clients that have gone quiet.
const FORGET_QUIET_CLIENTS: std::time::Duration = std::time::Duration::from_secs(60);

/// The two ceilings, per client key.
struct Ceilings {
    /// `RATE_LIMIT_PER_MIN` — requests, charged once each, on whichever chunk arrives first.
    requests: RateLimit,
    /// Events, charged before decrypting, when nothing is known yet about what they belong to.
    events: RateLimit,
}

pub struct Bridge {
    config: Arc<Config>,
    forwarder: Arc<Forwarder>,
    ceilings: Arc<Ceilings>,
    partials: Partials,
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
        let ceilings = Ceilings {
            requests: RateLimit::per_minute(config.rate_limit_per_min),
            events: RateLimit::per_minute(config.rate_limit_per_min.saturating_mul(
                NonZeroU32::new(EVENTS_PER_REQUEST).expect("a non-zero constant"),
            )),
        };
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

        Ok(Self {
            config: Arc::new(config),
            forwarder: Arc::new(forwarder),
            ceilings: Arc::new(ceilings),
            partials: Arc::new(StdMutex::new(Reassembler::new(Limits::default()))),
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

        let serving = Arc::new(Semaphore::new(MAX_CONCURRENT));
        let mut forget = tokio::time::interval(FORGET_QUIET_CLIENTS);

        loop {
            let received = tokio::select! {
                received = notifications.recv() => received,
                _ = forget.tick() => {
                    self.ceilings.requests.retain_recent();
                    self.ceilings.events.retain_recent();
                    continue;
                }
            };
            let notification = match received {
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
            // Dropped rather than answered: answering a flood would be publishing on its behalf.
            let Ok(permit) = Arc::clone(&serving).try_acquire_owned() else {
                tracing::warn!("too many requests in flight; dropped one");
                continue;
            };

            let config = Arc::clone(&self.config);
            let forwarder = Arc::clone(&self.forwarder);
            let ceilings = Arc::clone(&self.ceilings);
            let partials = Arc::clone(&self.partials);
            let client = self.client.clone();

            // One task per request: a homeserver that takes thirty seconds to answer one call must
            // not stop the bridge from hearing the next.
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = serve(&config, &forwarder, &ceilings, &partials, &client, &event).await {
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
    ceilings: &Ceilings,
    partials: &Partials,
    client: &Client,
    event: &Event,
) -> Result<()> {
    let sender = event.pubkey;

    if !config.allows(&sender) {
        tracing::debug!(client = %sender, "not on the allow list");
        return Ok(());
    }
    if !is_fresh(event.created_at, Timestamp::now()) {
        tracing::info!(client = %sender, "dropped a stale or future event");
        return Ok(());
    }
    // Before decrypting, so it can only be silent: without the envelope there is no request id to
    // answer on. It is set far above anything honest, so silence here means a flood.
    if !ceilings.events.allow(&sender) {
        tracing::info!(client = %sender, "too many events");
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

    // A request may arrive in pieces, from several relays, in any order. Everything up to here
    // happens per *event*; everything below happens once per *message*.
    let key = (sender, envelope.id.clone());
    let request_id = envelope.id.clone();
    let now = Instant::now();
    let accepted = {
        let mut reassembler = partials.lock().expect("the reassembler");
        // A request is charged once, on whichever of its chunks arrives first — not once per
        // chunk, which is how a single photo used to exhaust the minute.
        let known = reassembler.knows(&key);
        if !known
            && envelope.total > 1
            && reassembler.in_flight_where(|(client, _)| *client == sender) >= MAX_IN_FLIGHT_PER_CLIENT
        {
            reassembler.refuse(key, now);
            drop(reassembler);
            tracing::info!(client = %sender, "too many half-sent messages");
            return Ok(());
        }
        let charge = if known {
            Ok(())
        } else {
            ceilings.requests.check(&sender)
        };
        match charge {
            Ok(()) => Ok(reassembler.accept(key, envelope, now)),
            Err(wait) => {
                // And refused as a whole, so that its remaining chunks are dropped quietly rather
                // than each one being charged, refused and answered again.
                reassembler.refuse(key, now);
                Err(wait)
            }
        }
    };
    let accepted = match accepted {
        Ok(accepted) => accepted,
        Err(wait) => {
            tracing::info!(client = %sender, "rate limited");
            return answer(config, client, &sender, too_many_requests(request_id, wait)).await;
        }
    };
    let (head, body) = match accepted {
        Accepted::Complete { head, body } => (head, body),
        Accepted::Waiting => return Ok(()),
        Accepted::Refused(reason) => {
            // Nothing goes back. There is no id to answer on — the head may be the very chunk that
            // was refused — and a bridge that replied to every malformed chunk would be a way to
            // make it publish to a relay on demand.
            tracing::info!(client = %sender, reason, "dropped a chunk");
            return Ok(());
        }
    };

    let request = HttpRequest::from_head(&head, body)?;
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
            return answer(
                config,
                client,
                &sender,
                HttpResponse {
                    id: request_id,
                    status: 403,
                    headers: Default::default(),
                    body: Vec::new(),
                },
            )
            .await;
        }
    };
    let host = upstream.host_str().unwrap_or("?").to_string();

    let response = match forwarder.forward(request, &upstream, &config.upstreams).await {
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

    answer(config, client, &sender, response).await
}

/// Whether an event was made close enough to now to be a request somebody is waiting on.
fn is_fresh(created_at: Timestamp, now: Timestamp) -> bool {
    created_at.as_secs().abs_diff(now.as_secs()) <= MAX_CLOCK_SKEW_SECS
}

/// A refusal the Matrix SDK knows what to do with.
///
/// It used to be silence, and silence is the one answer a bridge must never give: the SDK waited
/// out its own ninety seconds with nothing to say why. `M_LIMIT_EXCEEDED` with `retry_after_ms` is
/// what a homeserver says when it rate-limits, so the SDK already backs off and retries on it —
/// when the ceiling allows, not before and not never.
fn too_many_requests(id: String, wait: std::time::Duration) -> HttpResponse {
    let retry_after_ms = wait.as_millis().max(1);
    let body = format!(
        r#"{{"errcode":"M_LIMIT_EXCEEDED","error":"The bridge is rate-limiting this device","retry_after_ms":{retry_after_ms}}}"#
    );
    HttpResponse {
        id,
        status: 429,
        headers: [("content-type".to_string(), "application/json".to_string())]
            .into_iter()
            .collect(),
        body: body.into_bytes(),
    }
}

/// Send one response back to the client that asked, in as many chunks as it takes.
///
/// Extracted because a refusal is as owed an answer as a success is: silence would leave the SDK
/// waiting out its own timeout with no way to tell "this bridge will not serve that homeserver"
/// from "this bridge is dead".
async fn answer(
    config: &Config,
    client: &Client,
    to: &PublicKey,
    response: HttpResponse,
) -> Result<()> {
    let id = response.id.clone();
    let envelopes = response.into_envelopes(config.max_body_chunk);

    let mut sealed = Vec::with_capacity(envelopes.len());
    for envelope in &envelopes {
        let content = match seal(config.keys.secret_key(), to, envelope) {
            Ok(content) => content,
            // One chunk of the body always fits; a *head* need not, because the head also carries
            // the response headers, and a homeserver may send headers longer than the whole chunk
            // budget. There is nothing to cut there, so the honest answer is the one the client
            // can act on rather than silence.
            Err(ProtoError::TooLarge(bytes)) => {
                tracing::warn!(bytes, "a chunk head does not fit one envelope; answering 502");
                let refusal = HttpResponse {
                    id: id.clone(),
                    status: 502,
                    headers: Default::default(),
                    body: Vec::new(),
                }
                .into_single_envelope();
                let content = seal(config.keys.secret_key(), to, &refusal)?;
                return publish(config, client, to, content).await;
            }
            Err(error) => return Err(error.into()),
        };
        sealed.push(content);
    }

    // **All at once, never one after another.** `send_event` does not return when the event is on
    // its way; it returns when *every* relay in the pool has acknowledged it or timed out, and a
    // relay that is down times out after ten seconds (`WAIT_FOR_OK_TIMEOUT` in nostr-relay-pool).
    // Sent in sequence, chunk two waited ten seconds for chunk one's dead relay, chunk three
    // twenty: a 53 KB sync answer took 20.4 s through the bridge and 1 ms without it. A
    // one-chunk answer never showed it — the client has the event from the live relay long before
    // the dead one gives up — which is why it survived until a whole session was measured
    // (`LiveBridgeSessionTests`). The client reassembles out of order, so order buys nothing here.
    let mut sends = JoinSet::new();
    for content in sealed {
        let event = EventBuilder::new(Kind::Custom(KIND_RESPONSE), content)
            .tag(Tag::public_key(*to))
            .sign_with_keys(&config.keys)?;
        let client = client.clone();
        sends.spawn(async move { client.send_event(&event).await });
    }
    let mut first_error = None;
    while let Some(joined) = sends.join_next().await {
        if let Ok(Err(error)) = joined {
            first_error.get_or_insert(error);
        }
    }
    match first_error {
        Some(error) => Err(error.into()),
        None => Ok(()),
    }
}

/// Publish one sealed event to every relay.
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

#[cfg(test)]
mod freshness {
    use super::*;

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
