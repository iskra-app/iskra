//! Per-client request ceiling.
//!
//! Without it the bridge is an open anonymous proxy that anybody who learns its public key can
//! point anywhere — and the public key is, by design, public.

use std::num::NonZeroU32;

use governor::clock::DefaultClock;
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
