//! The whole tunnel, in one process, with no network and no deployed anything.
//!
//! A relay runs in-process (`nostr-relay-builder`), a fake homeserver runs in-process
//! (`wiremock`), and the probe crate is the real client. What these tests prove is the thing that
//! is otherwise only provable by deploying: that a request published as a nostr event comes back
//! as the homeserver's own bytes.

use std::collections::BTreeMap;

use std::collections::BTreeSet;

use iskra_bridge::upstream::{parse_origin, Allowed, Upstreams};
use std::num::NonZeroU32;
use std::time::Duration;

use iskra_tunnel_probe::TunnelClient;
use nostr_sdk::prelude::Keys;
use url::Url;
use wiremock::matchers::{body_bytes, body_string, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

mod common;
use common::Harness;

const TIMEOUT: Duration = Duration::from_secs(20);

#[tokio::test]
async fn a_get_comes_back_with_the_homeservers_own_bytes() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"versions":["v1.11"]}"#))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
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
        .expect("an answer");

    assert_eq!(response.status, 200);
    assert_eq!(response.body, br#"{"versions":["v1.11"]}"#);
}

#[tokio::test]
async fn a_post_carries_its_body_and_its_headers_through() {
    let harness = Harness::start().await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .and(header("authorization", "Bearer secret-token"))
        .and(body_string(r#"{"type":"m.login.token"}"#))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"access_token":"x"}"#))
        .mount(&harness.homeserver)
        .await;

    let mut headers = BTreeMap::new();
    headers.insert("authorization".into(), "Bearer secret-token".into());
    headers.insert("content-type".into(), "application/json".into());

    let client = harness.client().await;
    let response = client
        .request(
            "POST",
            "/_matrix/client/v3/login",
            None,
            headers,
            br#"{"type":"m.login.token"}"#.to_vec(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
    assert_eq!(response.body, br#"{"access_token":"x"}"#);
}

/// A response far too big for one NIP-44 payload, which is where the tunnel used to stop.
///
/// 200 KB is nine chunks at the default budget, and every byte of it has to come back in the right
/// order — this is the test that would catch a chunker and a reassembler that disagree.
#[tokio::test]
async fn a_response_larger_than_one_envelope_comes_back_whole() {
    let harness = Harness::start().await;
    let body = "x".repeat(200_000);
    Mock::given(method("GET"))
        .and(path("/_matrix/client/big"))
        .respond_with(ResponseTemplate::new(200).set_body_string(body.clone()))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "GET",
            "/_matrix/client/big",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
    assert_eq!(response.body.len(), body.len());
    assert_eq!(response.body, body.as_bytes());
}

/// And the same in the other direction: a body the *client* cannot fit in one event.
///
/// This is what sending a photo looks like from here. `body_bytes` makes wiremock check every
/// byte, so a reassembly that joined the chunks in the wrong order would not match.
#[tokio::test]
async fn a_request_body_larger_than_one_envelope_arrives_whole() {
    let harness = Harness::start().await;
    // Not a repeated character: a body of one repeated byte reassembles identically however the
    // chunks are ordered, which is exactly the bug this should catch.
    let body: Vec<u8> = (0..150_000u32).map(|i| (i % 251) as u8).collect();
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .and(body_bytes(body.clone()))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"content_uri":"mxc://x"}"#))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "POST",
            "/_matrix/media/v3/upload",
            None,
            BTreeMap::new(),
            body,
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
}

/// A dead relay in the list must not stand between the client and a chunked answer.
///
/// This is the one `LiveBridgeSessionTests` found: `send_event` waits for *every* relay to say OK,
/// a relay that is down takes ten seconds to be given up on, and chunks published one after
/// another each waited out that ten seconds before the next could leave. A 53 KB sync answer took
/// twenty seconds. Nothing smaller than two chunks ever showed it, because the client has the one
/// event from the live relay long before the dead one is abandoned.
///
/// `ws://127.0.0.1:1` is refused on connect, which leaves nostr-sdk retrying it — exactly the state
/// `nos.lol` was in, answering `502` to the handshake, when the session was measured.
#[tokio::test]
async fn a_dead_relay_does_not_hold_up_a_chunked_answer() {
    let harness = Harness::start_with(|mut config| {
        config.relays.push("ws://127.0.0.1:1".into());
        config
    })
    .await;
    let body = "z".repeat(200_000);
    Mock::given(method("GET"))
        .and(path("/_matrix/client/big"))
        .respond_with(ResponseTemplate::new(200).set_body_string(body.clone()))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let started = std::time::Instant::now();
    let response = client
        .request(
            "GET",
            "/_matrix/client/big",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.body.len(), body.len());
    // Nine chunks. Sent in sequence behind a dead relay, this is ninety seconds.
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "a chunked answer took {:?} with a dead relay in the list",
        started.elapsed()
    );
}

/// One request on three relays reaches the homeserver **once**.
///
/// Every relay delivers its own copy of an event, and a bridge that served each copy would sign
/// somebody in three times, as three devices, and upload their keys three times over. Nothing in
/// the bridge prevents that. What does is nostr-sdk: its default database is a `MemoryDatabase` in
/// *tracker* mode, which remembers the id of every event it has seen — ephemeral ones included,
/// though it stores none of them — and a repeat produces no notification.
///
/// That is a property of somebody else's default, which is exactly the kind of thing that changes
/// in a minor version without a word. This pins it: were the tracker to go, this fails rather than
/// every login through the bridge quietly becoming three.
#[tokio::test]
async fn a_request_on_several_relays_reaches_the_homeserver_once() {
    let harness = Harness::start_on(3, |config| config).await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"device_id":"ONE"}"#))
        .expect(1)
        .mount(&harness.homeserver)
        .await;
    // And a chunked one, which is where a repeat could also reopen a message already served.
    let body: Vec<u8> = (0..60_000u32).map(|i| (i % 251) as u8).collect();
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .expect(1)
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "POST",
            "/_matrix/client/v3/login",
            None,
            BTreeMap::new(),
            br#"{"type":"m.login.password"}"#.to_vec(),
            TIMEOUT,
        )
        .await
        .expect("an answer");
    assert_eq!(response.status, 200);
    let response = client
        .request(
            "POST",
            "/_matrix/media/v3/upload",
            None,
            BTreeMap::new(),
            body,
            TIMEOUT,
        )
        .await
        .expect("an answer");
    assert_eq!(response.status, 200);

    // Long enough for the slowest relay's copy to have arrived and been dealt with.
    tokio::time::sleep(Duration::from_millis(500)).await;
    harness.homeserver.verify().await;
}

