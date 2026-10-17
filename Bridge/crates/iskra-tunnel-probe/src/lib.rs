//! The client side of the tunnel, in as little code as it can be written.
//!
//! This exists so the bridge can be proven end to end before and beside the Swift client, and so
//! the integration tests have a real client rather than a mock of one. The app's
//! `NostrStreamTunnel` and `LocalConnectProxy` do what [`StreamClient`] does here, with a keypair
//! from the Keychain instead of a generated one — including the single dispatch loop, which is not
//! an optimisation but the only shape that survives more than one stream at a time.

pub mod stream;

pub use stream::{Outcome, StreamClient, TunnelStream};
