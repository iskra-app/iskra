//! Everything the bridge needs, taken from the environment and validated once.
//!
//! Validated *once*, at startup, is the point: a bridge that discovers its homeserver URL is
//! nonsense on the first tunnelled request has already accepted traffic it cannot serve.

use std::collections::HashSet;
use std::num::NonZeroU32;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use iskra_tunnel_proto::DEFAULT_MAX_BODY_CHUNK;
use nostr_sdk::prelude::{Keys, PublicKey};
use url::Url;

#[derive(Debug, Clone)]
pub struct Config {
    /// The one homeserver this bridge fronts.
    pub homeserver: Url,
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
        let homeserver = required("HOMESERVER_URL")?;
        let homeserver = Url::parse(&homeserver)
            .with_context(|| "HOMESERVER_URL is not a URL".to_string())?;
        if !matches!(homeserver.scheme(), "http" | "https") {
            return Err(anyhow!("HOMESERVER_URL must be http or https"));
        }

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
            homeserver,
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
