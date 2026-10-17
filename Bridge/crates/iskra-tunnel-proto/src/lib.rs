//! The wire format of the Iskra nostr tunnel, and nothing else.
//!
//! The tunnel carries a TCP stream that the client's own TLS runs over, so the bridge moves
//! ciphertext it cannot read: it sees which host, when, and how many bytes, and nothing inside.
//! (An earlier protocol carried HTTP requests the bridge had to read in order to repeat, access
//! token included. It is gone, from both sides; there is no fallback to it.)
//!
//! Both sides link this crate, which is the point: a sender that cuts a stream one way and a
//! receiver that puts it back together another way would fail only under load, only sometimes,
//! and only in production. Here there is one frame, one window and one reassembly, and the tests
//! in `stream` are the whole specification — the Swift side is asked the same questions.
//!
//! Deliberately free of I/O. Nothing here opens a socket, reads the clock or touches the network,
//! so every rule the protocol has can be pinned by a unit test.

pub mod crypto;
pub mod stream;

pub use crypto::{open_frame, seal_frame};
pub use stream::{
    new_stream_id, pow_reason, pow_required, reason, Inbound, Outbound, StreamFrame, StreamOp,
    Violation, DEFAULT_POW_BITS, MAX_POW_BITS, STREAM_PROTOCOL_VERSION,
};

use thiserror::Error;

/// Bridge → client: the relay list and segment size the bridge wants used. Reserved; not sent.
/// (The proof-of-work difficulty, once meant for it, travels in the `rst` that asks for more.)
pub const KIND_CONFIG: u16 = 20005;
/// Client → bridge: one frame of a stream.
pub const KIND_STREAM_CLIENT: u16 = 20010;
/// Bridge → client: one frame of a stream.
pub const KIND_STREAM_BRIDGE: u16 = 20011;

/// Longest stream id either side accepts. The id is a key the bridge holds, chosen by a stranger,
/// so its length is memory a stranger chooses; a client sends a UUID, and 64 is room to spare.
pub const MAX_SID_LEN: usize = 64;

/// NIP-44 v2 refuses to encrypt more than this in one payload. The segment budget is derived from
/// it rather than from a round number, because a round number that happens to exceed it produces a
/// tunnel that works until somebody downloads a large photo.
pub const MAX_NIP44_PLAINTEXT: usize = 65_535;

/// Bytes of stream per segment, as senders cut them. Base64 inflates this by a third, the JSON
/// frame adds a little more, and NIP-44's base64 ciphertext adds a third on top of *that* — so
/// 24 KiB lands around a 44 KB event, comfortably inside the 64 KB limit common on public relays.
pub const DEFAULT_SEGMENT: usize = 24 * 1024;

#[derive(Debug, Error)]
pub enum ProtoError {
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u8),
    #[error("frame is malformed: {0}")]
    Malformed(&'static str),
    #[error("segment is not valid base64")]
    BadBase64(#[from] base64::DecodeError),
    #[error("frame is not valid JSON")]
    BadJson(#[from] serde_json::Error),
    #[error("payload does not decrypt with this key")]
    Undecryptable,
    #[error("payload is too large to encrypt: {0} bytes exceeds the NIP-44 limit")]
    TooLarge(usize),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_segment_budget_fits_inside_the_nip44_limit() {
        // Segment → base64 (+1/3) → JSON frame overhead. Whatever else changes, this has to hold.
        let base64_len = DEFAULT_SEGMENT.div_ceil(3) * 4;
        assert!(base64_len + 512 < MAX_NIP44_PLAINTEXT);
    }
}
