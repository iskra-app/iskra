//! The Iskra nostr tunnel bridge.
//!
//! A Matrix client that cannot reach its homeserver directly wraps each HTTP request in a NIP-44
//! encrypted nostr event and publishes it to a relay. This service listens on those relays,
//! unwraps the request, makes it against the real homeserver, and sends the response back the same
//! way. To the network between the client and the relay it looks like nostr, because it is.
//!
//! What the bridge can see is the whole point of the threat model and is stated plainly in the
//! README: it terminates the Matrix Client-Server API, so it sees the access token, every room and
//! event id, and the bodies of messages in **unencrypted** rooms. Encrypted rooms stay encrypted —
//! Olm and Megolm live above this layer and the bridge never holds their keys.

pub mod config;
pub mod forwarder;
pub mod listener;
pub mod ratelimit;

pub use config::Config;
pub use listener::Bridge;
