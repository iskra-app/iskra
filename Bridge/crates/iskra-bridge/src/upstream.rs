//! Which homeservers this bridge is willing to talk to.
//!
//! Once the target moved into the request, "which homeserver" stopped being a deployment detail
//! and became an access-control decision made per request, on behalf of a stranger. That is what
//! this module is: the bridge's answer to *where will you go for me*, and the reasons it says no.
//!
//! Three refusals matter more than the rest, and each of them is a thing an open bridge would
//! otherwise be:
//!
//! - **Not a Matrix path** — without this the bridge is a general-purpose web proxy that happens
//!   to speak nostr. Everything the Client-Server API needs lives under `/_matrix/` or
//!   `/.well-known/matrix/`, so nothing legitimate is lost and a great deal of abuse is.
//! - **Not a public address** — without this the bridge is a window into the network it runs on.
//!   `http://192.168.1.1/`, `http://169.254.169.254/latest/meta-data/`, `http://127.0.0.1:8080/`:
//!   an open proxy that will fetch those on request is a scanner for the operator's own LAN.
//! - **Not on the list** — an operator who names their homeservers gets a bridge that serves those
//!   and nothing else, which is the right default for a bridge run for a community.

use std::collections::BTreeSet;
use std::net::IpAddr;

use anyhow::{anyhow, Result};
use url::Url;

/// The one path prefix outside `/_matrix/` a Matrix client legitimately asks for.
const WELL_KNOWN: &str = "/.well-known/matrix/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The client named no homeserver and the bridge has no default to fall back on.
    NoTarget,
    NotAUrl,
    /// Neither `http` nor `https`, or no host at all.
    BadOrigin,
    /// Not one of the homeservers this bridge serves.
    NotAllowed,
    /// A loopback, private, link-local or otherwise non-public address.
    NotPublic,
    /// A path outside the Matrix API.
    NotMatrix,
}

