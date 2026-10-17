//! Where a blind stream may go.
//!
//! In v1 `upstream.rs` decides this from the request: the path must be under `/_matrix/`, the
//! address public, the origin listed. A blind bridge never sees a path, so "is this Matrix" moves
//! from the request to the **host**, and the rules become these:
//!
//! - **Port 443 only**, unless the operator listed a host with another port. An open 25 or 22 is
//!   what gets an operator's server switched off by the hosting company.
//! - **Listed hosts only**, when `ALLOWED_UPSTREAMS` is a list. An operator who names their
//!   homeservers has vouched for them, private address and all, as in v1.
//! - **On an open bridge, public addresses only** — every address the name resolves to, not just
//!   the first — and **only hosts that answer like a Matrix server**, asked by the bridge itself
//!   over real TLS, on the very addresses it will then connect to.
//!
//! What this does and does not achieve is worth being exact about. It keeps *other people's* sites
//! from receiving traffic through the bridge — spam, scraping, attacks, everything an operator would
//! answer for. It does not stop somebody who runs their own "homeserver" that answers `/versions`
//! from reaching it through the bridge with any TLS they like. That is not a hole; it is the limit
//! of the method, and getting people to their own server is what the bridge is for.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};

use iskra_tunnel_proto::reason;
use url::Url;

use crate::sni::normalise;
use crate::upstream::{is_global, is_local_name, Upstreams};

/// The one port an open bridge carries.
pub const HTTPS_PORT: u16 = 443;

/// How long a host's answer to "are you Matrix" is believed.
const MATRIX_YES_FOR: Duration = Duration::from_secs(24 * 60 * 60);
const MATRIX_NO_FOR: Duration = Duration::from_secs(10 * 60);
/// Most hosts remembered. Past this the memory is dropped whole, as `reassemble`'s refusals are:
/// forgetting only costs a second probe.
const MAX_REMEMBERED: usize = 4096;
/// How long the probe waits for a host to answer, and how much of the answer it reads.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const PROBE_MAX_BODY: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    BadPort,
    NotAllowed,
    NotPublic,
    NoSuchHost,
    NotMatrix,
}

impl Refusal {
    /// The `rst` reason, which is also what goes in the log — one word, no host.
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::BadPort => reason::BAD_PORT,
            Refusal::NotAllowed => reason::NOT_ALLOWED,
            Refusal::NotPublic => reason::NOT_PUBLIC,
            Refusal::NoSuchHost => reason::NO_SUCH_HOST,
            Refusal::NotMatrix => reason::NOT_MATRIX,
        }
    }
}

enum Rule {
    /// `(host, port)`, from the `https` origins in `ALLOWED_UPSTREAMS` (or `HOMESERVER_URL`).
    Listed(HashSet<(String, u16)>),
    Anywhere,
}

pub struct Destinations {
    rule: Rule,
    probe: MatrixProbe,
}

impl Destinations {
    /// The same list v1 serves, read as hosts. Only `https` origins count: a stream is somebody's
    /// own TLS, and an `http` homeserver has none for the bridge to be blind to.
    pub fn new(upstreams: &Upstreams) -> Self {
        Self::with_probe(upstreams, MatrixProbe::new(Vec::new()))
    }

    pub fn with_probe(upstreams: &Upstreams, probe: MatrixProbe) -> Self {
        let rule = if upstreams.is_open() {
            Rule::Anywhere
        } else {
            Rule::Listed(
                upstreams
                    .listed()
                    .iter()
                    .filter_map(|origin| Url::parse(origin).ok())
                    .filter(|url| url.scheme() == "https")
                    .filter_map(|url| {
                        Some((normalise(url.host_str()?), url.port_or_known_default()?))
                    })
                    .collect(),
            )
        };
        Self { rule, probe }
    }

