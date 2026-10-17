//! Per-client ceilings.
//!
//! Without them the bridge is an open anonymous proxy that anybody who learns its public key can
//! point anywhere — and the public key is, by design, public.
//!
//! There are two, and they count different things on purpose. `RATE_LIMIT_PER_MIN` is a ceiling on
//! **requests** — what reaches the homeserver, and what an operator means by the number. It used to
//! be charged per nostr *event*, which was the same thing until chunking made it not: a 3 MB photo
//! is a hundred and twenty-eight events, so one upload spent the whole minute's allowance, and the
//! chunks past it were dropped in silence and the upload hung until the client gave up. The second
//! ceiling is on events, and it is there for the work the bridge does before it can know what a
//! request is — decrypting — generous enough that no honest upload meets it.

use std::num::NonZeroU32;
use std::time::Duration;

use governor::clock::{Clock, DefaultClock};
use governor::state::keyed::DefaultKeyedStateStore;
use governor::state::{InMemoryState, NotKeyed};
use governor::{Quota, RateLimiter};
use nostr_sdk::prelude::PublicKey;

pub struct RateLimit {
    inner: RateLimiter<PublicKey, DefaultKeyedStateStore<PublicKey>, DefaultClock>,
}

impl RateLimit {
    pub fn per_minute(limit: NonZeroU32) -> Self {
        Self {
            inner: RateLimiter::keyed(Quota::per_minute(limit)),
        }
    }

    /// True when this client may make one more request right now.
    pub fn allow(&self, client: &PublicKey) -> bool {
        self.inner.check_key(client).is_ok()
    }

    /// The same, and when it is not allowed, how long until it would be.
    ///
    /// Which is what goes back to the client as `retry_after_ms`: the Matrix SDK honours it, so a
    /// refused request is retried when it can succeed rather than hammered or abandoned.
    pub fn check(&self, client: &PublicKey) -> Result<(), Duration> {
        self.inner
            .check_key(client)
            .map_err(|not_until| not_until.wait_time_from(DefaultClock::default().now()))
    }

    /// Drop the state of clients that have gone quiet, so a bridge that has seen many keys over a
    /// long uptime does not keep every one of them forever.
    pub fn retain_recent(&self) {
        self.inner.retain_recent();
    }
}

/// Bytes per minute, per client and for everybody, for v2 streams.
///
/// Waited on, not refused: a stream over its allowance is slowed, not broken. The bridge stops
/// reading the socket (one direction) or stops writing and acknowledging (the other), and the
/// windows on both sides turn that into TCP back-pressure all the way to whoever is sending.
pub struct ByteLimit {
    per_client: RateLimiter<PublicKey, DefaultKeyedStateStore<PublicKey>, DefaultClock>,
    total: Option<RateLimiter<NotKeyed, InMemoryState, DefaultClock>>,
}

impl ByteLimit {
    pub fn new(per_client: NonZeroU32, total: Option<NonZeroU32>) -> Self {
        Self {
            per_client: RateLimiter::keyed(Quota::per_minute(per_client)),
            total: total.map(|total| RateLimiter::direct(Quota::per_minute(total))),
        }
    }

    /// Wait until `client` may move `bytes` more.
    pub async fn take(&self, client: &PublicKey, bytes: usize) {
        let Some(n) = NonZeroU32::new(bytes.min(u32::MAX as usize) as u32) else {
            return;
        };
        loop {
            match self.per_client.check_key_n(client, n) {
                Ok(Ok(())) => break,
                Ok(Err(not_until)) => {
                    tokio::time::sleep(not_until.wait_time_from(DefaultClock::default().now()))
                        .await
                }
                // More than a whole minute's allowance in one go: never satisfiable, so not
                // waited for. Segments are 24 KiB and the smallest sane allowance is megabytes.
                Err(_) => break,
            }
        }
        if let Some(total) = &self.total {
            loop {
                match total.check_n(n) {
                    Ok(Ok(())) => break,
                    Ok(Err(not_until)) => {
                        tokio::time::sleep(not_until.wait_time_from(DefaultClock::default().now()))
                            .await
                    }
                    Err(_) => break,
                }
            }
        }
    }

    pub fn retain_recent(&self) {
        self.per_client.retain_recent();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr_sdk::prelude::Keys;

    #[test]
    fn a_client_is_cut_off_after_its_quota() {
        let limit = RateLimit::per_minute(NonZeroU32::new(3).unwrap());
        let client = Keys::generate().public_key();

        assert!(limit.allow(&client));
        assert!(limit.allow(&client));
        assert!(limit.allow(&client));
        assert!(!limit.allow(&client));
    }

    #[test]
    fn one_loud_client_does_not_silence_another() {
        let limit = RateLimit::per_minute(NonZeroU32::new(1).unwrap());
        let loud = Keys::generate().public_key();
        let quiet = Keys::generate().public_key();

        assert!(limit.allow(&loud));
        assert!(!limit.allow(&loud));
        assert!(limit.allow(&quiet));
    }

    /// On the real clock — governor keeps its own, which tokio's paused time does not move.
    #[tokio::test]
    async fn bytes_over_the_allowance_wait_rather_than_fail() {
        let limit = ByteLimit::new(NonZeroU32::new(6000).unwrap(), None);
        let client = Keys::generate().public_key();
        let start = std::time::Instant::now();
        limit.take(&client, 6000).await;
        assert!(start.elapsed() < Duration::from_millis(200));
        // 6000 a minute is 100 a second; 50 more is half a second's worth.
        limit.take(&client, 50).await;
        assert!(start.elapsed() >= Duration::from_millis(400), "{:?}", start.elapsed());
    }
}
