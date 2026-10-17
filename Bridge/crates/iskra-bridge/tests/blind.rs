//! Protocol v2 end to end: a real relay, the real bridge, and a homeserver with real TLS.
//!
//! What these prove is the property the whole of `docs/BLIND-BRIDGE.md` is for: the bridge moves
//! somebody's TLS to the homeserver and back, and what it carried — the token, the path, the body —
//! reached the far side without the bridge ever holding it in a form it could read.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

use iskra_bridge::config::StreamLimits;
use iskra_bridge::upstream::{parse_origin, Allowed, Upstreams};
use iskra_bridge::Config;
use iskra_tunnel_probe::{Outcome, StreamClient, TunnelStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

mod common;
use common::tls::{pattern, server_name, TlsServer};
use common::Harness;

const TIMEOUT: Duration = Duration::from_secs(20);

fn listed(origins: &[String]) -> Upstreams {
    let set: BTreeSet<String> = origins.iter().map(|o| parse_origin(o).unwrap()).collect();
    Upstreams::new(None, Some(Allowed::These(set))).unwrap()
}

/// A blind-only bridge that serves the TLS server and nothing else.
async fn blind_bridge(server: &TlsServer, tweak: impl FnOnce(Config) -> Config) -> Harness {
    let origin = format!("https://localhost:{}", server.port);
    Harness::start_with(move |config| {
        tweak(Config {
            upstreams: listed(&[origin]),
            blind_only: true,
            ..config
        })
    })
    .await
}

async fn open_bridge() -> Harness {
    Harness::start_with(|config| Config {
        upstreams: Upstreams::new(None, Some(Allowed::Anywhere)).unwrap(),
        blind_only: true,
        ..config
    })
    .await
}

/// One HTTP/1.1 request over TLS over a stream, `Connection: close`, and the whole answer.
async fn https(
    server: &TlsServer,
    stream: TunnelStream,
    name: &str,
    request: &[u8],
) -> (Vec<u8>, Outcome) {
    let TunnelStream { io, outcome } = stream;
    let mut tls = tokio::time::timeout(TIMEOUT, server.connector().connect(server_name(name), io))
        .await
        .expect("handshake in time")
        .expect("handshake");
    tls.write_all(request).await.unwrap();
    let mut answer = Vec::new();
    tokio::time::timeout(TIMEOUT, tls.read_to_end(&mut answer))
        .await
        .expect("answer in time")
        .expect("answer");
    let _ = tls.shutdown().await;
    drop(tls);
    let outcome = tokio::time::timeout(TIMEOUT, outcome)
        .await
        .expect("the stream ends")
        .expect("an outcome");
    (answer, outcome)
}

fn body_of(response: &[u8]) -> &[u8] {
    let end = response
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("a head")
        + 4;
    &response[end..]
}

/// The thing all of this is for. The token goes in, the homeserver reads it, the answer comes
/// back, and the stream closes in order.
#[tokio::test]
async fn a_request_goes_through_inside_tls() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;

    let request = b"GET /_matrix/client/v3/sync HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer syt_token_MARKER\r\nConnection: close\r\n\r\n";
    let stream = client.open("localhost", server.port);
    let (answer, outcome) = https(&server, stream, "localhost", request).await;

    assert!(
        answer.starts_with(b"HTTP/1.1 200"),
        "{}",
        String::from_utf8_lossy(&answer)
    );
    assert_eq!(body_of(&answer), b"secret-body-MARKER");
    assert!(
        server.saw(b"Bearer syt_token_MARKER"),
        "the homeserver read the token"
    );
    assert_eq!(outcome, Outcome::Closed);
}

/// The client closes its half first — what a kept-alive connection does when the pool lets it
/// go — and the host closes after. That is an orderly close, not a broken upstream.
#[tokio::test]
async fn the_client_closing_first_is_an_orderly_close() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;

    let TunnelStream { io, outcome } = client.open("localhost", server.port);
    let mut tls = server.connector().connect(server_name("localhost"), io).await.unwrap();
    tls.write_all(b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .unwrap();
    let expected = br#"{"versions":["v1.11"]}"#;
    let mut answer = Vec::new();
    while !answer.ends_with(expected) {
        let mut buffer = [0u8; 1024];
        let n = tls.read(&mut buffer).await.unwrap();
        assert!(n > 0, "the answer ended early");
        answer.extend_from_slice(&buffer[..n]);
    }
    tls.shutdown().await.unwrap();
    let mut rest = Vec::new();
    let _ = tokio::time::timeout(TIMEOUT, tls.read_to_end(&mut rest)).await;
    drop(tls);
    assert_eq!(
        tokio::time::timeout(TIMEOUT, outcome).await.unwrap().unwrap(),
        Outcome::Closed
    );
}

