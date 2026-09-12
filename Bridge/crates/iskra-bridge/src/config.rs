//! Everything the bridge needs, taken from the environment and validated once.
//!
//! Validated *once*, at startup, is the point: a bridge that discovers its homeserver URL is
//! nonsense on the first tunnelled request has already accepted traffic it cannot serve.

use std::collections::{BTreeSet, HashSet};
use std::num::NonZeroU32;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use iskra_tunnel_proto::DEFAULT_MAX_BODY_CHUNK;
use nostr_sdk::prelude::{Keys, PublicKey};
use url::Url;

use crate::upstream::{parse_origin, Allowed, Upstreams};

#[derive(Debug, Clone)]
pub struct Config {
    /// Which homeservers this bridge will go to, and which one it falls back on.
    pub upstreams: Upstreams,
    /// The bridge's own nostr identity. Clients address it by this public key.
    pub keys: Keys,
    /// Relays the bridge listens on.
    pub relays: Vec<String>,
    /// Relays the bridge tells clients to use. Usually the same list; separate so it can be
    /// changed for clients without restarting what the bridge itself is connected to.
    pub client_relays: Vec<String>,
    pub rate_limit_per_min: NonZeroU32,
    /// `None` means an open bridge. `Some` means only these keys are served.
    pub allowed_pubkeys: Option<HashSet<PublicKey>>,
    pub max_body_chunk: usize,
    pub request_timeout: Duration,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        // Both optional, and at least one required — `Upstreams::new` is what insists on that.
        // `HOMESERVER_URL` alone keeps an existing deployment behaving exactly as it did: one
        // homeserver, no client may name another.
        let homeserver = match optional("HOMESERVER_URL") {
            None => None,
            Some(raw) => {
                let url = Url::parse(&raw)
                    .with_context(|| "HOMESERVER_URL is not a URL".to_string())?;
                if !matches!(url.scheme(), "http" | "https") {
                    return Err(anyhow!("HOMESERVER_URL must be http or https"));
                }
                Some(url)
            }
        };

        let allowed = match optional("ALLOWED_UPSTREAMS") {
            None => None,
            // `*` is deliberately ugly to write and impossible to arrive at by accident: it turns
            // the bridge into one anybody on any homeserver can use, which is a decision, not a
            // default.
            Some(raw) if raw.trim() == "*" => Some(Allowed::Anywhere),
            Some(raw) => {
                let mut set = BTreeSet::new();
                for item in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
                    set.insert(parse_origin(item).with_context(|| {
                        format!("ALLOWED_UPSTREAMS contains a bad entry: {item}")
                    })?);
                }
                if set.is_empty() {
                    return Err(anyhow!("ALLOWED_UPSTREAMS is empty; remove it or fill it in"));
                }
                Some(Allowed::These(set))
            }
        };

        let upstreams = Upstreams::new(homeserver, allowed)?;

        let secret = required("BRIDGE_NOSTR_PRIVKEY")?;
        let keys = Keys::parse(&secret)
            .map_err(|_| anyhow!("BRIDGE_NOSTR_PRIVKEY is not an nsec or hex secret key"))?;

        let relays = relay_list("RELAY_LIST")?;
        if relays.is_empty() {
            return Err(anyhow!("RELAY_LIST is empty; the bridge would hear nothing"));
        }
        let client_relays = match std::env::var("CLIENT_RELAY_LIST") {
            Ok(_) => relay_list("CLIENT_RELAY_LIST")?,
            Err(_) => relays.clone(),
        };

        let rate_limit_per_min = parse_or("RATE_LIMIT_PER_MIN", 120u32)?;
        let rate_limit_per_min = NonZeroU32::new(rate_limit_per_min)
            .ok_or_else(|| anyhow!("RATE_LIMIT_PER_MIN must be at least 1"))?;

        let allowed_pubkeys = match std::env::var("ALLOWED_PUBKEYS") {
            Err(_) => None,
            Ok(raw) if raw.trim().is_empty() => None,
            Ok(raw) => {
                let mut set = HashSet::new();
                for item in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
                    let key = PublicKey::parse(item)
                        .map_err(|_| anyhow!("ALLOWED_PUBKEYS contains a key that is not an npub or hex: {item}"))?;
                    set.insert(key);
                }
                Some(set)
            }
        };

        let max_body_chunk = parse_or("MAX_BODY_CHUNK", DEFAULT_MAX_BODY_CHUNK)?;
        let request_timeout = Duration::from_secs(parse_or("REQUEST_TIMEOUT_SECS", 60u64)?);

        Ok(Self {
            upstreams,
            keys,
            relays,
            client_relays,
            rate_limit_per_min,
            allowed_pubkeys,
            max_body_chunk,
            request_timeout,
        })
    }

    /// Whether this client may use the bridge at all. An open bridge says yes to everyone.
    pub fn allows(&self, client: &PublicKey) -> bool {
        match &self.allowed_pubkeys {
            None => true,
            Some(allowed) => allowed.contains(client),
        }
    }
}

/// An unset or blank variable is the same as absent. A deployment that writes `ALLOWED_UPSTREAMS=`
/// in a compose file means "I did not set this", and reading it as an empty allowlist would be a
/// bridge that refuses everything for a reason nobody can see.
fn optional(name: &str) -> Option<String> {
    match std::env::var(name) {
        Err(_) => None,
        Ok(raw) if raw.trim().is_empty() => None,
        Ok(raw) => Some(raw),
    }
}

fn required(name: &str) -> Result<String> {
    std::env::var(name).map_err(|_| anyhow!("{name} is required"))
}

fn relay_list(name: &str) -> Result<Vec<String>> {
    let raw = required(name)?;
    let mut relays = Vec::new();
    for item in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let url = Url::parse(item).with_context(|| format!("{name} contains a bad URL: {item}"))?;
        if !matches!(url.scheme(), "ws" | "wss") {
            return Err(anyhow!("{name} entries must be ws:// or wss://, got {item}"));
        }
        relays.push(item.to_string());
    }
    Ok(relays)
}

fn parse_or<T>(name: &str, default: T) -> Result<T>
where
    T: std::str::FromStr,
    T::Err: std::fmt::Display,
{
    match std::env::var(name) {
        Err(_) => Ok(default),
        Ok(raw) if raw.trim().is_empty() => Ok(default),
        Ok(raw) => raw
            .trim()
            .parse::<T>()
            .map_err(|error| anyhow!("{name} is not valid: {error}")),
    }
}
