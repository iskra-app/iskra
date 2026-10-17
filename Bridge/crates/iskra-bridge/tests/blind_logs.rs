//! The bridge's logs, at `trace`, after carrying a token, a password and a body: none of the three
//! are in them, and neither is the host.
//!
//! A test binary of its own because it installs the process-wide subscriber, and it records
//! everything — every crate, every level — so that "the bridge does not log it" means nothing in
//! the process logged it either, not only the lines the bridge itself writes.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iskra_bridge::upstream::{parse_origin, Allowed, Upstreams};
use iskra_bridge::Config;
use iskra_tunnel_probe::{Outcome, TunnelStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing_subscriber::fmt::MakeWriter;

mod common;
use common::tls::{server_name, TlsServer};
use common::Harness;

#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for Captured {
    type Writer = Captured;
    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

const TOKEN: &str = "syt_TOKEN_MARKER_a81f";
const PASSWORD: &str = "PASSWORD_MARKER_77c0";

#[tokio::test]
async fn trace_logs_hold_no_token_no_password_no_body_and_no_host() {
    let captured = Captured::default();
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .with_writer(captured.clone())
        .init();

    let server = TlsServer::start().await;
    let origin = parse_origin(&format!("https://localhost:{}", server.port)).unwrap();
    let harness = Harness::start_with(move |config| Config {
        upstreams: Upstreams::new(None, Some(Allowed::These([origin].into()))).unwrap(),
        blind_only: true,
        ..config
    })
    .await;
    let client = harness.stream_client().await;

    let body = format!(r#"{{"type":"m.login.password","password":"{PASSWORD}"}}"#);
    let request = format!(
        "POST /_matrix/client/v3/login HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let TunnelStream { io, outcome } = client.open("localhost", server.port);
    let mut tls = server
        .connector()
        .connect(server_name("localhost"), io)
        .await
        .unwrap();
    tls.write_all(request.as_bytes()).await.unwrap();
    let mut answer = Vec::new();
    tls.read_to_end(&mut answer).await.unwrap();
    drop(tls);
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(20), outcome)
            .await
            .unwrap()
            .unwrap(),
        Outcome::Closed
    );
    // The close is logged by the stream's task as it ends; give it the moment it takes.
    tokio::time::sleep(Duration::from_millis(300)).await;

    assert!(
        server.saw(TOKEN.as_bytes()) && server.saw(PASSWORD.as_bytes()),
        "it went through"
    );
    assert!(answer.ends_with(b"secret-body-MARKER"));

    let logs = String::from_utf8(captured.0.lock().unwrap().clone()).unwrap();
    assert!(logs.contains("stream closed"), "the bridge did log, at all");
    for marker in [
        TOKEN,
        PASSWORD,
        "secret-body-MARKER",
        "/_matrix/client/v3/login",
    ] {
        assert!(!logs.contains(marker), "{marker} is in the logs");
    }
    // The host is the one thing the bridge must know, and still it does not write it down next to
    // anybody's traffic. (The startup line lists the operator's own configuration, which is the
    // operator's to read; the lines about streams are about somebody.)
    let stream_lines: Vec<&str> = logs
        .lines()
        .filter(|line| {
            line.contains("iskra_bridge::stream") || line.contains("iskra_bridge::blind")
        })
        .collect();
    assert!(!stream_lines.is_empty());
    for line in stream_lines {
        assert!(
            !line.contains("localhost"),
            "the host is in a bridge log line: {line}"
        );
    }
}