/// A request over the limit is told so — in words the Matrix SDK acts on — instead of being met
/// with silence.
///
/// It used to be silence, and a client can do nothing with silence but wait out its own timeout.
/// `M_LIMIT_EXCEEDED` with `retry_after_ms` is what a homeserver says when it rate-limits, and the
/// SDK already backs off on it.
#[tokio::test]
async fn a_request_over_the_limit_is_answered_429_not_ignored() {
    let harness = Harness::start_with(|mut config| {
        config.rate_limit_per_min = NonZeroU32::new(1).unwrap();
        config
    })
    .await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let ask = || {
        client.request(
            "GET",
            "/_matrix/client/versions",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
    };
    assert_eq!(ask().await.expect("the first").status, 200);

    let started = std::time::Instant::now();
    let refused = ask().await.expect("an answer, not a timeout");
    assert_eq!(refused.status, 429);
    assert!(started.elapsed() < Duration::from_secs(5));
    let body: serde_json::Value = serde_json::from_slice(&refused.body).expect("JSON");
    assert_eq!(body["errcode"], "M_LIMIT_EXCEEDED");
    assert!(body["retry_after_ms"].as_u64().unwrap_or(0) > 0);
}

/// The limit counts requests, not the events they are cut into.
///
/// It counted events until chunking made the two different: a 3 MB photo is 128 events, so one
/// upload spent the whole minute's allowance and the chunks past it were dropped in silence. Here
/// the limit is five a minute and the upload is nine chunks — one request, and it goes through.
#[tokio::test]
async fn a_chunked_upload_is_one_request_to_the_limit() {
    let harness = Harness::start_with(|mut config| {
        config.rate_limit_per_min = NonZeroU32::new(5).unwrap();
        config
    })
    .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "POST",
            "/_matrix/media/v3/upload",
            None,
            BTreeMap::new(),
            vec![7; 200_000],
            TIMEOUT,
        )
        .await
        .expect("an answer");
    assert_eq!(response.status, 200);
}

