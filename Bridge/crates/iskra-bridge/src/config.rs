//! Everything the bridge needs, taken from the environment and validated once.
//!
//! Validated *once*, at startup, is the point: a bridge that discovers its homeserver list is
//! nonsense on the first stream has already accepted traffic it cannot serve.

use std::collections::{BTreeSet, HashSet};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Write};
use std::num::NonZeroU32;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use iskra_tunnel_proto::{DEFAULT_POW_BITS, DEFAULT_SEGMENT, MAX_POW_BITS};
use nostr_sdk::prelude::{Keys, PublicKey};
use url::Url;

use crate::upstream::{parse_origin, Allowed, Upstreams};

/// Relays a bridge listens on when told nothing: the same three the app uses when *it* is told
/// nothing (`TunnelSettings.defaultRelays`), so a bridge and a client set up by somebody who left
/// both fields empty already agree. `relay.damus.io` is left out on purpose — it answers `503` to
/// the connection itself often enough to be the standing example.
pub const DEFAULT_RELAYS: [&str; 3] = [
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://relay.nostr.band",
];

/// Events per minute one client key may send before the bridge stops decrypting them. Charged
/// before anything is known about an event, because decrypting is the bridge's main cost. A 64 MiB
/// minute of streaming is about 2700 segments, plus their acknowledgements; this is well above it.
pub const DEFAULT_EVENTS_PER_MIN: u32 = 8192;

/// Settings of the protocol that is gone. Set, they are said out loud at startup rather than
/// ignored in silence: an operator who still sets `HOMESERVER_URL` believes something about this
/// bridge that is no longer true.
const RETIRED: [(&str, &str); 5] = [
    ("HOMESERVER_URL", "list the homeserver in ALLOWED_UPSTREAMS"),
    ("RATE_LIMIT_PER_MIN", "the bridge no longer sees requests; see STREAM_BYTES_PER_MIN and EVENTS_PER_MIN"),
    ("REQUEST_TIMEOUT_SECS", "the bridge no longer makes requests"),
    ("MAX_BODY_CHUNK", "renamed SEGMENT_BYTES"),
    ("BLIND_ONLY", "the bridge carries streams only, always"),
];

#[derive(Debug, Clone)]
pub struct Config {
    /// Which homeservers this bridge will carry streams to.
    pub upstreams: Upstreams,
    /// The bridge's own nostr identity. Clients address it by this public key.
    pub keys: Keys,
    /// Relays the bridge listens on.
    pub relays: Vec<String>,
    /// Relays the bridge tells clients to use. Usually the same list; separate so it can be
    /// changed for clients without restarting what the bridge itself is connected to.
    pub client_relays: Vec<String>,
    /// Events per minute per client key, charged before decrypting.
    pub events_per_min: NonZeroU32,
    /// `None` means an open bridge. `Some` means only these keys are served.
    pub allowed_pubkeys: Option<HashSet<PublicKey>>,
    /// Bytes per segment the bridge cuts what it reads into.
    pub segment_bytes: usize,
    /// NIP-13 bits an `open` must be mined to. `0` turns it off.
    pub pow_bits: u8,
    pub streams: StreamLimits,
}

/// The ceilings on streams. None of them is per *request* — the bridge sees no requests — and
/// none can be got round by a new nostr key alone: the totals hold whatever the key.
#[derive(Debug, Clone)]
pub struct StreamLimits {
    /// Streams one client key may have open. The SDK keeps a small pool of connections, one or two
    /// with HTTP/2; sixteen is room for that and for the notification extension beside it.
    pub per_client: usize,
    /// Streams open at once, everybody together. Each holds a socket and up to a window of memory.
    pub total: usize,
    /// Bytes per minute one client may move, both directions together. Over it, the stream slows
    /// down — the bridge stops reading and stops acknowledging — rather than breaking.
    pub bytes_per_min: NonZeroU32,
    /// The same for everybody together, so that one neighbour cannot take the whole uplink.
    pub bytes_per_min_total: Option<NonZeroU32>,
}

