//! The whole tunnel, in one process, with no network and no deployed anything.
//!
//! A relay runs in-process (`nostr-relay-builder`), a fake homeserver runs in-process
//! (`wiremock`), and the probe crate is the real client. What these tests prove is the thing that
//! is otherwise only provable by deploying: that a request published as a nostr event comes back
//! as the homeserver's own bytes.

use std::collections::BTreeMap;
use std::time::Duration;

use iskra_tunnel_probe::TunnelClient;
use nostr_sdk::prelude::Keys;
use url::Url;
use wiremock::matchers::{body_string, header, method, path};
use wiremock::{Mock, ResponseTemplate};

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
            headers,
            br#"{"type":"m.login.token"}"#.to_vec(),
            TIMEOUT,
        )
        .await
        .expect("an answer");

    assert_eq!(response.status, 200);
    assert_eq!(response.body, br#"{"access_token":"x"}"#);
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
        config.homeserver = Url::parse("http://127.0.0.1:1").expect("url");
        config.request_timeout = Duration::from_secs(2);
        config
    })
    .await;

    let client = harness.client().await;
    let response = client
        .request(
            "GET",
            "/_matrix/client/versions",
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
            BTreeMap::new(),
            Vec::new(),
            TIMEOUT,
        )
        .await
        .expect("still serving");
    assert_eq!(response.status, 200);
    assert_ne!(harness.bridge_keys.public_key(), impostor.public_key());
}
