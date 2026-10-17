//! The Iskra nostr tunnel bridge.
//!
//! A Matrix client that cannot reach its homeserver directly opens a TCP stream through nostr: each
//! frame is a NIP-44 encrypted event on a relay. This service listens on those relays, connects to
//! the homeserver the client asked for, and moves bytes both ways. To the network between the
//! client and the relay it looks like nostr, because it is.
//!
//! **The bridge cannot read what it carries.** The SDK speaks TLS to the homeserver itself, with
//! the real certificate checked, through the stream; the bridge sees which host, when, and how many
//! bytes. No token, no path, no message — not in unencrypted rooms either. That is the whole threat
//! model, and `docs/BLIND-BRIDGE.md` has it as a table. (The protocol before this one read every
//! request, token included. It is gone.)

pub mod blind;
pub mod config;
pub mod listener;
pub mod ratelimit;
pub mod sni;
pub mod stream;
pub mod upstream;

pub use config::Config;
pub use listener::Bridge;
