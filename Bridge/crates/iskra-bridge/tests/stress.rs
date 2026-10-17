//! Load, for as long as you like, against relays and a homeserver that live in this process.
//!
//! Every test here is `#[ignore]`d, so `cargo test` stays a few seconds. Run them deliberately:
//!
//! ```sh
//! cargo test --release --test stress -- --ignored --nocapture
//! ```
//!
//! The heavy load belongs here rather than on public relays, and that is a deliberate line: a
//! volunteer-run relay owes us nothing, and thousands of events a minute from one pubkey is an
//! attack whatever we call it.

use std::sync::Arc;
use std::time::{Duration, Instant};

use iskra_bridge::config::StreamLimits;
use iskra_bridge::Config;
use iskra_tunnel_probe::{StreamClient, TunnelStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

mod common;
use common::tls::{pattern, server_name, TlsServer};
use common::Harness;

const TIMEOUT: Duration = Duration::from_secs(60);

fn roomy(config: Config) -> Config {
    Config {
        streams: StreamLimits {
            per_client: 1024,
            total: 4096,
            ..StreamLimits::default()
        },
        ..config
    }
}

fn report(label: &str, mut timings: Vec<Duration>) {
    timings.sort();
    let at = |p: f64| timings[((timings.len() as f64 - 1.0) * p).round() as usize];
    println!(
        "{label}: n={} · p50 {:?} · p95 {:?} · max {:?}",
        timings.len(),
        at(0.50),
        at(0.95),
        timings[timings.len() - 1]
    );
}

/// One download over its own stream; the time it took.
async fn download(client: &StreamClient, server: &TlsServer, size: usize) -> Duration {
    let started = Instant::now();
    let TunnelStream { io, outcome: _ } = client.open("localhost", server.port);
    let mut tls = server
        .connector()
        .connect(server_name("localhost"), io)
        .await
        .expect("handshake");
    tls.write_all(
        format!("GET /big/{size} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .as_bytes(),
    )
    .await
    .unwrap();
    let mut answer = Vec::new();
    tokio::time::timeout(TIMEOUT, tls.read_to_end(&mut answer))
        .await
        .expect("in time")
        .expect("answer");
    let body_start = answer.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    assert!(
        answer[body_start..] == pattern(size)[..],
        "bytes out of order"
    );
    started.elapsed()
}

/// Many streams at once from one client, every one of them whole.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn many_concurrent_streams_all_arrive_whole() {
    const STREAMS: usize = 64;
    let harness = Harness::start_with(roomy).await;
    let client = Arc::new(harness.stream_client().await);
    let server = Arc::new(harness.server.clone_handle());

    let mut tasks = Vec::new();
    for n in 0..STREAMS {
        let client = Arc::clone(&client);
        let server = Arc::clone(&server);
        tasks.push(tokio::spawn(async move {
            download(&client, &server, 64 * 1024 + n * 1000).await
        }));
    }
    let mut timings = Vec::new();
    for task in tasks {
        timings.push(task.await.expect("a stream"));
    }
    report("concurrent streams", timings);
}

/// Many clients, each its own key, each with one download.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn many_distinct_clients_are_all_served() {
    const CLIENTS: usize = 32;
    let harness = Harness::start_with(roomy).await;
    let server = Arc::new(harness.server.clone_handle());

    let mut tasks = Vec::new();
    for _ in 0..CLIENTS {
        let client = harness.stream_client().await;
        let server = Arc::clone(&server);
        tasks.push(tokio::spawn(async move {
            download(&client, &server, 256 * 1024).await
        }));
    }
    let mut timings = Vec::new();
    for task in tasks {
        timings.push(task.await.expect("a client"));
    }
    report("distinct clients", timings);
}

/// Big in both directions on one stream, several times over.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn large_downloads_one_after_another() {
    let harness = Harness::start_with(roomy).await;
    let client = harness.stream_client().await;
    let mut timings = Vec::new();
    for _ in 0..5 {
        timings.push(download(&client, &harness.server, 8 * 1024 * 1024).await);
    }
    report("8 MiB downloads", timings);
}
