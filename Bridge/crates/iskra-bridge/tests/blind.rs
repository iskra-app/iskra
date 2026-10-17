//! The tunnel end to end: real relays, the real bridge, and a homeserver with real TLS.
//!
//! What these prove is the property the whole of `docs/BLIND-BRIDGE.md` is for: the bridge moves
//! somebody's TLS to the homeserver and back, and what it carried — the token, the path, the body —
//! reached the far side without the bridge ever holding it in a form it could read.

use std::sync::Arc;
use std::time::Duration;

use iskra_bridge::config::StreamLimits;
use iskra_bridge::upstream::{Allowed, Upstreams};
use iskra_bridge::Config;
use iskra_tunnel_probe::{Outcome, StreamClient, TunnelStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

mod common;
use common::tls::{pattern, server_name, TlsServer};
use common::Harness;
use nostr_sdk::prelude::Keys;

const TIMEOUT: Duration = Duration::from_secs(20);

async fn open_bridge() -> Harness {
    Harness::start_with(|config| Config {
        upstreams: Upstreams::new(Allowed::Anywhere).unwrap(),
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
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;

    let request = b"GET /_matrix/client/v3/sync HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer syt_token_MARKER\r\nConnection: close\r\n\r\n";
    let stream = client.open("localhost", server.port);
    let (answer, outcome) = https(server, stream, "localhost", request).await;

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
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;

    let TunnelStream { io, outcome } = client.open("localhost", server.port);
    let mut tls = server
        .connector()
        .connect(server_name("localhost"), io)
        .await
        .unwrap();
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
        tokio::time::timeout(TIMEOUT, outcome)
            .await
            .unwrap()
            .unwrap(),
        Outcome::Closed
    );
}

/// Three megabytes down is well over a hundred segments and many windows: it only arrives if
/// acknowledgements flow and the window reopens.
#[tokio::test]
async fn a_download_many_windows_long_arrives_whole_and_in_order() {
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;

    let size = 3 * 1024 * 1024;
    let request =
        format!("GET /big/{size} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let (answer, outcome) = https(
        server,
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
    let harness = Harness::start().await;
    let server = &harness.server;
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
        server,
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
    let harness = Harness::start().await;
    let server = &harness.server;
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
    let harness = Harness::start().await;
    let server = &harness.server;
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
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "example.org", 443, Some("example.org"), server).await,
        "not allowed"
    );
    assert_eq!(
        refused(&client, "localhost", 22, Some("localhost"), server).await,
        "bad port"
    );
}

/// The check that ties the host to the TLS: the name in the ClientHello is the host in `open`, or
/// the "Matrix server" checked is not the server talked to.
#[tokio::test]
async fn a_client_hello_for_another_name_is_refused() {
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(
            &client,
            "localhost",
            server.port,
            Some("example.org"),
            server
        )
        .await,
        "sni mismatch"
    );
    assert_eq!(
        refused(&client, "localhost", server.port, Some("127.0.0.1"), server).await,
        "no sni"
    );
}

/// A blind bridge carries TLS and nothing else: plain HTTP in the clear is exactly what it must
/// not become a pipe for.
#[tokio::test]
async fn plain_text_is_not_carried() {
    let harness = Harness::start().await;
    let server = &harness.server;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "localhost", server.port, None, server).await,
        "not tls"
    );
}

#[tokio::test]
async fn an_open_bridge_carries_443_to_public_addresses_only() {
    let harness = open_bridge().await;
    let server = &harness.server;
    let client = harness.stream_client().await;
    assert_eq!(
        refused(&client, "matrix.org", 8443, Some("matrix.org"), server).await,
        "bad port"
    );
    assert_eq!(
        refused(&client, "localhost", 443, Some("localhost"), server).await,
        "not public"
    );
}

/// Over the per-client ceiling the answer is "busy", said out loud — not a stream that hangs.
#[tokio::test]
async fn past_the_stream_ceiling_the_bridge_says_busy() {
    let harness = Harness::start_with(|config| Config {
        streams: StreamLimits {
            per_client: 1,
            ..StreamLimits::default()
        },
        ..config
    })
    .await;
    let server = &harness.server;
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
        refused(&client, "localhost", server.port, Some("localhost"), server).await,
        "busy"
    );
}

