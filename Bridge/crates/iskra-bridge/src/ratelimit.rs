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
}