impl Default for StreamLimits {
    fn default() -> Self {
        Self {
            per_client: 16,
            total: 2048,
            bytes_per_min: NonZeroU32::new(64 * 1024 * 1024).expect("a non-zero constant"),
            bytes_per_min_total: None,
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self> {
        for (name, instead) in RETIRED {
            if optional(name).is_some() {
                tracing::warn!("{name} is no longer read — {instead}");
            }
        }

        let allowed = match optional("ALLOWED_UPSTREAMS") {
            None if optional("HOMESERVER_URL").is_some() => {
                return Err(anyhow!(
                    "HOMESERVER_URL is gone; put the homeserver in ALLOWED_UPSTREAMS instead"
                ))
            }
            None => {
                return Err(anyhow!(
                    "ALLOWED_UPSTREAMS is required: a list of homeservers, or * for any public one"
                ))
            }
            // `*` is deliberately ugly to write and impossible to arrive at by accident: it turns
            // the bridge into one anybody on any homeserver can use, which is a decision, not a
            // default.
            Some(raw) if raw.trim() == "*" => Allowed::Anywhere,
            Some(raw) => {
                let mut set = BTreeSet::new();
                for item in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
                    set.insert(parse_origin(item).with_context(|| {
                        format!("ALLOWED_UPSTREAMS contains a bad entry: {item}")
                    })?);
                }
                Allowed::These(set)
            }
        };
        let upstreams = Upstreams::new(allowed)?;

        let keys = match (optional("BRIDGE_NOSTR_PRIVKEY"), optional("BRIDGE_KEY_FILE")) {
            (Some(secret), _) => Keys::parse(secret.trim())
                .map_err(|_| anyhow!("BRIDGE_NOSTR_PRIVKEY is not an nsec or hex secret key"))?,
            (None, Some(path)) => load_or_create_key(Path::new(&path))?,
            (None, None) => {
                return Err(anyhow!("BRIDGE_NOSTR_PRIVKEY or BRIDGE_KEY_FILE is required"))
            }
        };

        let relays = match optional("RELAY_LIST") {
            Some(raw) => relay_list("RELAY_LIST", &raw)?,
            None => DEFAULT_RELAYS.iter().map(|relay| relay.to_string()).collect(),
        };
        if relays.is_empty() {
            return Err(anyhow!("RELAY_LIST is empty; the bridge would hear nothing"));
        }
        let client_relays = match optional("CLIENT_RELAY_LIST") {
            Some(raw) => relay_list("CLIENT_RELAY_LIST", &raw)?,
            None => relays.clone(),
        };

        let events_per_min = NonZeroU32::new(parse_or("EVENTS_PER_MIN", DEFAULT_EVENTS_PER_MIN)?)
            .ok_or_else(|| anyhow!("EVENTS_PER_MIN must be at least 1"))?;

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

        let segment_bytes = parse_or("SEGMENT_BYTES", DEFAULT_SEGMENT)?;
        if segment_bytes == 0 || segment_bytes > DEFAULT_SEGMENT {
            return Err(anyhow!(
                "SEGMENT_BYTES must be between 1 and {DEFAULT_SEGMENT}: a larger segment does not fit one NIP-44 payload"
            ));
        }

        let pow_bits = parse_or("POW_DIFFICULTY", DEFAULT_POW_BITS)?;
        if pow_bits > MAX_POW_BITS {
            // Each bit doubles the client's work, and clients ignore a difficulty past this: a
            // bridge set higher would be a bridge nobody can use, not a well-defended one.
            return Err(anyhow!("POW_DIFFICULTY must be at most {MAX_POW_BITS}"));
        }

        let defaults = StreamLimits::default();
        let streams = StreamLimits {
            per_client: parse_or("MAX_STREAMS_PER_CLIENT", defaults.per_client)?.max(1),
            total: parse_or("MAX_STREAMS", defaults.total)?.max(1),
            bytes_per_min: NonZeroU32::new(parse_or(
                "STREAM_BYTES_PER_MIN",
                defaults.bytes_per_min.get(),
            )?)
            .ok_or_else(|| anyhow!("STREAM_BYTES_PER_MIN must be at least 1"))?,
            bytes_per_min_total: match optional("STREAM_BYTES_PER_MIN_TOTAL") {
                None => None,
                Some(_) => Some(
                    NonZeroU32::new(parse_or("STREAM_BYTES_PER_MIN_TOTAL", 0u32)?)
                        .ok_or_else(|| anyhow!("STREAM_BYTES_PER_MIN_TOTAL must be at least 1"))?,
                ),
            },
        };

        Ok(Self {
            upstreams,
            keys,
            relays,
            client_relays,
            events_per_min,
            allowed_pubkeys,
            segment_bytes,
            pow_bits,
            streams,
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

/// The key in `path`, or a new one written there if there is none yet.
///
/// The key *is* the bridge's address — its public half is what people type into the app — so a key
/// made afresh on every start would be a bridge that moves every time its container is recreated.
/// Kept on a volume, it is made once and read ever after, and nobody setting a bridge up has to
/// know what `openssl rand` is.
///
/// `create_new` rather than check-then-write: two copies started at once against one volume must
/// end up with one key between them, not one each with the second silently overwriting the first.
pub fn load_or_create_key(path: &Path) -> Result<Keys> {
    match std::fs::read_to_string(path) {
        Ok(raw) => {
            return Keys::parse(raw.trim()).map_err(|_| {
                anyhow!("{} does not hold an nsec or hex secret key", path.display())
            })
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error).with_context(|| format!("cannot read {}", path.display()))
        }
    }

    let keys = Keys::generate();
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    match options.open(path) {
        Ok(mut file) => {
            writeln!(file, "{}", keys.secret_key().to_secret_hex())
                .and_then(|()| file.sync_all())
                .with_context(|| format!("cannot write {}", path.display()))?;
            tracing::info!(path = %path.display(), "made a new bridge key");
            Ok(keys)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => load_or_create_key(path),
        Err(error) => Err(error).with_context(|| {
            format!("cannot create {}; is the directory writable?", path.display())
        }),
    }
}

fn relay_list(name: &str, raw: &str) -> Result<Vec<String>> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use nostr_sdk::prelude::ToBech32;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("iskra-bridge-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn key_file_is_made_once_and_then_kept() {
        let path = scratch("kept").join("bridge-key");
        let first = load_or_create_key(&path).unwrap();
        let second = load_or_create_key(&path).unwrap();
        assert_eq!(first.public_key(), second.public_key());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn key_file_written_by_hand_is_read_as_is() {
        let path = scratch("by-hand").join("bridge-key");
        let keys = Keys::generate();
        let nsec = keys.secret_key().to_bech32().unwrap();
        std::fs::write(&path, format!("  {nsec}\n\n")).unwrap();
        assert_eq!(load_or_create_key(&path).unwrap().public_key(), keys.public_key());
    }

    /// A key file that cannot be read is a stop, never a fresh key: replacing it would quietly move
    /// the bridge to a new address, and every device pointed at the old one would just go silent.
    #[test]
    fn key_file_with_nonsense_is_refused_not_replaced() {
        let path = scratch("nonsense").join("bridge-key");
        std::fs::write(&path, "not a key").unwrap();
        assert!(load_or_create_key(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "not a key");
    }

    #[test]
    fn key_file_in_a_missing_directory_is_an_error() {
        let path = scratch("missing").join("no-such-dir").join("bridge-key");
        assert!(load_or_create_key(&path).is_err());
    }
}