/// A closed bridge: a key it was not told about gets nothing — not a refusal, nothing — and the
/// key it was told about is served by the same bridge.
#[tokio::test]
async fn a_client_outside_the_allow_list_gets_nothing() {
    let welcome = Keys::generate();
    let allowed = [welcome.public_key()].into_iter().collect();
    let harness = Harness::start_with(move |config| Config {
        allowed_pubkeys: Some(allowed),
        ..config
    })
    .await;
    let server = &harness.server;
    let request =
        b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    let stranger = harness.stream_client().await;
    let TunnelStream { io, outcome: _ } = stranger.open("localhost", server.port);
    let attempt = tokio::time::timeout(
        Duration::from_secs(3),
        server.connector().connect(server_name("localhost"), io),
    )
    .await;
    assert!(
        !matches!(attempt, Ok(Ok(_))),
        "a stranger must not be served"
    );

    let friend = harness.stream_client_with(welcome).await;
    let (answer, outcome) = https(
        server,
        friend.open("localhost", server.port),
        "localhost",
        request,
    )
    .await;
    assert_eq!(body_of(&answer), br#"{"versions":["v1.11"]}"#);
    assert_eq!(outcome, Outcome::Closed);
}

/// Right relay, right kind, right tag — sealed to a key this bridge does not hold. Dropped
/// quietly, and the loop goes on serving.
#[tokio::test]
async fn a_frame_sealed_for_another_bridge_is_ignored() {
    let harness = Harness::start().await;
    let server = &harness.server;
    let impostor = Keys::generate();
    let confused =
        StreamClient::connect(Keys::generate(), impostor.public_key(), &harness.relay_urls)
            .await
            .unwrap();
    let TunnelStream { io, outcome: _ } = confused.open("localhost", server.port);
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        server.connector().connect(server_name("localhost"), io),
    )
    .await;

    let client = harness.stream_client().await;
    let request =
        b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    let (answer, _) = https(
        server,
        client.open("localhost", server.port),
        "localhost",
        request,
    )
    .await;
    assert_eq!(body_of(&answer), br#"{"versions":["v1.11"]}"#);
}

/// One stream on three relays is **one** connection to the homeserver.
///
/// Every relay delivers its own copy of every frame. What keeps that from becoming three TLS
/// handshakes — three sign-ins, three devices — is nostr-sdk's default database remembering the id
/// of every event seen, ephemeral ones included, and the bridge's tombstones for streams that are
/// over. The first is somebody else's default and could change in a minor version without a word;
/// this pins both.
#[tokio::test]
async fn a_stream_on_several_relays_reaches_the_homeserver_once() {
    let harness = Harness::start_on(3, |config| config).await;
    let server = &harness.server;
    let client = harness.stream_client().await;
    let request = b"POST /_matrix/client/v3/login HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
    let (answer, outcome) = https(
        server,
        client.open("localhost", server.port),
        "localhost",
        request,
    )
    .await;
    assert_eq!(body_of(&answer), b"secret-body-MARKER");
    assert_eq!(outcome, Outcome::Closed);

    // Long enough for the slowest relay's copies to have arrived and been dealt with.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(server.requests.lock().unwrap().len(), 1);
}

/// A relay that is down must not hold anything up.
///
/// The lesson of the protocol before this one: `send_event` returns only when every relay has
/// acknowledged or timed out — ten seconds for one that is down — and frames sent one after another
/// each waited out the dead relay. A hundred segments behind a dead relay would be a quarter of an
/// hour. `ws://127.0.0.1:1` is refused on connect, which leaves nostr-sdk retrying it: the state a
/// public relay answering `502` to the handshake is in.
#[tokio::test]
async fn a_dead_relay_does_not_hold_up_a_download() {
    let harness = Harness::start_with(|mut config| {
        config.relays.push("ws://127.0.0.1:1".into());
        config
    })
    .await;
    let server = &harness.server;
    let mut relays = harness.relay_urls.clone();
    relays.push("ws://127.0.0.1:1".into());
    let client = StreamClient::connect(Keys::generate(), harness.bridge.public_key(), &relays)
        .await
        .unwrap()
        .with_pow(common::TEST_POW_BITS);

    let size = 1024 * 1024;
    let request =
        format!("GET /big/{size} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let started = std::time::Instant::now();
    let (answer, outcome) = https(
        server,
        client.open("localhost", server.port),
        "localhost",
        request.as_bytes(),
    )
    .await;
    assert_eq!(body_of(&answer).len(), size);
    assert_eq!(outcome, Outcome::Closed);
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "a megabyte took {:?} with a dead relay in the list",
        started.elapsed()
    );
}

/// An `open` with too little work is turned away with the difficulty in the refusal, and the next
/// one is mined to it and goes through. This is how a bridge under attack raises the price without
/// an app update: the client learns it from the first refusal.
#[tokio::test]
async fn too_little_work_is_refused_with_the_price_and_the_next_open_pays_it() {
    let harness = Harness::start_with(|config| Config {
        pow_bits: 10,
        ..config
    })
    .await;
    let server = &harness.server;
    let client = harness.stream_client().await.with_pow(0);

    let reason = refused(&client, "localhost", server.port, Some("localhost"), server).await;
    assert_eq!(reason, "pow 10");
    assert_eq!(client.pow_bits(), 10, "the client took the price from the refusal");

    let request = b"GET /_matrix/client/versions HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    let (answer, outcome) = https(server, client.open("localhost", server.port), "localhost", request).await;
    assert_eq!(body_of(&answer), br#"{"versions":["v1.11"]}"#);
    assert_eq!(outcome, Outcome::Closed);
}
