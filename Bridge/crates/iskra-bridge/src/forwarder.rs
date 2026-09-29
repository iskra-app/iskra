//! The plain-HTTP half: a reconstructed request goes out to the real homeserver.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_proto::{HttpRequest, HttpResponse, Limits};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, AUTHORIZATION, CONTENT_TYPE, LOCATION};
use reqwest::{redirect, Method, StatusCode};
use url::Url;

use crate::upstream::Upstreams;

/// How many redirects one request may follow. reqwest's own default, kept.
const MAX_REDIRECTS: usize = 10;

/// Headers that describe *this* hop and must not be carried to the next one. Forwarding
/// `Transfer-Encoding` or `Content-Length` from a connection reqwest is about to frame itself is
/// how a proxy produces a response nobody can parse.
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
];

/// Headers a client must not be able to set on the homeserver's behalf. A homeserver behind a
/// reverse proxy believes the left-most `X-Forwarded-For`, so passing a client's own through would
/// let anyone on the bridge pick the address the homeserver rate-limits, bans and shows as "last
/// seen".
fn is_spoofable(name: &str) -> bool {
    name.starts_with("x-forwarded-")
        || name.starts_with("proxy-")
        || name == "forwarded"
        || name == "x-real-ip"
}

/// A reqwest error, told without its URL. `reqwest::Error`'s `Display` ends in `for url (…)` — the
/// whole path and query, room and event ids and sync positions included — and this is what the
/// listener logs on every timeout. The README promises no full paths in the log; this keeps it.
fn quiet(error: reqwest::Error) -> anyhow::Error {
    let kind = if error.is_timeout() {
        "timed out"
    } else if error.is_connect() {
        "could not connect"
    } else if error.is_body() || error.is_decode() {
        "broken body"
    } else {
        "request failed"
    };
    anyhow!("{kind}: {}", error.without_url())
}

pub struct Forwarder {
    http: reqwest::Client,
}