/// Three megabytes down is well over a hundred segments and many windows: it only arrives if
/// acknowledgements flow and the window reopens.
#[tokio::test]
async fn a_download_many_windows_long_arrives_whole_and_in_order() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;

    let size = 3 * 1024 * 1024;
    let request =
        format!("GET /big/{size} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let (answer, outcome) = https(
        &server,
        client.open("localhost", server.port),
        "localhost",
        request.as_bytes(),
    )
    .await;
    assert_eq!(body_of(&answer).len(), size);
    assert!(
        body_of(&answer) == pattern(size).as_slice(),
        "bytes out of order"
    );
    assert_eq!(outcome, Outcome::Closed);
}

/// And the other way: a photo going up.
#[tokio::test]
async fn an_upload_many_windows_long_arrives_whole() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;

    let body = pattern(2 * 1024 * 1024);
    let sum: u64 = body.iter().map(|&b| b as u64).sum();
    let mut request = format!(
        "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    request.extend_from_slice(&body);
    let (answer, outcome) = https(
        &server,
        client.open("localhost", server.port),
        "localhost",
        &request,
    )
    .await;
    assert_eq!(
        body_of(&answer),
        format!(r#"{{"got":{},"sum":{sum}}}"#, body.len()).as_bytes()
    );
    assert_eq!(outcome, Outcome::Closed);
}

/// reqwest — the HTTP client inside the Matrix SDK — pointed at an ordinary `http://` proxy, with
/// the secret in the URL, and the TLS its own. Several requests on one kept-alive connection,
/// because that is how the SDK uses it, and the bridge has to keep the stream for them.
#[tokio::test]
async fn reqwest_goes_through_the_connect_proxy_with_its_own_tls() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = Arc::new(harness.stream_client().await);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy_port = listener.local_addr().unwrap().port();
    tokio::spawn(Arc::clone(&client).serve_connect(listener, Some("s3cret".into())));

    let http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all(format!("http://iskra:s3cret@127.0.0.1:{proxy_port}")).unwrap())
        .add_root_certificate(server.reqwest_root())
        .timeout(TIMEOUT)
        .build()
        .unwrap();
    let base = format!("https://localhost:{}", server.port);
    for _ in 0..3 {
        let response = http
            .get(format!("{base}/_matrix/client/versions"))
            .bearer_auth("syt_reqwest_MARKER")
            .send()
            .await
            .expect("an answer");
        assert_eq!(response.status(), 200);
        assert_eq!(response.text().await.unwrap(), r#"{"versions":["v1.11"]}"#);
    }
    assert!(server.saw(b"Bearer syt_reqwest_MARKER"));
    assert_eq!(
        harness.bridge.open_streams(),
        1,
        "one kept-alive connection, one stream"
    );
}

/// Anything on the device can knock on a loopback port. Without the secret: 407, and no stream.
#[tokio::test]
async fn the_connect_proxy_wants_its_secret() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = Arc::new(harness.stream_client().await);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy_port = listener.local_addr().unwrap().port();
    tokio::spawn(Arc::clone(&client).serve_connect(listener, Some("s3cret".into())));

    for credentials in ["", "iskra:wrong@"] {
        let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", proxy_port))
            .await
            .unwrap();
        let auth = if credentials.is_empty() {
            String::new()
        } else {
            "Proxy-Authorization: Basic aXNrcmE6d3Jvbmc=\r\n".to_string()
        };
        socket
            .write_all(
                format!("CONNECT localhost:{} HTTP/1.1\r\n{auth}\r\n", server.port).as_bytes(),
            )
            .await
            .unwrap();
        let mut answer = vec![0; 256];
        let n = socket.read(&mut answer).await.unwrap();
        assert!(
            answer[..n].starts_with(b"HTTP/1.1 407"),
            "{}",
            String::from_utf8_lossy(&answer[..n])
        );
    }
    assert_eq!(harness.bridge.open_streams(), 0);
}