    /// The addresses to connect to, or why not.
    ///
    /// **The caller connects to exactly these.** Resolving the name a second time to connect would
    /// be DNS rebinding handed over on a plate: the check would have been about one address and
    /// the connection made to another.
    pub async fn admit(&self, host: &str, port: u16) -> Result<Vec<SocketAddr>, Refusal> {
        let host = normalise(host);
        match &self.rule {
            Rule::Listed(list) => {
                if !list.contains(&(host.clone(), port)) {
                    return Err(if port == HTTPS_PORT {
                        Refusal::NotAllowed
                    } else {
                        Refusal::BadPort
                    });
                }
            }
            Rule::Anywhere => {
                if port != HTTPS_PORT {
                    return Err(Refusal::BadPort);
                }
                if is_local_name(&host) {
                    return Err(Refusal::NotPublic);
                }
            }
        }

        let addresses: Vec<SocketAddr> = match tokio::net::lookup_host((host.as_str(), port)).await
        {
            Ok(resolved) => resolved.collect(),
            Err(_) => return Err(Refusal::NoSuchHost),
        };
        if addresses.is_empty() {
            return Err(Refusal::NoSuchHost);
        }

        if let Rule::Anywhere = self.rule {
            // One private address among public ones is enough to refuse the lot: which of them a
            // connection lands on is not the client's to choose, and so not the client's excuse.
            if !addresses.iter().all(|address| is_global(&address.ip())) {
                return Err(Refusal::NotPublic);
            }
            // Only the addresses that themselves answered as Matrix are handed back, and so only
            // they are connected to.
            let confirmed = self.probe.matrix_addresses(&host, &addresses).await;
            if confirmed.is_empty() {
                return Err(Refusal::NotMatrix);
            }
            return Ok(confirmed);
        }
        Ok(addresses)
    }
}

/// Asks a host whether it is a Matrix server, and remembers the answer — **per address**.
///
/// Remembered per name alone, the answer could be reused for addresses that never gave it: a name
/// answers "yes" from a server of its owner's, its DNS is then pointed at somebody else's public
/// address, and for a day the bridge carries raw TCP on 443 to that address. The client brings its
/// own TLS and need not check the certificate that comes back, so a certificate mismatch protects
/// nobody here. Keyed by `(name, address)`, a yes covers exactly the machine that said it.
pub struct MatrixProbe {
    /// Extra roots to trust, beyond the public ones. Empty in production; a test's own CA in tests.
    roots: Vec<reqwest::Certificate>,
    remembered: StdMutex<HashMap<(String, SocketAddr), (bool, Instant)>>,
}

impl MatrixProbe {
    pub fn new(roots: Vec<reqwest::Certificate>) -> Self {
        Self {
            roots,
            remembered: StdMutex::new(HashMap::new()),
        }
    }

    /// The addresses among `addresses` that answer as a Matrix server for `host`: `GET
    /// /_matrix/client/versions` with a `versions` array, or `GET /.well-known/matrix/client` with
    /// `m.homeserver` — the second is what a delegating name like `matrix.org` serves, where the
    /// API itself lives elsewhere.
    ///
    /// Asked over the bridge's own TLS, certificate checked, one address at a time: each probe is
    /// pinned to its address, so the answer belongs to that machine. Probing stops at the first
    /// new yes — a name with eight addresses costs one probe, not eight — and the stream then goes
    /// only to addresses that have said yes.
    pub async fn matrix_addresses(&self, host: &str, addresses: &[SocketAddr]) -> Vec<SocketAddr> {
        let mut confirmed = Vec::new();
        let mut unknown = Vec::new();
        {
            let now = Instant::now();
            let remembered = self.remembered.lock().expect("probe memory");
            for address in addresses {
                match remembered.get(&(host.to_string(), *address)) {
                    Some(&(answer, when))
                        if now.duration_since(when)
                            < if answer { MATRIX_YES_FOR } else { MATRIX_NO_FOR } =>
                    {
                        if answer {
                            confirmed.push(*address);
                        }
                    }
                    _ => unknown.push(*address),
                }
            }
        }
        if !confirmed.is_empty() {
            return confirmed;
        }
        for address in unknown {
            let answer = self.ask(host, &[address]).await;
            let mut remembered = self.remembered.lock().expect("probe memory");
            if remembered.len() >= MAX_REMEMBERED {
                remembered.clear();
            }
            remembered.insert((host.to_string(), address), (answer, Instant::now()));
            if answer {
                confirmed.push(address);
                break;
            }
        }
        confirmed
    }

    /// Whether any of `addresses` answers as Matrix for `host`.
    pub async fn is_matrix(&self, host: &str, addresses: &[SocketAddr]) -> bool {
        !self.matrix_addresses(host, addresses).await.is_empty()
    }