impl Forwarder {
    pub fn new(timeout: Duration) -> Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(timeout)
            // Redirects are followed by `forward`, not by reqwest: every hop has to pass the same
            // `Upstreams::resolve` the first URL did, and a reqwest policy cannot await it. Left to
            // reqwest, a homeserver — or on an open bridge, anybody's server — answering
            // `302 Location: http://169.254.169.254/…` had the bridge fetch that and hand the body
            // back: every rule about where the bridge goes, undone by one header.
            .redirect(redirect::Policy::none())
            // Nor does it take a proxy from the environment: where the bridge's traffic goes is
            // `ALLOWED_UPSTREAMS`, not whatever `HTTPS_PROXY` the host happens to have set.
            .no_proxy()
            // The bridge is the only thing in this design that talks TLS to the homeserver, so its
            // certificate checking stays on. There is no flag here to turn it off.
            .build()?;
        Ok(Self { http })
    }

    /// - `url` is the whole thing to fetch, as `Upstreams::resolve` built and judged it — host,
    ///   path and query, with any `..` already resolved.
    ///
    ///   The forwarder deliberately does no joining of its own. It used to take an origin and join
    ///   the client's path to it here, which meant the URL that was checked and the URL that was
    ///   fetched were built in two different places from two different pieces — and a path like
    ///   `/_matrix/../admin` passed the check as a string and became something else as a URL.
    ///   Whatever arrives here has already been resolved and judged as one object.
    ///
    /// - A redirect is followed here, one hop at a time, and each hop is judged by `upstreams` as
    ///   the first URL was. One that fails is not passed back as a 3xx: the SDK would follow it
    ///   itself, straight to the address and around the tunnel, which is the one thing a bridge
    ///   must never let happen quietly. It becomes an error, and the client gets a 502.
    ///
    /// - The body is read up to the 8 MB the client's reassembler accepts, and no further. Past
    ///   that the client throws it away anyway — after the bridge had held all of it in memory and
    ///   published it to every relay in 24 KiB pieces.
    pub async fn forward(
        &self,
        request: HttpRequest,
        url: &Url,
        upstreams: &Upstreams,
    ) -> Result<HttpResponse> {
        let mut method = Method::from_bytes(request.method.as_bytes())
            .map_err(|_| anyhow!("unusable method"))?;
        let mut url = url.clone();
        let mut body = request.body;

        let mut headers = HeaderMap::new();
        for (name, value) in &request.headers {
            let lower = name.to_ascii_lowercase();
            if HOP_BY_HOP.contains(&lower.as_str()) || is_spoofable(&lower) {
                continue;
            }
            let Ok(name) = HeaderName::from_bytes(lower.as_bytes()) else {
                continue;
            };
            let Ok(value) = HeaderValue::from_str(value) else {
                continue;
            };
            headers.insert(name, value);
        }

        let mut hops = 0;
        let mut response = loop {
            let response = self
                .http
                .request(method.clone(), url.clone())
                .headers(headers.clone())
                .body(body.clone())
                .send()
                .await
                .map_err(quiet)?;

            let Some(next) = redirect_target(&response, &url) else {
                break response;
            };
            hops += 1;
            if hops > MAX_REDIRECTS {
                return Err(anyhow!("too many redirects"));
            }
            let origin = next.origin().ascii_serialization();
            let path = match next.query() {
                Some(query) => format!("{}?{query}", next.path()),
                None => next.path().to_string(),
            };
            let next = upstreams
                .resolve(Some(origin.as_str()), &path)
                .await
                .map_err(|refusal| anyhow!("redirect refused: {}", refusal.as_str()))?;
            // reqwest's own rule, kept now that the following is done here: credentials go no
            // further than the origin they were written for.
            if next.origin() != url.origin() {
                headers.remove(AUTHORIZATION);
            }
            // 301, 302 and 303 turn anything but a GET or HEAD into a GET with no body, as
            // browsers and reqwest do; 307 and 308 repeat the request as it was.
            let rewrites = matches!(
                response.status(),
                StatusCode::MOVED_PERMANENTLY | StatusCode::FOUND | StatusCode::SEE_OTHER
            );
            if rewrites && method != Method::GET && method != Method::HEAD {
                method = Method::GET;
                body = Vec::new();
                headers.remove(CONTENT_TYPE);
            }
            url = next;
        };

        let status = response.status().as_u16();
        let mut out_headers = BTreeMap::new();
        for (name, value) in response.headers() {
            if HOP_BY_HOP.contains(&name.as_str()) {
                continue;
            }
            if let Ok(value) = value.to_str() {
                out_headers.insert(name.as_str().to_string(), value.to_string());
            }
        }

        let cap = Limits::default().max_bytes;
        if response
            .content_length()
            .is_some_and(|length| length > cap as u64)
        {
            return Err(anyhow!("response too large"));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(quiet)? {
            if body.len() + chunk.len() > cap {
                return Err(anyhow!("response too large"));
            }
            body.extend_from_slice(&chunk);
        }

        Ok(HttpResponse {
            id: request.id,
            status,
            headers: out_headers,
            body,
        })
    }
}

/// Where a redirect points, resolved against the URL that answered it — or `None` if this is not
/// a redirect the bridge follows. A 3xx with no usable `Location` (a 304, say) is an answer, and
/// goes back to the client as one.
fn redirect_target(response: &reqwest::Response, current: &Url) -> Option<Url> {
    if !matches!(
        response.status(),
        StatusCode::MOVED_PERMANENTLY
            | StatusCode::FOUND
            | StatusCode::SEE_OTHER
            | StatusCode::TEMPORARY_REDIRECT
            | StatusCode::PERMANENT_REDIRECT
    ) {
        return None;
    }
    let location = response.headers().get(LOCATION)?.to_str().ok()?;
    current.join(location).ok()
}
