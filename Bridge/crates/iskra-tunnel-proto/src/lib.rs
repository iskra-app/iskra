//! The wire format of the Iskra nostr tunnel, and nothing else.
//!
//! Both sides of the tunnel link this crate, which is the point: a client that chunks a body one
//! way and a bridge that reassembles it another way would fail only under load, only sometimes,
//! and only in production. Here there is one chunker and one reassembler, and the tests below are
//! the whole specification.
//!
//! Deliberately free of I/O. Nothing here opens a socket, reads the clock or touches the network,
//! so every rule the protocol has can be pinned by a unit test.

pub mod chunk;
pub mod crypto;
pub mod envelope;
pub mod reassemble;

pub use chunk::chunk_count;
pub use crypto::{open, seal};
pub use envelope::{Envelope, HttpRequest, HttpResponse, MAX_ID_LEN, PROTOCOL_VERSION};
pub use reassemble::{Accepted, Limits, Reassembler};

use thiserror::Error;

/// Client → bridge: one chunk of an HTTP request.
pub const KIND_REQUEST: u16 = 20001;
/// Bridge → client: one chunk of an HTTP response.
pub const KIND_RESPONSE: u16 = 20002;
/// Client → bridge: subscribe to sync, and keep that subscription alive.
pub const KIND_SUBSCRIBE: u16 = 20003;
/// Bridge → client: a sync delta the client did not have to ask for.
pub const KIND_PUSH: u16 = 20004;
/// Bridge → client: the relay list and chunk size the bridge wants used.
pub const KIND_CONFIG: u16 = 20005;

/// NIP-44 v2 refuses to encrypt more than this in one payload. Every chunk budget is derived from
/// it rather than from a round number, because a round number that happens to exceed it produces a
/// tunnel that works until somebody sends a long message.
pub const MAX_NIP44_PLAINTEXT: usize = 65_535;

/// Raw body bytes per chunk. Base64 inflates this by a third, the JSON envelope adds a little more,
/// and NIP-44's base64 ciphertext adds a third on top of *that* — so 24 KiB of body lands around a
/// 44 KB event, comfortably inside the 64 KB limit common on public relays.
pub const DEFAULT_MAX_BODY_CHUNK: usize = 24 * 1024;

#[derive(Debug, Error)]
pub enum ProtoError {
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u8),
    #[error("envelope is malformed: {0}")]
    Malformed(&'static str),
    #[error("body is not valid base64")]
    BadBase64(#[from] base64::DecodeError),
    #[error("envelope is not valid JSON")]
    BadJson(#[from] serde_json::Error),
    #[error("payload does not decrypt with this key")]
    Undecryptable,
    #[error("payload is too large to encrypt: {0} bytes exceeds the NIP-44 limit")]
    TooLarge(usize),
}

/// The first two path segments and nothing more.
///
/// Everything the tunnel carries is somebody's private traffic, and a Matrix path is not the
/// exception it looks like: `/_matrix/client/v3/rooms/{roomId}/send/...` names the room and often
/// the event. Logs get this, never the path itself.
pub fn log_path(path: &str) -> String {
    let mut out = String::new();
    for segment in path.trim_start_matches('/').split('/').take(2) {
        out.push('/');
        out.push_str(segment);
    }
    if out.is_empty() {
        out.push('/');
    }
    out.push_str("/…");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_path_keeps_two_segments_and_drops_the_identifiers() {
        assert_eq!(
            log_path("/_matrix/client/v3/rooms/!abc:matrix.org/send/m.room.message/txn1"),
            "/_matrix/client/…"
        );
        assert_eq!(log_path("/_matrix/client"), "/_matrix/client/…");
        assert_eq!(log_path("/"), "//…");
    }

    #[test]
    fn the_chunk_budget_fits_inside_the_nip44_limit() {
        // Body → base64 (+1/3) → JSON envelope overhead. Whatever else changes, this has to hold.
        let base64_len = DEFAULT_MAX_BODY_CHUNK.div_ceil(3) * 4;
        assert!(base64_len + 2048 < MAX_NIP44_PLAINTEXT);
    }
}