    async fn ask(&self, host: &str, addresses: &[SocketAddr]) -> bool {
        let mut builder = reqwest::Client::builder()
            .resolve_to_addrs(host, addresses)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(PROBE_TIMEOUT);
        for root in &self.roots {
            builder = builder.add_root_certificate(root.clone());
        }
        let Ok(http) = builder.build() else {
            return false;
        };
        let port = addresses
            .first()
            .map(SocketAddr::port)
            .unwrap_or(HTTPS_PORT);
        let base = format!("https://{host}:{port}");

        if let Some(json) = fetch_json(&http, &format!("{base}/_matrix/client/versions")).await {
            if json
                .get("versions")
                .is_some_and(serde_json::Value::is_array)
            {
                return true;
            }
        }
        if let Some(json) = fetch_json(&http, &format!("{base}/.well-known/matrix/client")).await {
            if json
                .get("m.homeserver")
                .is_some_and(serde_json::Value::is_object)
            {
                return true;
            }
        }
        false
    }
}

async fn fetch_json(http: &reqwest::Client, url: &str) -> Option<serde_json::Value> {
    let mut response = http.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if body.len() + chunk.len() > PROBE_MAX_BODY {
            return None;
        }
        body.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&body).ok()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::sync::Arc;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;
    use crate::upstream::{parse_origin, Allowed};

    fn listed(origins: &[&str]) -> Upstreams {
        let set: BTreeSet<String> = origins.iter().map(|o| parse_origin(o).unwrap()).collect();
        Upstreams::new(None, Some(Allowed::These(set))).unwrap()
    }

    fn open() -> Upstreams {
        Upstreams::new(None, Some(Allowed::Anywhere)).unwrap()
    }

    #[tokio::test]
    async fn a_listed_host_on_its_port_is_admitted_private_or_not() {
        let destinations = Destinations::new(&listed(&["https://localhost:8448"]));
        let addresses = destinations.admit("LOCALHOST.", 8448).await.unwrap();
        assert!(addresses
            .iter()
            .all(|a| a.ip().is_loopback() && a.port() == 8448));
    }

    #[tokio::test]
    async fn an_unlisted_host_is_not_allowed_and_an_unlisted_port_is_a_bad_port() {
        let destinations = Destinations::new(&listed(&["matrix.org"]));
        assert_eq!(
            destinations.admit("example.org", 443).await,
            Err(Refusal::NotAllowed)
        );
        assert_eq!(
            destinations.admit("matrix.org", 22).await,
            Err(Refusal::BadPort)
        );
    }

    /// An `http` homeserver has no TLS for the bridge to be blind to, so it is no stream target.
    #[tokio::test]
    async fn an_http_origin_is_not_a_stream_target() {
        let destinations = Destinations::new(&listed(&["http://localhost:8008"]));
        assert_eq!(
            destinations.admit("localhost", 8008).await,
            Err(Refusal::BadPort)
        );
    }

    #[tokio::test]
    async fn an_open_bridge_carries_443_and_nothing_else() {
        let destinations = Destinations::new(&open());
        for port in [22, 25, 80, 8443, 8448] {
            assert_eq!(
                destinations.admit("matrix.org", port).await,
                Err(Refusal::BadPort)
            );
        }
    }

    #[tokio::test]
    async fn an_open_bridge_is_not_a_window_onto_the_operators_network() {
        let destinations = Destinations::new(&open());
        for host in [
            "localhost",
            "box.internal",
            "127.0.0.1",
            "10.0.0.1",
            "169.254.169.254",
            "::1",
        ] {
            assert_eq!(
                destinations.admit(host, 443).await,
                Err(Refusal::NotPublic),
                "{host}"
            );
        }
    }

    // ---- The probe, against a TLS server of the test's own. ----

    /// A TLS server for `localhost` that answers every request with `status` and `body`, and
    /// counts how many it was asked.
    async fn server(
        status: u16,
        path: &'static str,
        body: &'static str,
    ) -> (
        SocketAddr,
        reqwest::Certificate,
        Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let der = cert.cert.der().clone();
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(cert.signing_key.serialize_der().into());
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![der.clone()], key)
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let asked = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = Arc::clone(&asked);
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = listener.accept().await else {
                    return;
                };
                let acceptor = acceptor.clone();
                let counter = Arc::clone(&counter);
                tokio::spawn(async move {
                    let Ok(mut tls) = acceptor.accept(tcp).await else {
                        return;
                    };
                    let mut request = vec![0; 4096];
                    let Ok(n) = tls.read(&mut request).await else {
                        return;
                    };
                    counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let head = String::from_utf8_lossy(&request[..n]);
                    let (status, body) = if head.starts_with(&format!("GET {path} ")) {
                        (status, body)
                    } else {
                        (404, "{}")
                    };
                    let response = format!(
                        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = tls.write_all(response.as_bytes()).await;
                    let _ = tls.shutdown().await;
                });
            }
        });
        (
            address,
            reqwest::Certificate::from_der(&der).unwrap(),
            asked,
        )
    }

    #[tokio::test]
    async fn a_host_that_lists_versions_is_matrix() {
        let (address, root, _) =
            server(200, "/_matrix/client/versions", r#"{"versions":["v1.11"]}"#).await;
        assert!(
            MatrixProbe::new(vec![root])
                .is_matrix("localhost", &[address])
                .await
        );
    }

    #[tokio::test]
    async fn a_delegating_host_with_only_well_known_is_matrix() {
        let (address, root, _) = server(
            200,
            "/.well-known/matrix/client",
            r#"{"m.homeserver":{"base_url":"https://matrix-client.matrix.org"}}"#,
        )
        .await;
        assert!(
            MatrixProbe::new(vec![root])
                .is_matrix("localhost", &[address])
                .await
        );
    }

    #[tokio::test]
    async fn a_web_site_is_not_matrix() {
        let (address, root, _) = server(200, "/", "<html></html>").await;
        assert!(
            !MatrixProbe::new(vec![root])
                .is_matrix("localhost", &[address])
                .await
        );
    }

    /// JSON that merely mentions the word is not an answer.
    #[tokio::test]
    async fn versions_that_are_not_a_list_are_not_matrix() {
        let (address, root, _) =
            server(200, "/_matrix/client/versions", r#"{"versions":"yes"}"#).await;
        assert!(
            !MatrixProbe::new(vec![root])
                .is_matrix("localhost", &[address])
                .await
        );
    }

    /// The probe trusts real certificates only: a host it cannot verify is not a Matrix server as
    /// far as the bridge is concerned.
    #[tokio::test]
    async fn a_certificate_the_bridge_cannot_verify_is_not_matrix() {
        let (address, _, _) =
            server(200, "/_matrix/client/versions", r#"{"versions":["v1.11"]}"#).await;
        assert!(
            !MatrixProbe::new(Vec::new())
                .is_matrix("localhost", &[address])
                .await
        );
    }

    /// The case the per-address memory exists for: a yes from one machine is no licence for
    /// another address the same name later points at.
    #[tokio::test]
    async fn a_yes_covers_the_address_that_gave_it_and_no_other() {
        let (matrix, root, _) = server(200, "/_matrix/client/versions", r#"{"versions":[]}"#).await;
        let (website, _, asked) = server(200, "/", "<html></html>").await;
        let probe = MatrixProbe::new(vec![root]);
        assert_eq!(probe.matrix_addresses("localhost", &[matrix]).await, vec![matrix]);
        // The name now resolves to the other machine as well: only the machine that said yes is
        // handed back.
        assert_eq!(probe.matrix_addresses("localhost", &[website, matrix]).await, vec![matrix]);
        // And to the other machine alone: it is asked itself, and it is not Matrix.
        assert!(probe.matrix_addresses("localhost", &[website]).await.is_empty());
        assert_eq!(asked.load(std::sync::atomic::Ordering::SeqCst), 0, "untrusted cert, no answer read");
    }

    #[tokio::test]
    async fn the_answer_is_remembered() {
        let (address, root, asked) =
            server(200, "/_matrix/client/versions", r#"{"versions":[]}"#).await;
        let probe = MatrixProbe::new(vec![root]);
        assert!(probe.is_matrix("localhost", &[address]).await);
        assert!(probe.is_matrix("localhost", &[address]).await);
        assert_eq!(asked.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}