/// Both ways at once, at the sizes either side of a chunk boundary.
#[tokio::test]
async fn bodies_either_side_of_the_chunk_boundary_round_trip() {
    let harness = Harness::start().await;
    let chunk = 24 * 1024;
    let sizes = [0usize, 1, chunk - 1, chunk, chunk + 1, chunk * 2];

    for size in sizes {
        Mock::given(method("GET"))
            .and(path(format!("/_matrix/client/size/{size}")))
            .respond_with(ResponseTemplate::new(200).set_body_string("y".repeat(size)))
            .mount(&harness.homeserver)
            .await;
    }

    let client = harness.client().await;
    for size in sizes {
        let response = client
            .request(
                "GET",
                &format!("/_matrix/client/size/{size}"),
                None,
                BTreeMap::new(),
                Vec::new(),
                TIMEOUT,
            )
            .await
            .unwrap_or_else(|error| panic!("a {size}-byte body: {error}"));
        assert_eq!(response.status, 200, "size {size}");
        assert_eq!(response.body.len(), size, "size {size}");
    }
}

#[tokio::test]
async fn an_error_status_is_carried_rather_than_swallowed() {
    // A 404 from the homeserver is an answer, not a failure of the tunnel: the SDK has to see it.
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/nope"))
        .respond_with(ResponseTemplate::new(404).set_body_string(r#"{"errcode":"M_NOT_FOUND"}"#))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "GET",
            "/_matrix/client/v3/nope",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 404);
}

#[tokio::test]
async fn a_query_string_survives_the_trip() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/sync"))
        .and(wiremock::matchers::query_param("timeout", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "GET",
            "/_matrix/client/v3/sync?timeout=0",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
}

#[tokio::test]
async fn a_client_outside_the_allow_list_gets_nothing() {
    let welcome = Keys::generate();
    let harness = Harness::start_with(|mut config| {
        config.allowed_pubkeys = Some([welcome.public_key()].into_iter().collect());
        config
    })
    .await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    let stranger = harness.client().await;
    let result = stranger
        .request(
            "GET",
            "/_matrix/client/versions",
            None,
            BTreeMap::new(),
            Vec::new(),
            Duration::from_secs(3),
        )
        .await;
    assert!(result.is_err(), "a stranger must not be served");

    // And the same bridge still serves the key it was given.
    let allowed = harness.client_with(welcome).await;
    let response = allowed
        .request(
            "GET",
            "/_matrix/client/versions",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("the allowed client is served");
    assert_eq!(response.status, 200);
}

#[tokio::test]
async fn an_unreachable_homeserver_answers_502_instead_of_hanging() {
    // The worst failure here is silence: the SDK would wait out its own timeout with nothing on
    // screen to explain it. The bridge owes the client a status even when it has nothing else.
    let harness = Harness::start_with(|mut config| {
        config.upstreams = Upstreams::new(
            Some(Url::parse("http://127.0.0.1:1").expect("url")),
            None,
        )
        .expect("upstreams");
        config.request_timeout = Duration::from_secs(2);
        config
    })
    .await;

    let client = harness.client().await;
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
        .expect("an answer, even a bad one");

    assert_eq!(response.status, 502);
}

#[tokio::test]
async fn an_event_sealed_for_another_bridge_is_ignored() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
        .mount(&harness.homeserver)
        .await;

    // Right relay, right kind, right recipient tag — but encrypted to a key this bridge does not
    // hold. It must be dropped quietly, not crash the serving loop.
    let impostor = Keys::generate();
    let confused = TunnelClient::connect(
        Keys::generate(),
        impostor.public_key(),
        std::slice::from_ref(&harness.relay_url),
    )
    .await
    .expect("connects");
    let _ = confused
        .request(
            "GET",
            "/_matrix/client/versions",
            None,
            BTreeMap::new(),
            Vec::new(),
            Duration::from_secs(2),
        )
        .await;

    // The loop is still alive and still serving.
    let client = harness.client().await;
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
        .expect("still serving");
    assert_eq!(response.status, 200);
    assert_ne!(harness.bridge_keys.public_key(), impostor.public_key());
}

/// The whole point of moving the target into the request: one bridge, several homeservers.
///
/// This is not a nice-to-have. Discovery is asked of `matrix.org` and the API lives at
/// `matrix-client.matrix.org`, so even a bridge run for a single community has to speak to more
/// than one origin — and a bridge pinned at deploy time is useless to anybody whose homeserver the
/// operator did not think of.
#[tokio::test]
async fn one_bridge_serves_several_homeservers() {
    let second = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"server":"second"}"#))
        .mount(&second)
        .await;
    let second_origin = parse_origin(&second.uri()).expect("origin");

    let allowed = second_origin.clone();
    let harness = Harness::start_with(move |mut config| {
        let first = config.upstreams.default_origin().expect("harness default");
        config.upstreams =
            Upstreams::new(None, Some(Allowed::These(BTreeSet::from([first, allowed]))))
                .expect("upstreams");
        config
    })
    .await;

    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"server":"first"}"#))
        .mount(&harness.homeserver)
        .await;
    let first_origin = harness.homeserver.uri();

    let client = harness.client().await;

    let from_first = client
        .request(
            "GET",
            "/_matrix/client/versions",
            Some(&first_origin),
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("the first homeserver answers");
    let from_second = client
        .request(
            "GET",
            "/_matrix/client/versions",
            Some(&second_origin),
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("the second homeserver answers");

    assert_eq!(
        String::from_utf8_lossy(&from_first.body),
        r#"{"server":"first"}"#
    );
    assert_eq!(
        String::from_utf8_lossy(&from_second.body),
        r#"{"server":"second"}"#
    );
}

/// A homeserver the operator did not list is refused — with an answer, not with silence.
#[tokio::test]
async fn a_homeserver_off_the_list_is_refused_out_loud() {
    let elsewhere = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string("should never be reached"))
        .mount(&elsewhere)
        .await;

    let harness = Harness::start().await;
    let client = harness.client().await;

    let response = client
        .request(
            "GET",
            "/_matrix/client/versions",
            Some(&elsewhere.uri()),
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("a refusal is still an answer");

    assert_eq!(response.status, 403);
    assert_eq!(
        elsewhere.received_requests().await.unwrap_or_default().len(),
        0
    );
}

/// The bridge is for Matrix, not for the web. Without this an open bridge is an anonymous proxy
/// for anything anybody feels like fetching.
#[tokio::test]
async fn the_bridge_will_not_fetch_something_that_is_not_matrix() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/admin/secrets"))
        .respond_with(ResponseTemplate::new(200).set_body_string("should never be reached"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request(
            "GET",
            "/admin/secrets",
            None,
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("a refusal is still an answer");

    assert_eq!(response.status, 403);
}

/// The traversal, end to end: the homeserver must never see the request at all.
///
/// The unit tests pin the policy; this pins that nothing downstream quietly re-joins the path and
/// undoes it. `/_matrix/../admin/secrets` reads as a Matrix path as a string and is
/// `/admin/secrets` as a URL, and the bridge used to check the first and fetch the second.
#[tokio::test]
async fn a_path_that_climbs_out_never_reaches_the_homeserver() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/admin/secrets"))
        .respond_with(ResponseTemplate::new(200).set_body_string("should never be reached"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    for target in [
        "/_matrix/../admin/secrets",
        "/_matrix/client/../../admin/secrets",
        "/_matrix/%2e%2e/admin/secrets",
    ] {
        let response = client
            .request("GET", target, None, BTreeMap::new(), Vec::new(), TIMEOUT)
            .await
            .expect("a refusal is still an answer");
        assert_eq!(response.status, 403, "{target}");
    }

    let seen = harness
        .homeserver
        .received_requests()
        .await
        .unwrap_or_default();
    assert!(
        seen.is_empty(),
        "the homeserver saw {} request(s) it should never have been asked for",
        seen.len()
    );
}

/// A redirect is judged like the request it answers. Left to reqwest, one `302` pointing off the
/// list — at the operator's LAN, at a cloud metadata address — had the bridge fetch that and hand
/// the body back. It is a 502, and the place it pointed at is never asked.
#[tokio::test]
async fn a_redirect_off_the_list_is_not_followed() {
    let elsewhere = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(200).set_body_string("should never be reached"))
        .mount(&elsewhere)
        .await;

    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(302).insert_header(
            "location",
            format!("{}/_matrix/client/versions", elsewhere.uri()),
        ))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request("GET", "/_matrix/client/versions", None, BTreeMap::new(), Vec::new(), TIMEOUT)
        .await
        .expect("an answer");

    // Not the 302 either: handed back, the SDK would follow it itself, around the tunnel.
    assert_eq!(response.status, 502);
    assert_eq!(
        elsewhere.received_requests().await.unwrap_or_default().len(),
        0
    );
}

/// A redirect that stays within what the bridge is for is followed, as it always was.
#[tokio::test]
async fn a_redirect_within_the_homeserver_is_followed() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/media/old"))
        .respond_with(ResponseTemplate::new(307).insert_header("location", "/_matrix/media/new"))
        .mount(&harness.homeserver)
        .await;
    Mock::given(method("GET"))
        .and(path("/_matrix/media/new"))
        .respond_with(ResponseTemplate::new(200).set_body_string("moved here"))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request("GET", "/_matrix/media/old", None, BTreeMap::new(), Vec::new(), TIMEOUT)
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
    assert_eq!(response.body, b"moved here");
}

/// Same host, but out of `/_matrix/`: a redirect cannot reach what a request could not.
#[tokio::test]
async fn a_redirect_out_of_matrix_is_not_followed() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/versions"))
        .respond_with(ResponseTemplate::new(302).insert_header("location", "/admin/secrets"))
        .mount(&harness.homeserver)
        .await;
    Mock::given(method("GET"))
        .and(path("/admin/secrets"))
        .respond_with(ResponseTemplate::new(200).set_body_string("secret"))
        .expect(0)
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request("GET", "/_matrix/client/versions", None, BTreeMap::new(), Vec::new(), TIMEOUT)
        .await
        .expect("an answer");

    assert_eq!(response.status, 502);
}

/// Past the 8 MB the client's reassembler accepts, the bridge stops reading rather than holding
/// it all and publishing it to every relay.
#[tokio::test]
async fn a_response_over_the_ceiling_is_a_502() {
    let harness = Harness::start().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/media/huge"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![0u8; 8 * 1024 * 1024 + 1]))
        .mount(&harness.homeserver)
        .await;

    let client = harness.client().await;
    let response = client
        .request("GET", "/_matrix/media/huge", None, BTreeMap::new(), Vec::new(), TIMEOUT)
        .await
        .expect("an answer");

    assert_eq!(response.status, 502);
}
