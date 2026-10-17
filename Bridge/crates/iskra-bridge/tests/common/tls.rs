//! A homeserver with real TLS, for a blind stream to carry ciphertext to.
//!
//! Not a homeserver at all, of course: just enough HTTP/1.1 over rustls to answer the questions
//! the blind tests ask, with a certificate made fresh per run for `localhost`. What matters is
//! that the TLS is real, so that whatever the bridge carries is genuinely unreadable to it.

use std::sync::{Arc, Mutex};

use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub struct TlsServer {
    pub port: u16,
    pub cert: CertificateDer<'static>,
    /// Every request as it arrived, head and body, in the clear — on the far side of the TLS.
    pub requests: Arc<Mutex<Vec<Vec<u8>>>>,
}

/// The body `/big/<n>` answers with: not one repeated byte, so a misordered stream shows.
pub fn pattern(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i % 251) as u8).collect()
}

impl TlsServer {
    pub async fn start() -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let made = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let cert = made.cert.der().clone();
        let key = PrivateKeyDer::Pkcs8(made.signing_key.serialize_der().into());
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert.clone()], key)
            .unwrap();
        let acceptor = TlsAcceptor::from(Arc::new(config));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&requests);
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = listener.accept().await else {
                    return;
                };
                let acceptor = acceptor.clone();
                let log = Arc::clone(&log);
                tokio::spawn(async move {
                    if let Ok(tls) = acceptor.accept(tcp).await {
                        serve(tls, log).await;
                    }
                });
            }
        });
        Self {
            port,
            cert,
            requests,
        }
    }

    /// Another handle on the same server, for tasks that outlive a borrow of the harness.
    pub fn clone_handle(&self) -> Self {
        Self {
            port: self.port,
            cert: self.cert.clone(),
            requests: Arc::clone(&self.requests),
        }
    }

    pub fn reqwest_root(&self) -> reqwest::Certificate {
        reqwest::Certificate::from_der(&self.cert).unwrap()
    }

    /// A TLS client that trusts this server and nobody else.
    pub fn connector(&self) -> TlsConnector {
        let mut roots = rustls::RootCertStore::empty();
        roots.add(self.cert.clone()).unwrap();
        let config = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        TlsConnector::from(Arc::new(config))
    }

    pub fn saw(&self, needle: &[u8]) -> bool {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .any(|request| request.windows(needle.len()).any(|w| w == needle))
    }
}

pub fn server_name(name: &str) -> ServerName<'static> {
    ServerName::try_from(name.to_string()).unwrap()
}

/// HTTP/1.1, keep-alive, `content-length` only:
/// - `GET /_matrix/client/versions` — a version list.
/// - `GET /big/<n>` — `n` bytes of [`pattern`].
/// - `POST /upload` — `{"got":<bytes>,"sum":<sum of bytes>}`.
/// - anything else — `200` with the body `secret-body-MARKER`, which no log may contain.
async fn serve<S: AsyncRead + AsyncWrite + Unpin>(mut tls: S, log: Arc<Mutex<Vec<Vec<u8>>>>) {
    let mut pending = Vec::new();
    loop {
        let head_end = loop {
            if let Some(end) = pending.windows(4).position(|w| w == b"\r\n\r\n") {
                break end + 4;
            }
            let mut buffer = [0u8; 16 * 1024];
            match tls.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(n) => pending.extend_from_slice(&buffer[..n]),
            }
        };
        let head = String::from_utf8_lossy(&pending[..head_end]).to_string();
        let length: usize = head
            .lines()
            .filter_map(|line| line.split_once(':'))
            .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
            .and_then(|(_, value)| value.trim().parse().ok())
            .unwrap_or(0);
        while pending.len() < head_end + length {
            let mut buffer = [0u8; 64 * 1024];
            match tls.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(n) => pending.extend_from_slice(&buffer[..n]),
            }
        }
        let request: Vec<u8> = pending.drain(..head_end + length).collect();
        let body = &request[head_end..];
        log.lock().unwrap().push(request.clone());

        let path = head.split(' ').nth(1).unwrap_or("/").to_string();
        let close = head.to_ascii_lowercase().contains("connection: close");
        let answer: Vec<u8> = if path == "/_matrix/client/versions" {
            br#"{"versions":["v1.11"]}"#.to_vec()
        } else if let Some(n) = path.strip_prefix("/big/") {
            pattern(n.parse().unwrap_or(0))
        } else if path == "/upload" {
            let sum: u64 = body.iter().map(|&b| b as u64).sum();
            format!(r#"{{"got":{},"sum":{sum}}}"#, body.len()).into_bytes()
        } else {
            b"secret-body-MARKER".to_vec()
        };
        let response_head = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n{}\r\n",
            answer.len(),
            if close { "connection: close\r\n" } else { "" }
        );
        if tls.write_all(response_head.as_bytes()).await.is_err()
            || tls.write_all(&answer).await.is_err()
        {
            return;
        }
        if close {
            let _ = tls.shutdown().await;
            return;
        }
    }
}