/// What a refused stream looks like from the client: an `rst` with the bridge's one word.
async fn refused(
    client: &StreamClient,
    host: &str,
    port: u16,
    tls_name: Option<&str>,
    server: &TlsServer,
) -> String {
    let TunnelStream { mut io, outcome } = client.open(host, port);
    match tls_name {
        Some(name) => {
            // The handshake fails — the bridge never connects — and that is the point.
            let _ =
                tokio::time::timeout(TIMEOUT, server.connector().connect(server_name(name), io))
                    .await;
        }
        None => {
            io.write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                .await
                .unwrap();
            let mut sink = Vec::new();
            let _ = tokio::time::timeout(TIMEOUT, io.read_to_end(&mut sink)).await;
        }
    }
    match tokio::time::timeout(TIMEOUT, outcome)
        .await
        .expect("an outcome in time")
        .expect("an outcome")
    {
        Outcome::Reset(reason) => reason,
        Outcome::Closed => panic!("{host}:{port} should have been refused"),
    }
}

#[tokio::test]
async fn an_unlisted_host_is_refused_by_name() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "example.org", 443, Some("example.org"), &server).await,
        "not allowed"
    );
    assert_eq!(
        refused(&client, "localhost", 22, Some("localhost"), &server).await,
        "bad port"
    );
}

/// The check that ties the host to the TLS: the name in the ClientHello is the host in `open`, or
/// the "Matrix server" checked is not the server talked to.
#[tokio::test]
async fn a_client_hello_for_another_name_is_refused() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(
            &client,
            "localhost",
            server.port,
            Some("example.org"),
            &server
        )
        .await,
        "sni mismatch"
    );
    assert_eq!(
        refused(
            &client,
            "localhost",
            server.port,
            Some("127.0.0.1"),
            &server
        )
        .await,
        "no sni"
    );
}

/// A blind bridge carries TLS and nothing else: plain HTTP in the clear is exactly what it must
/// not become a pipe for.
#[tokio::test]
async fn plain_text_is_not_carried() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "localhost", server.port, None, &server).await,
        "not tls"
    );
}

#[tokio::test]
async fn an_open_bridge_carries_443_to_public_addresses_only() {
    let server = TlsServer::start().await;
    let harness = open_bridge().await;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "matrix.org", 8443, Some("matrix.org"), &server).await,
        "bad port"
    );
    assert_eq!(
        refused(&client, "localhost", 443, Some("localhost"), &server).await,
        "not public"
    );
}

/// Over the per-client ceiling the answer is "busy", said out loud — not a stream that hangs.
#[tokio::test]
async fn past_the_stream_ceiling_the_bridge_says_busy() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |config| Config {
        streams: StreamLimits {
            per_client: 1,
            ..StreamLimits::default()
        },
        ..config
    })
    .await;
    let client = harness.stream_client().await;

    // The first one is up and held open.
    let TunnelStream {
        io,
        outcome: _first,
    } = client.open("localhost", server.port);
    let mut held = server
        .connector()
        .connect(server_name("localhost"), io)
        .await
        .expect("first stream");
    held.write_all(b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .unwrap();
    let mut buffer = [0u8; 256];
    let _ = held.read(&mut buffer).await.unwrap();

    assert_eq!(
        refused(
            &client,
            "localhost",
            server.port,
            Some("localhost"),
            &server
        )
        .await,
        "busy"
    );
}

/// `BLIND_ONLY`: a v1 request is not answered at all — the bridge does not even subscribe to them.
/// A token that never reaches the bridge is one nobody has to promise not to read.
#[tokio::test]
async fn a_blind_only_bridge_does_not_hear_v1() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |c| c).await;
    let v1 = harness.client().await;
    let result = v1
        .request(
            "GET",
            "/_matrix/client/versions",
            Some(&format!("https://localhost:{}", server.port)),
            BTreeMap::new(),
            Vec::new(),
            Duration::from_secs(3),
        )
        .await;
    assert!(result.is_err(), "a blind-only bridge answered v1");
}

/// And with v1 still on, both protocols are served side by side — the state an existing bridge
/// is in until its clients have moved.
#[tokio::test]
async fn without_blind_only_both_protocols_are_served() {
    let server = TlsServer::start().await;
    let harness = blind_bridge(&server, |config| Config {
        blind_only: false,
        ..config
    })
    .await;
    let client = harness.stream_client().await;
    let request =
        b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    let (answer, _) = https(
        &server,
        client.open("localhost", server.port),
        "localhost",
        request,
    )
    .await;
    assert_eq!(body_of(&answer), br#"{"versions":["v1.11"]}"#);
}
