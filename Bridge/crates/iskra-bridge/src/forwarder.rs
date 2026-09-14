//! The plain-HTTP half: a reconstructed request goes out to the real homeserver.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iskra_tunnel_proto::{HttpRequest, HttpResponse};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::Method;
use url::Url;

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

pub struct Forwarder {
    http: reqwest::Client,
}

impl Forwarder {
    pub fn new(timeout: Duration) -> Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(timeout)
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
    pub async fn forward(&self, request: HttpRequest, url: &Url) -> Result<HttpResponse> {
        let method = Method::from_bytes(request.method.as_bytes())
            .map_err(|_| anyhow!("unusable method"))?;
        let url = url.clone();

        let mut headers = HeaderMap::new();
        for (name, value) in &request.headers {
            let lower = name.to_ascii_lowercase();
            if HOP_BY_HOP.contains(&lower.as_str()) {
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

        let response = self
            .http
            .request(method, url)
            .headers(headers)
            .body(request.body)
            .send()
            .await?;

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
        let body = response.bytes().await?.to_vec();

        Ok(HttpResponse {
            id: request.id,
            status,
            headers: out_headers,
            body,
        })
    }
}
