//! Load, for as long as you like, against a relay and a homeserver that live in this process.
//!
//! Every test here is `#[ignore]`d, so `cargo test` stays a few seconds. Run them deliberately:
//!
//! ```sh
//! cargo test --release --test stress -- --ignored --nocapture
//! SOAK_SECS=300 cargo test --release --test stress -- --ignored --nocapture soak
//! ```
//!
//! The heavy load belongs here rather than on public relays, and that is a deliberate line: a
//! volunteer-run relay owes us nothing, and thousands of requests a minute from one pubkey is an
//! attack whatever we call it. Against real relays we run one gentle minute; against this one we
//! run whatever we want.

use std::collections::BTreeMap;
use std::num::NonZeroU32;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use wiremock::matchers::{method, path};
use wiremock::{Mock, ResponseTemplate};

mod common;
use common::Harness;

const TIMEOUT: Duration = Duration::from_secs(30);

fn unlimited(mut config: iskra_bridge::Config) -> iskra_bridge::Config {
    config.rate_limit_per_min = NonZeroU32::new(1_000_000).unwrap();
    config
}

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    let index = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[index]
}

fn report(label: &str, mut timings: Vec<Duration>) {
    timings.sort();
    println!(
        "{label}: n={} · p50 {:?} · p95 {:?} · p99 {:?} · max {:?}",
        timings.len(),
        percentile(&timings, 0.50),
        percentile(&timings, 0.95),
        percentile(&timings, 0.99),
        timings.last().copied().unwrap_or_default(),
    );
}

/// Many requests, many at once, and every single one must come back.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn sustained_concurrent_load_answers_every_request() {
    const WORKERS: usize = 32;
    const PER_WORKER: usize = 100;

    let harness = Harness::start_with(unlimited).await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"versions":["v1.11"]}"#))
        .mount(&harness.homeserver)
        .await;

    let client = Arc::new(harness.client().await);
    let started = Instant::now();

    let mut workers = Vec::with_capacity(WORKERS);
    for _ in 0..WORKERS {
        let client = Arc::clone(&client);
        workers.push(tokio::spawn(async move {
            let mut timings = Vec::with_capacity(PER_WORKER);
            for _ in 0..PER_WORKER {
                let at = Instant::now();
                let response = client
                    .request(
                        "GET",
                        "/_matrix/client/versions",
                        None,
                        BTreeMap::new(),
                        Vec::new(),
                        TIMEOUT,
                    )
                    .await
                    .expect("every request is answered");
                assert_eq!(response.status, 200);
                timings.push(at.elapsed());
            }
            timings
        }));
    }

    let mut timings = Vec::new();
    for worker in workers {
        timings.extend(worker.await.expect("worker finished"));
    }
    let elapsed = started.elapsed();

    let total = WORKERS * PER_WORKER;
    assert_eq!(timings.len(), total);
    println!(
        "{total} requests across {WORKERS} workers in {elapsed:?} — {:.0} req/s",
        total as f64 / elapsed.as_secs_f64()
    );
    report("concurrent", timings);
}

/// The load arrives from many different keys rather than one.
///
/// This is the shape that grows the rate limiter's keyed state, and the shape a public bridge
/// actually sees.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn many_distinct_clients_are_all_served() {
    const CLIENTS: usize = 60;
    const PER_CLIENT: usize = 10;

    let harness = Harness::start_with(unlimited).await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let mut workers = Vec::with_capacity(CLIENTS);
    for _ in 0..CLIENTS {
        let client = harness.client().await;
        workers.push(tokio::spawn(async move {
            for _ in 0..PER_CLIENT {
                let response = client
                    .request(
                        "GET",
                        "/_matrix/client/versions",
                        None,
                        BTreeMap::new(),
                        Vec::new(),
                        TIMEOUT,
                    )
                    .await
                    .expect("served");
                assert_eq!(response.status, 200);
            }
        }));
    }

    for worker in workers {
        worker.await.expect("client finished");
    }
    println!("{CLIENTS} clients × {PER_CLIENT} requests all served");
}