impl Refusal {
    /// One short word for the log. Deliberately says nothing about *which* address or path was
    /// asked for: a refusal is still somebody's traffic.
    pub fn as_str(&self) -> &'static str {
        match self {
            Refusal::NoTarget => "no target",
            Refusal::NotAUrl => "not a url",
            Refusal::BadOrigin => "bad origin",
            Refusal::NotAllowed => "not allowed",
            Refusal::NotPublic => "not public",
            Refusal::NotMatrix => "not matrix",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What the operator said about where the bridge may go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Allowed {
    /// Any public homeserver. The bridge becomes usable by anyone on any server — which is the
    /// point of a public bridge, and also why `ALLOWED_PUBKEYS` and the rate limit exist.
    Anywhere,
    /// Exactly these origins, normalised to `scheme://host[:port]`.
    These(BTreeSet<String>),
}

#[derive(Debug, Clone)]
pub struct Upstreams {
    /// Used when a request names no homeserver. Older clients, and the simplest deployments.
    default: Option<Url>,
    allowed: Allowed,
}

impl Upstreams {
    /// - `default` — `HOMESERVER_URL`, if the operator set one.
    /// - `allowed` — `ALLOWED_UPSTREAMS`. Unset means "the default and nothing else", which is
    ///   exactly what this bridge did before it could serve more than one homeserver, so an
    ///   existing deployment keeps behaving as it did.
    pub fn new(default: Option<Url>, allowed: Option<Allowed>) -> Result<Self> {
        let allowed = match (allowed, &default) {
            (Some(allowed), _) => allowed,
            (None, Some(default)) => Allowed::These(BTreeSet::from([origin_of(default)])),
            (None, None) => {
                return Err(anyhow!(
                    "set HOMESERVER_URL, or ALLOWED_UPSTREAMS, or both; \
                     a bridge that may go nowhere has nothing to do"
                ))
            }
        };

        // A named default that the list refuses would be a bridge whose own fallback it rejects —
        // better said at startup than discovered on the first request that omits a target.
        if let (Some(default), Allowed::These(list)) = (&default, &allowed) {
            if !list.contains(&origin_of(default)) {
                return Err(anyhow!(
                    "HOMESERVER_URL is not in ALLOWED_UPSTREAMS; add it or drop one of the two"
                ));
            }
        }

        Ok(Self { default, allowed })
    }

    /// The origin a request that names nothing falls back to, if there is one. For the startup
    /// line, and for tests that need to add a homeserver to whatever is already allowed.
    pub fn default_origin(&self) -> Option<String> {
        self.default.as_ref().map(origin_of)
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

    /// How many homeservers this bridge serves, for the startup line. `None` means any.
    pub fn count(&self) -> Option<usize> {
        match &self.allowed {
            Allowed::Anywhere => None,
            Allowed::These(list) => Some(list.len()),
        }
    }

    /// The exact URL to fetch, or the reason not to.
    ///
    /// The path is checked here rather than in the forwarder because the two decisions are one
    /// decision: what this bridge is for. Splitting them would let a later refactor keep the host
    /// rule and lose the path rule without anything looking wrong.
    ///
    /// **The whole URL is built first and judged afterwards, and that order is the security
    /// property.** Judging the path as the client wrote it looks equivalent and is not: `..` is
    /// only a directory segment once a URL exists to resolve it against, so
    /// `/_matrix/../admin/secrets` passes a `starts_with("/_matrix/")` test and then resolves to
    /// `/admin/secrets` the moment anything joins it to a base. The bridge would have checked one
    /// string and fetched another. Building the URL first means the thing checked and the thing
    /// fetched are the same object — dot segments, percent-encoded dot segments (`%2e%2e`, which
    /// the URL spec treats identically) and protocol-relative `//elsewhere/…` all resolved before
    /// anybody asks whether they are allowed.
    pub async fn resolve(&self, requested: Option<&str>, path: &str) -> Result<Url, Refusal> {
        let base = match requested {
            None => self.default.clone().ok_or(Refusal::NoTarget)?,
            Some(raw) => Url::parse(raw).map_err(|_| Refusal::NotAUrl)?,
        };

        if !matches!(base.scheme(), "http" | "https") || base.host().is_none() {
            return Err(Refusal::BadOrigin);
        }

        let url = base.join(path).map_err(|_| Refusal::NotAUrl)?;

        // `//elsewhere/_matrix/…` is a protocol-relative URL, not a path: joined to the base it
        // names a different host entirely. It is refused as an origin the operator never allowed,
        // which is exactly what it is.
        if url.origin() != base.origin() {
            return Err(Refusal::NotAllowed);
        }
        if !is_matrix_path(url.path()) {
            return Err(Refusal::NotMatrix);
        }

        match &self.allowed {
            Allowed::These(list) => {
                if !list.contains(&origin_of(&base)) {
                    return Err(Refusal::NotAllowed);
                }
            }
            // Only an open bridge needs the address check: an operator who listed their
            // homeservers has already vouched for them, and one of them may legitimately be on the
            // same private network as the bridge.
            Allowed::Anywhere => is_public(&base).await?,
        }

        Ok(url)
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
pub fn parse_origin(raw: &str) -> Result<String> {
    let raw = raw.trim();
    // A bare host is what an operator will write, and refusing it over a missing scheme would be
    // pedantry. https, never http: the bridge-to-homeserver leg is the one place real TLS remains.
    let candidate = if raw.contains("://") {
        raw.to_string()
    } else {
        format!("https://{raw}")
    };
    let url = Url::parse(&candidate).map_err(|_| anyhow!("not a URL: {raw}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(anyhow!("must be http or https: {raw}"));
    }
    if url.host().is_none() {
        return Err(anyhow!("has no host: {raw}"));
    }
    Ok(origin_of(&url))
}

fn is_matrix_path(path: &str) -> bool {
    // Anchored at the start, so `/evil?next=/_matrix/` and `//elsewhere/_matrix/` do not qualify.
    path.starts_with("/_matrix/") || path.starts_with(WELL_KNOWN)
}

/// Refuse an address that is not on the public internet.
///
/// The host is resolved rather than merely inspected, because the interesting case is a name that
/// points somewhere private — an IP literal is the obvious attempt and the easy one to catch.
///
/// This is not complete and should not be sold as such: reqwest resolves the name again when it
/// connects, so a name that answers differently the second time (DNS rebinding) still gets through.
/// Closing that needs the connection itself to be pinned to the address checked here. An operator
/// who cannot accept that gap should list their homeservers instead of running the bridge open.
async fn is_public(target: &Url) -> Result<(), Refusal> {
    let host = target.host_str().ok_or(Refusal::BadOrigin)?;
    let port = target.port_or_known_default().unwrap_or(443);

    if is_local_name(host) {
        return Err(Refusal::NotPublic);
    }

    let addresses: Vec<IpAddr> = match tokio::net::lookup_host((host, port)).await {
        // A name that does not resolve is refused as not public rather than forwarded and left to
        // fail: it is the same answer, arrived at without a connection attempt.
        Err(_) => return Err(Refusal::NotPublic),
        Ok(resolved) => resolved.map(|address| address.ip()).collect(),
    };

    if addresses.is_empty() || !addresses.iter().all(is_global) {
        return Err(Refusal::NotPublic);
    }
    Ok(())
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

    fn url(raw: &str) -> Url {
        Url::parse(raw).expect("test URL")
    }

    fn only(origins: &[&str]) -> Allowed {
        Allowed::These(origins.iter().map(|o| parse_origin(o).unwrap()).collect())
    }

    const PATH: &str = "/_matrix/client/versions";

    #[tokio::test]
    async fn a_named_homeserver_on_the_list_is_served() {
        let upstreams =
            Upstreams::new(None, Some(only(&["matrix.org", "example.org"]))).unwrap();
        let resolved = upstreams
            .resolve(Some("https://example.org"), PATH)
            .await
            .unwrap();
        assert_eq!(origin_of(&resolved), "https://example.org");
    }

    #[tokio::test]
    async fn a_homeserver_off_the_list_is_refused() {
        let upstreams = Upstreams::new(None, Some(only(&["matrix.org"]))).unwrap();
        let refusal = upstreams
            .resolve(Some("https://elsewhere.example"), PATH)
            .await
            .unwrap_err();
        assert_eq!(refusal, Refusal::NotAllowed);
    }

    /// The case that made all of this necessary: discovery is asked of the delegating name and the
    /// API lives at another. One bridge has to serve both or it serves neither properly.
    #[tokio::test]
    async fn delegation_needs_two_origins_and_gets_them() {
        let upstreams = Upstreams::new(
            None,
            Some(only(&["matrix.org", "matrix-client.matrix.org"])),
        )
        .unwrap();

        let discovery = upstreams
            .resolve(Some("https://matrix.org"), "/.well-known/matrix/client")
            .await
            .unwrap();
        let api = upstreams
            .resolve(Some("https://matrix-client.matrix.org"), PATH)
            .await
            .unwrap();

        assert_eq!(origin_of(&discovery), "https://matrix.org");
        assert_eq!(origin_of(&api), "https://matrix-client.matrix.org");
    }

    #[tokio::test]
    async fn a_client_that_names_nothing_gets_the_default() {
        let upstreams = Upstreams::new(Some(url("https://matrix.org")), None).unwrap();
        let resolved = upstreams.resolve(None, PATH).await.unwrap();
        assert_eq!(origin_of(&resolved), "https://matrix.org");
    }

    #[tokio::test]
    async fn with_no_default_a_client_must_name_one() {
        let upstreams = Upstreams::new(None, Some(only(&["matrix.org"]))).unwrap();
        assert_eq!(
            upstreams.resolve(None, PATH).await.unwrap_err(),
            Refusal::NoTarget
        );
    }

    #[tokio::test]
    async fn the_bridge_is_not_a_web_proxy() {
        let upstreams = Upstreams::new(None, Some(Allowed::Anywhere)).unwrap();
        for path in [
            "/",
            "/admin",
            "/evil?next=/_matrix/client/versions",
            "/_matrixevil/",
        ] {
            assert_eq!(
                upstreams
                    .resolve(Some("https://example.org"), path)
                    .await
                    .unwrap_err(),
                Refusal::NotMatrix,
                "{path} should not be forwarded"
            );
        }
    }

    /// A path that starts under `/_matrix/` and does not stay there.
    ///
    /// This is the bug the prefix check had while it looked at the string the client sent: `..` is
    /// not a directory segment until there is a URL to resolve it against, so
    /// `/_matrix/../admin/secrets` reads as a Matrix path right up until something joins it to a
    /// homeserver, at which point it is `/admin/secrets`. The check and the fetch were looking at
    /// two different things. `%2e%2e` is the same trick spelled differently — the URL spec treats
    /// it as a dot segment too, so a check that only looked for literal dots would have missed it.
    #[tokio::test]
    async fn a_path_may_not_climb_out_of_the_matrix_api() {
        let upstreams = Upstreams::new(None, Some(Allowed::Anywhere)).unwrap();
        for path in [
            "/_matrix/../admin/secrets",
            "/_matrix/client/../../admin",
            "/_matrix/%2e%2e/admin",
            "/_matrix/%2E%2E/admin",
            "/_matrix/./../admin",
            "/.well-known/matrix/../../admin",
        ] {
            assert_eq!(
                upstreams
                    .resolve(Some("https://example.org"), path)
                    .await
                    .unwrap_err(),
                Refusal::NotMatrix,
                "{path} climbs out and must be refused"
            );
        }
    }

    /// `//elsewhere/…` is not a path at all: joined to a base it names another host. It is refused
    /// as an origin nobody allowed, which is what it is.
    #[tokio::test]
    async fn a_protocol_relative_path_may_not_change_the_host() {
        let upstreams = Upstreams::new(None, Some(Allowed::Anywhere)).unwrap();
        assert_eq!(
            upstreams
                .resolve(
                    Some("https://example.org"),
                    "//elsewhere.example/_matrix/client/versions"
                )
                .await
                .unwrap_err(),
            Refusal::NotAllowed
        );
    }

    /// Dots inside a segment are not dot segments. Room aliases and event ids carry all sorts of
    /// punctuation, and a fix that refused every `..` anywhere in the path would break them.
    #[tokio::test]
    async fn dots_inside_a_segment_are_left_alone() {
        let upstreams = Upstreams::new(None, Some(only(&["example.org"]))).unwrap();
        let resolved = upstreams
            .resolve(
                Some("https://example.org"),
                "/_matrix/client/v3/rooms/%23foo..bar:example.org/state",
            )
            .await
            .unwrap();
        assert_eq!(
            resolved.path(),
            "/_matrix/client/v3/rooms/%23foo..bar:example.org/state"
        );
    }

    /// What comes back is the whole request, query and all — the forwarder does no joining of its
    /// own any more, so anything lost here is lost for good.
    #[tokio::test]
    async fn the_query_string_survives() {
        let upstreams = Upstreams::new(None, Some(only(&["example.org"]))).unwrap();
        let resolved = upstreams
            .resolve(Some("https://example.org"), "/_matrix/client/v3/sync?timeout=0")
            .await
            .unwrap();
        assert_eq!(resolved.as_str(), "https://example.org/_matrix/client/v3/sync?timeout=0");
    }

    #[tokio::test]
    async fn an_open_bridge_is_not_a_window_onto_the_operators_network() {
        let upstreams = Upstreams::new(None, Some(Allowed::Anywhere)).unwrap();
        for target in [
            "http://127.0.0.1:8080",
            "http://localhost",
            "http://192.168.1.1",
            "http://10.0.0.1",
            "http://169.254.169.254",
            "http://[::1]",
            "http://[fd00::1]",
            "http://box.internal",
        ] {
            assert_eq!(
                upstreams.resolve(Some(target), PATH).await.unwrap_err(),
                Refusal::NotPublic,
                "{target} should be refused"
            );
        }
    }

    /// A listed homeserver may legitimately be on the bridge's own network — an operator running
    /// both is the obvious case — and the operator saying so is what makes it allowed.
    #[tokio::test]
    async fn a_listed_private_homeserver_is_the_operators_business() {
        let upstreams = Upstreams::new(None, Some(only(&["http://10.0.0.5:8008"]))).unwrap();
        let resolved = upstreams
            .resolve(Some("http://10.0.0.5:8008"), PATH)
            .await
            .unwrap();
        assert_eq!(origin_of(&resolved), "http://10.0.0.5:8008");
    }

    #[tokio::test]
    async fn only_http_and_https() {
        let upstreams = Upstreams::new(None, Some(Allowed::Anywhere)).unwrap();
        for target in ["file:///etc/passwd", "ftp://example.org", "gopher://x"] {
            let refusal = upstreams.resolve(Some(target), PATH).await.unwrap_err();
            assert!(
                matches!(refusal, Refusal::BadOrigin | Refusal::NotAUrl),
                "{target} gave {refusal}"
            );
        }
    }

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
    }

    #[test]
    fn a_bridge_that_may_go_nowhere_will_not_start() {
        assert!(Upstreams::new(None, None).is_err());
    }

    #[test]
    fn a_default_the_list_refuses_will_not_start() {
        let error = Upstreams::new(Some(url("https://matrix.org")), Some(only(&["other.example"])))
            .unwrap_err();
        assert!(error.to_string().contains("ALLOWED_UPSTREAMS"));
    }
}
