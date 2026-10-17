//! Which homeservers this bridge is willing to carry streams to, as the operator wrote it down.
//!
//! `ALLOWED_UPSTREAMS` is either a list of origins or `*`. What a stream may actually reach is
//! decided in `blind.rs`, which reads this list as hosts and ports; this module holds the list and
//! the two facts about addresses that decision rests on — which names are private by what they are
//! called, and which addresses the public internet routes to.

use std::collections::BTreeSet;
use std::net::IpAddr;

use anyhow::{anyhow, Result};
use url::Url;

/// What the operator said about where the bridge may go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Allowed {
    /// Any public Matrix server. Usable by anyone on any homeserver — which is the point of a
    /// public bridge, and also why `ALLOWED_PUBKEYS` and the ceilings exist.
    Anywhere,
    /// Exactly these origins, normalised to `https://host[:port]`.
    These(BTreeSet<String>),
}

#[derive(Debug, Clone)]
pub struct Upstreams {
    allowed: Allowed,
}

impl Upstreams {
    pub fn new(allowed: Allowed) -> Result<Self> {
        if let Allowed::These(list) = &allowed {
            if list.is_empty() {
                return Err(anyhow!(
                    "ALLOWED_UPSTREAMS is empty; a bridge that may go nowhere has nothing to do"
                ));
            }
        }
        Ok(Self { allowed })
    }

    /// Every homeserver this bridge will go to, for the startup line. Empty for an open bridge.
    pub fn listed(&self) -> Vec<String> {
        match &self.allowed {
            Allowed::Anywhere => Vec::new(),
            Allowed::These(list) => list.iter().cloned().collect(),
        }
    }

    pub fn is_open(&self) -> bool {
        matches!(self.allowed, Allowed::Anywhere)
    }
}

/// `https://Matrix.ORG:443/_matrix/…` -> `https://matrix.org`.
///
/// Comparing origins rather than URLs is what makes the list a list of *servers*: an entry written
/// with a trailing slash, a default port, or in capitals is the same server either way.
pub fn origin_of(url: &Url) -> String {
    url.origin().ascii_serialization()
}

/// Parse one `ALLOWED_UPSTREAMS` entry into the origin it names.
///
/// `https` only. A stream is somebody's own TLS to the homeserver; an `http` homeserver has no TLS
/// for the bridge to be blind to, and carrying it would be carrying somebody's token in the clear.
pub fn parse_origin(raw: &str) -> Result<String> {
    let raw = raw.trim();
    // A bare host is what an operator will write, and refusing it over a missing scheme would be
    // pedantry.
    let candidate = if raw.contains("://") {
        raw.to_string()
    } else {
        format!("https://{raw}")
    };
    let url = Url::parse(&candidate).map_err(|_| anyhow!("not a URL: {raw}"))?;
    if url.scheme() != "https" {
        return Err(anyhow!("must be https: {raw}"));
    }
    if url.host().is_none() {
        return Err(anyhow!("has no host: {raw}"));
    }
    Ok(origin_of(&url))
}

/// Names that are private by what they are called, before anybody resolves them.
pub(crate) fn is_local_name(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
}

/// Whether an address is one the public internet routes to.
///
/// Written out rather than using `IpAddr::is_global`, which is still unstable. Anything not
/// recognised as public is refused, so a gap here errs towards refusing traffic rather than
/// towards opening a door onto the operator's network.
pub(crate) fn is_global(address: &IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => {
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || v4.is_multicast()
                // 100.64.0.0/10, carrier-grade NAT.
                || (v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]))
                // 192.0.0.0/24, IETF protocol assignments.
                || v4.octets()[..3] == [192, 0, 0]
                // 198.18.0.0/15, benchmarking.
                || (v4.octets()[0] == 198 && (v4.octets()[1] & 0xfe) == 18)
                // 240.0.0.0/4, reserved.
                || v4.octets()[0] >= 240)
        }
        IpAddr::V6(v6) => {
            if v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() {
                return false;
            }
            let segments = v6.segments();
            // fc00::/7 unique local, fe80::/10 link local.
            if (segments[0] & 0xfe00) == 0xfc00 || (segments[0] & 0xffc0) == 0xfe80 {
                return false;
            }
            // An IPv4 address wearing an IPv6 hat is still that address.
            match v6.to_ipv4_mapped() {
                Some(v4) => is_global(&IpAddr::V4(v4)),
                None => true,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_origin_is_written_however_the_operator_likes() {
        for written in [
            "matrix.org",
            "https://matrix.org",
            "https://matrix.org/",
            "https://MATRIX.ORG",
            "https://matrix.org:443/_matrix/client/versions",
        ] {
            assert_eq!(parse_origin(written).unwrap(), "https://matrix.org");
        }
        assert_eq!(
            parse_origin("matrix.example.org:8448").unwrap(),
            "https://matrix.example.org:8448"
        );
    }

    #[test]
    fn only_https_origins() {
        for written in [
            "http://matrix.org",
            "ftp://matrix.org",
            "file:///etc/passwd",
        ] {
            assert!(parse_origin(written).is_err(), "{written}");
        }
    }

    #[test]
    fn an_empty_list_will_not_start() {
        assert!(Upstreams::new(Allowed::These(BTreeSet::new())).is_err());
    }

    #[test]
    fn private_addresses_are_not_global() {
        for address in [
            "127.0.0.1",
            "10.0.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "240.0.0.178",
            "::1",
            "fd00::1",
            "fe80::1",
            "::ffff:10.0.0.1",
        ] {
            assert!(!is_global(&address.parse().unwrap()), "{address}");
        }
        for address in ["1.1.1.1", "2606:4700:4700::1111"] {
            assert!(is_global(&address.parse().unwrap()), "{address}");
        }
    }

    #[test]
    fn names_that_say_they_are_private() {
        for host in [
            "localhost",
            "LOCALHOST.",
            "a.localhost",
            "printer.local",
            "box.internal",
        ] {
            assert!(is_local_name(host), "{host}");
        }
        assert!(!is_local_name("matrix.org"));
    }
}