/// A flood from one key is cut off, and the bridge is healthy on the other side of it.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn a_flood_from_one_key_is_cut_off_without_taking_the_bridge_down() {
    let harness = Harness::start_with(|mut config| {
        config.rate_limit_per_min = NonZeroU32::new(30).unwrap();
        config
    })
    .await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let flooder = Arc::new(harness.client().await);
    let served = Arc::new(AtomicUsize::new(0));

    let mut workers = Vec::new();
    for _ in 0..10 {
        let flooder = Arc::clone(&flooder);
        let served = Arc::clone(&served);
        workers.push(tokio::spawn(async move {
            for _ in 0..20 {
                let answered = flooder
                    .request(
                        "GET",
                        "/_matrix/client/versions",
                        None,
                        BTreeMap::new(),
                        Vec::new(),
                        Duration::from_secs(2),
                    )
                    .await
                    .is_ok();
                if answered {
                    served.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }
    for worker in workers {
        worker.await.expect("worker finished");
    }

    let served = served.load(Ordering::Relaxed);
    println!("200 requests attempted under a 30/min ceiling — {served} served");
    assert!(served > 0, "the limiter must not refuse everything");
    assert!(
        served <= 60,
        "the limiter let {served} through under a 30/min ceiling"
    );

    // A different key is unaffected by the flooder's exhausted bucket.
    let bystander = harness.client().await;
    let response = bystander
        .request(
            "GET",
            "/_matrix/client/versions",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("a bystander is still served");
    assert_eq!(response.status, 200);
}

/// Big bodies, in numbers, which is where chunking is either cheap or the whole thing is a toy.
///
/// Sizes climb past the chunk budget by a lot: 4 MB is 171 events for one answer. What this
/// watches for is a reassembler whose cost is quadratic in chunks, and a pool that loses one event
/// in two hundred — either of which is invisible at 200 KB and fatal at four megabytes.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn large_bodies_round_trip_in_both_directions() {
    let harness = Harness::start_with(unlimited).await;
    let sizes = [24 * 1024usize, 200_000, 1024 * 1024, 4 * 1024 * 1024];

    for size in sizes {
        Mock::given(method("GET"))
            .and(path(format!("/_matrix/client/size/{size}")))
            .respond_with(ResponseTemplate::new(200).set_body_string("y".repeat(size)))
            .mount(&harness.homeserver)
            .await;
    }

    let client = harness.client().await;
    for size in sizes {
        let started = Instant::now();
        let response = client
            .request(
                "GET",
                &format!("/_matrix/client/size/{size}"),
                None,
                BTreeMap::new(),
                Vec::new(),
                Duration::from_secs(120),
            )
            .await
            .unwrap_or_else(|error| panic!("a {size}-byte body: {error}"));
        assert_eq!(response.status, 200, "size {size}");
        assert_eq!(response.body.len(), size, "size {size}");
        println!(
            "{size:>9} bytes in {:>6} ms ({} chunks)",
            started.elapsed().as_millis(),
            size.div_ceil(24 * 1024)
        );
    }
}

/// Several big answers at once, which is the case the in-flight cap is about: each one holds its
/// chunks in memory until the last arrives, and they must not be assembled into each other.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn several_large_responses_at_once_do_not_mix() {
    let harness = Harness::start_with(unlimited).await;
    for letter in ["a", "b", "c", "d"] {
        Mock::given(method("GET"))
            .and(path(format!("/_matrix/client/{letter}")))
            .respond_with(ResponseTemplate::new(200).set_body_string(letter.repeat(300_000)))
            .mount(&harness.homeserver)
            .await;
    }

    let client = std::sync::Arc::new(harness.client().await);
    let mut tasks = Vec::new();
    for letter in ["a", "b", "c", "d"] {
        let client = std::sync::Arc::clone(&client);
        tasks.push(tokio::spawn(async move {
            let response = client
                .request(
                    "GET",
                    &format!("/_matrix/client/{letter}"),
                    None,
                    BTreeMap::new(),
                    Vec::new(),
                    Duration::from_secs(120),
                )
                .await
                .expect("an answer");
            // Every byte is the letter that was asked for: a chunk of somebody else's answer
            // landing in this one would show up here and nowhere else.
            assert_eq!(response.body.len(), 300_000);
            assert!(response.body.iter().all(|byte| *byte == letter.as_bytes()[0]));
        }));
    }
    for task in tasks {
        task.await.expect("a task");
    }
}

/// Steady traffic for a while, watching for drift: a tunnel that is fine for ten seconds and
/// falling apart at five minutes is the failure this catches.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn soak() {
    let seconds: u64 = std::env::var("SOAK_SECS")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(60);

    let harness = Harness::start_with(unlimited).await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"versions":["v1.11"]}"#))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut timings = Vec::new();
    let mut failures = 0usize;

    // Held back deliberately: this measures endurance, not peak throughput, and a tight loop would
    // measure the machine instead.
    let mut ticker = tokio::time::interval(Duration::from_millis(20));
    while Instant::now() < deadline {
        ticker.tick().await;
        let at = Instant::now();
        match client
            .request(
                "GET",
                "/_matrix/client/versions",
                None,
                BTreeMap::new(),
                Vec::new(),
                TIMEOUT,
            )
            .await
        {
            Ok(response) if response.status == 200 => timings.push(at.elapsed()),
            _ => failures += 1,
        }
    }

    // Drift: compare the first tenth of the run with the last.
    let tenth = (timings.len() / 10).max(1);
    let first: Duration = timings.iter().take(tenth).sum::<Duration>() / tenth as u32;
    let last: Duration = timings.iter().rev().take(tenth).sum::<Duration>() / tenth as u32;
    println!("soak {seconds}s — first tenth {first:?}, last tenth {last:?}, {failures} failures");
    report("soak", timings.clone());

    assert_eq!(failures, 0, "the tunnel dropped {failures} requests");
    assert!(
        last < first * 4,
        "latency drifted from {first:?} to {last:?} over {seconds}s"
    );
}
