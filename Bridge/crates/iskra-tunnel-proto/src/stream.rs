//! The stream: the tunnel carries a TCP connection that the client's own TLS runs over, and the
//! bridge sees ciphertext and nothing else. What it still sees is the host it was asked to connect
//! to, when, and how many bytes; that is the whole list, and `docs/BLIND-BRIDGE.md` has it as a
//! table.
//!
//! Three pieces, all free of I/O like the rest of this crate:
//!
//! - [`StreamFrame`] — the JSON inside the event. Flat, with every field optional on the wire and
//!   [`StreamFrame::validate`] deciding which ones each `op` must and must not have, so that the
//!   Swift mirror can be a struct field for field and not an enum it has to guess the shape of.
//! - [`Outbound`] — the sender's window. Bounded in bytes *and* in segments, and moved only by
//!   acknowledgements, so that what one side reads from its socket is never more than the other
//!   side has written to its own. That is the whole of the back-pressure: a sender with a full
//!   window stops reading, and TCP tells the homeserver to slow down.
//! - [`Inbound`] — the receiver's reassembly. Segments arrive out of order and from several relays,
//!   and only the contiguous prefix goes to the socket. A hole is not waited on for long: relays do
//!   not store ephemeral events, so a segment no relay delivered is never coming.
//!
//! There is no retransmission, on purpose: a hole longer than [`GAP_TIMEOUT`] resets the stream,
//! and the HTTP client above it retries on a fresh one. Whether holes are common enough to want
//! more than that is a question for measurement, not for this file.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use base64::prelude::{Engine as _, BASE64_STANDARD};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ProtoError, MAX_SID_LEN};

/// `v` of every frame — 2, because the protocol before it was 1, and a frame from that one (or
/// from a future one) is refused rather than guessed at.
pub const STREAM_PROTOCOL_VERSION: u8 = 2;

/// Most unacknowledged bytes a sender may have out. 1 MiB is about forty segments, which keeps a
/// relay busy without letting either side hold somebody's download in memory.
pub const WINDOW_BYTES: usize = 1024 * 1024;

/// Most unacknowledged segments a sender may have out, whatever their size. Without it a sender
/// that flushes a few bytes at a time could have tens of thousands of segments in the air inside
/// the byte window, and the receiver would have to hold every one of them past a hole.
pub const WINDOW_SEGMENTS: u32 = 64;

/// The receiver acknowledges at least this often, in segments written to its socket…
pub const ACK_EVERY_SEGMENTS: u32 = 8;
/// …or in bytes, whichever comes first. Both are well inside the window: an acknowledgement that
/// waited for the window to fill would never be sent, because the sender stops when it fills.
pub const ACK_EVERY_BYTES: usize = 256 * 1024;

/// How long a hole is waited on before the stream is reset.
pub const GAP_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a socket may say nothing before what it has said goes out as a segment. One event per
/// read would be hundreds of events per room load — TLS records arrive a few hundred bytes at a
/// time — and a public relay bans that.
pub const COALESCE: Duration = Duration::from_millis(5);

/// Longest host an `open` may name: a DNS name's own ceiling.
pub const MAX_HOST_LEN: usize = 253;

/// Longest reason an `rst` may carry. The reasons are the short words in [`reason`].
pub const MAX_REASON_LEN: usize = 64;

/// Largest segment either side accepts, decoded. Senders cut at `DEFAULT_SEGMENT`; this is
/// room above that, and a ceiling on what a stranger can make the receiver decode.
pub const MAX_SEGMENT: usize = 64 * 1024;

/// What an `rst` says. One word each, the same on both sides, so the app can turn them into a
/// sentence a person can act on — "the bridge will not take you to that server" is a different
/// problem from "the bridge is busy", and both are different from a bridge that is down.
pub mod reason {
    /// `open` named a port other than 443 (or the one listed for that host).
    pub const BAD_PORT: &str = "bad port";
    /// The host resolves to an address that is not on the public internet.
    pub const NOT_PUBLIC: &str = "not public";
    /// Not one of the homeservers this bridge serves.
    pub const NOT_ALLOWED: &str = "not allowed";
    /// An open bridge asked the host whether it is a Matrix server, and it said no.
    pub const NOT_MATRIX: &str = "not matrix";
    /// The host does not resolve.
    pub const NO_SUCH_HOST: &str = "no such host";
    /// The first bytes were not a TLS ClientHello.
    pub const NOT_TLS: &str = "not tls";
    /// The ClientHello named no server.
    pub const NO_SNI: &str = "no sni";
    /// The ClientHello named a server other than the host in `open`.
    pub const SNI_MISMATCH: &str = "sni mismatch";
    /// The bridge has as many streams open as it will hold, for this client or for everyone.
    pub const BUSY: &str = "busy";
    /// A segment never arrived.
    pub const GAP: &str = "gap";
    /// The other side sent past the window it was given.
    pub const WINDOW: &str = "window";
    /// A frame that contradicts the stream: data after `fin`, an `ack` for something never sent.
    pub const PROTOCOL: &str = "protocol";
    /// The TCP connection to the host could not be made.
    pub const UNREACHABLE: &str = "unreachable";
    /// The TCP connection to the host broke.
    pub const UPSTREAM: &str = "upstream";
    /// Nothing moved for too long.
    pub const IDLE: &str = "idle";
    /// The stream lived as long as a stream may.
    pub const EXPIRED: &str = "expired";
    /// The side that sent it has closed the stream itself.
    pub const CLOSED: &str = "closed";
    /// The `open` carried less proof of work than the bridge asks for. Sent as `pow <bits>` — see
    /// [`super::pow_reason`] — so the client learns the difficulty from the refusal itself.
    pub const POW: &str = "pow";
}

/// The difficulty a client mines its `open` to when it knows nothing better: NIP-13 leading zero
/// bits of the event id. Sixteen is a fraction of a second on a phone once per connection, and
/// costly for anybody opening thousands — which is the point: a nostr key costs nothing, so every
/// ceiling "per key" can be dodged with a new one, and this is the one that cannot.
pub const DEFAULT_POW_BITS: u8 = 16;

/// The most either side accepts. Each bit doubles the client's work, and 24 is already seconds on
/// a phone per connection: a bridge asking for more is broken or hostile, and the client ignores
/// it rather than mining until the battery is gone.
pub const MAX_POW_BITS: u8 = 24;

/// The `rst` reason for an `open` mined to too few bits: `pow 20`.
///
/// The difficulty travels in the refusal rather than in an announcement of its own, so a bridge
/// under attack can raise it without an app update, without a config event on the relays, and
/// without anybody having to ask: the next `open` from that client is mined to what it was told.
pub fn pow_reason(bits: u8) -> String {
    format!("{} {bits}", reason::POW)
}

/// The difficulty a `pow <bits>` refusal asks for, or `None` for any other reason — and for a
/// difficulty past [`MAX_POW_BITS`].
pub fn pow_required(reason: &str) -> Option<u8> {
    let (word, bits) = reason.split_once(' ')?;
    if word != reason::POW {
        return None;
    }
    bits.parse().ok().filter(|&bits| bits <= MAX_POW_BITS)
}

/// What a frame does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StreamOp {
    /// Client → bridge: connect to `host:port`, and here are the first bytes (`seq` 0).
    Open,
    /// Bridge → client: the TCP connection is up.
    Opened,
    /// One segment of the stream.
    Data,
    /// Every segment below `ack` has been written to the receiver's socket.
    Ack,
    /// No segment at or past `seq` will be sent: the sender's half is closed.
    Fin,
    /// The stream is over, with `reason`.
    Rst,
}

/// One frame of one stream, as it travels inside a NIP-44 payload.
///
/// `seq` counts segments, not bytes, and each direction counts its own. `open` is segment 0 of
/// the client's direction, which is how the ClientHello rides in the same event that asks for the
/// connection: a cold connection would otherwise pay one more round trip through a relay, and the
/// bridge needs the ClientHello before it connects anyway, to check the server name in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamFrame {
    pub v: u8,
    pub sid: String,
    pub op: StreamOp,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ack: Option<u32>,
    /// Base64 of the segment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// A fresh stream id. A UUID, because the id is a key the
/// bridge holds, and it is the client's to choose.
pub fn new_stream_id() -> String {
    Uuid::new_v4().to_string()
}

impl StreamFrame {
    fn bare(sid: &str, op: StreamOp) -> Self {
        Self {
            v: STREAM_PROTOCOL_VERSION,
            sid: sid.to_string(),
            op,
            host: None,
            port: None,
            seq: None,
            ack: None,
            data: None,
            reason: None,
        }
    }

    pub fn open(sid: &str, host: &str, port: u16, first: &[u8]) -> Self {
        Self {
            host: Some(host.to_string()),
            port: Some(port),
            seq: Some(0),
            data: Some(BASE64_STANDARD.encode(first)),
            ..Self::bare(sid, StreamOp::Open)
        }
    }

    pub fn opened(sid: &str) -> Self {
        Self::bare(sid, StreamOp::Opened)
    }

    pub fn data(sid: &str, seq: u32, bytes: &[u8]) -> Self {
        Self {
            seq: Some(seq),
            data: Some(BASE64_STANDARD.encode(bytes)),
            ..Self::bare(sid, StreamOp::Data)
        }
    }

    pub fn ack(sid: &str, ack: u32) -> Self {
        Self {
            ack: Some(ack),
            ..Self::bare(sid, StreamOp::Ack)
        }
    }

    pub fn fin(sid: &str, seq: u32) -> Self {
        Self {
            seq: Some(seq),
            ..Self::bare(sid, StreamOp::Fin)
        }
    }

    pub fn rst(sid: &str, reason: &str) -> Self {
        Self {
            reason: Some(reason.to_string()),
            ..Self::bare(sid, StreamOp::Rst)
        }
    }

    /// Refuse anything self-contradictory, before code that assumes a sane frame sees it.
    ///
    /// Each op has the fields it needs and **no others**. Strictness here is what keeps the two
    /// implementations honest: a field one side sends and the other ignores is a field whose
    /// meaning drifts.
    pub fn validate(&self) -> Result<(), ProtoError> {
        if self.v != STREAM_PROTOCOL_VERSION {
            return Err(ProtoError::UnsupportedVersion(self.v));
        }
        if self.sid.is_empty() {
            return Err(ProtoError::Malformed("sid is empty"));
        }
        if self.sid.len() > MAX_SID_LEN {
            return Err(ProtoError::Malformed("sid is too long"));
        }

        let has = |present: bool, needed: bool, what: &'static str| -> Result<(), ProtoError> {
            match (present, needed) {
                (false, true) => Err(ProtoError::Malformed(what)),
                (true, false) => Err(ProtoError::Malformed("a field this op does not carry")),
                _ => Ok(()),
            }
        };
        let (host, port, seq, ack, data, reason) = match self.op {
            StreamOp::Open => (true, true, true, false, true, false),
            StreamOp::Opened => (false, false, false, false, false, false),
            StreamOp::Data => (false, false, true, false, true, false),
            StreamOp::Ack => (false, false, false, true, false, false),
            StreamOp::Fin => (false, false, true, false, false, false),
            StreamOp::Rst => (false, false, false, false, false, true),
        };
        has(self.host.is_some(), host, "open has no host")?;
        has(self.port.is_some(), port, "open has no port")?;
        has(self.seq.is_some(), seq, "no seq")?;
        has(self.ack.is_some(), ack, "ack has no ack")?;
        has(self.data.is_some(), data, "no data")?;
        has(self.reason.is_some(), reason, "rst has no reason")?;

        if self.op == StreamOp::Open {
            if self.seq != Some(0) {
                return Err(ProtoError::Malformed("open is not segment 0"));
            }
            let host = self.host.as_deref().unwrap_or_default();
            if host.is_empty() || host.len() > MAX_HOST_LEN {
                return Err(ProtoError::Malformed("host is empty or too long"));
            }
            if self.port == Some(0) {
                return Err(ProtoError::Malformed("port is zero"));
            }
        }
        if let Some(reason) = &self.reason {
            if reason.len() > MAX_REASON_LEN {
                return Err(ProtoError::Malformed("reason is too long"));
            }
        }
        // Base64 is a third longer than what it carries; past this, the decoded segment is past
        // `MAX_SEGMENT`, and it is refused before anybody decodes it.
        if let Some(data) = &self.data {
            if data.len() > MAX_SEGMENT.div_ceil(3) * 4 {
                return Err(ProtoError::Malformed("segment is too large"));
            }
        }
        Ok(())
    }

    /// The segment's bytes, decoded. Empty for a frame that carries none.
    pub fn payload(&self) -> Result<Vec<u8>, ProtoError> {
        match &self.data {
            None => Ok(Vec::new()),
            Some(data) if data.is_empty() => Ok(Vec::new()),
            Some(data) => Ok(BASE64_STANDARD.decode(data)?),
        }
    }
}

/// Something the other side did that a correct implementation never does. The stream is reset
/// with [`reason::WINDOW`] or [`reason::PROTOCOL`] — never quietly carried on, because a stream
/// whose two ends disagree about what was said delivers somebody's bytes in the wrong order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// A segment past the window this side gave.
    BeyondWindow,
    /// A segment at or past the `fin` already received.
    DataAfterFin,
    /// A second `fin` that disagrees with the first, or one below what was already delivered.
    FinMoved,
    /// An `ack` for a segment that was never sent.
    AckBeyondSent,
}

impl Violation {
    /// The `rst` reason it becomes.
    pub fn reason(self) -> &'static str {
        match self {
            Violation::BeyondWindow => reason::WINDOW,
            _ => reason::PROTOCOL,
        }
    }
}

/// The sending half's window.
#[derive(Debug, Default)]
pub struct Outbound {
    next_seq: u32,
    /// Every segment below this has been acknowledged.
    acked: u32,
    /// Sizes of the segments in `acked..next_seq`, oldest first.
    unacked: std::collections::VecDeque<usize>,
    unacked_bytes: usize,
}

impl Outbound {
    /// A sender whose segment 0 already went out with `open`, `first_len` bytes long.
    pub fn after_open(first_len: usize) -> Self {
        let mut outbound = Self::default();
        outbound.push(first_len);
        outbound
    }

    /// Whether a segment of `len` bytes may go out now.
    ///
    /// An empty window always admits one segment, whatever its size: a segment larger than the
    /// window would otherwise never be sent, and the stream would stall with nothing to explain it.
    pub fn has_room(&self, len: usize) -> bool {
        if self.unacked.is_empty() {
            return true;
        }
        (self.unacked.len() as u32) < WINDOW_SEGMENTS && self.unacked_bytes + len <= WINDOW_BYTES
    }

    /// Whether *any* segment may go out — what a sender asks before reading its socket at all.
    pub fn is_open(&self) -> bool {
        self.has_room(0)
    }

    /// Account for one segment going out; its `seq`.
    pub fn push(&mut self, len: usize) -> u32 {
        let seq = self.next_seq;
        self.next_seq += 1;
        self.unacked.push_back(len);
        self.unacked_bytes += len;
        seq
    }

    /// The `seq` the next segment will get — and the `seq` of a `fin`, which says "nothing at or
    /// past this".
    pub fn next_seq(&self) -> u32 {
        self.next_seq
    }

    /// Take an acknowledgement. An old one, arriving late from a slow relay, changes nothing.
    pub fn ack(&mut self, ack: u32) -> Result<(), Violation> {
        if ack > self.next_seq {
            return Err(Violation::AckBeyondSent);
        }
        while self.acked < ack {
            let len = self
                .unacked
                .pop_front()
                .expect("one size per unacked segment");
            self.unacked_bytes -= len;
            self.acked += 1;
        }
        Ok(())
    }

    pub fn unacked_bytes(&self) -> usize {
        self.unacked_bytes
    }
}

/// The receiving half: segments in, the contiguous prefix out.
#[derive(Debug, Default)]
pub struct Inbound {
    /// The next `seq` the socket is waiting for. Everything below it has been handed out.
    next: u32,
    /// Segments past a hole, held until it fills.
    held: BTreeMap<u32, Vec<u8>>,
    held_bytes: usize,
    fin: Option<u32>,
    /// Since when something has been waiting on a hole. `None` while nothing is.
    hole_since: Option<Instant>,

    /// Segments the owner has reported written to its socket — what `ack` says.
    written: u32,
    /// Bytes handed out by `accept` and not yet reported written: the owner's queue to its socket.
    unwritten_bytes: usize,
    unacked_segments: u32,
    unacked_bytes: usize,
}

impl Inbound {
    pub fn new() -> Self {
        Self::default()
    }

    /// Take one segment. Returns whatever is now contiguous, in order, for the socket — possibly
    /// nothing (a duplicate, or a segment past a hole), possibly several (the one that filled it).
    pub fn accept(
        &mut self,
        seq: u32,
        bytes: Vec<u8>,
        now: Instant,
    ) -> Result<Vec<Vec<u8>>, Violation> {
        // Every relay delivers its own copy. Ordinary, and already counted.
        if seq < self.next || self.held.contains_key(&seq) {
            return Ok(Vec::new());
        }
        if self.fin.is_some_and(|fin| seq >= fin) {
            return Err(Violation::DataAfterFin);
        }
        // The window is measured from what has been **written**, not from what has been
        // assembled. The sender's window starts at its last acknowledgement, which is never past
        // `written`, so a correct sender never gets this far ahead. Measured from `next` instead,
        // a sender ignoring acknowledgements could keep the prefix moving and pile up everything
        // in front of a slow socket — held nowhere in this struct, and so capped by nothing.
        if seq >= self.written.saturating_add(WINDOW_SEGMENTS)
            || self.held_bytes + self.unwritten_bytes + bytes.len() > WINDOW_BYTES + MAX_SEGMENT
        {
            return Err(Violation::BeyondWindow);
        }

        let mut ready = Vec::new();
        if seq == self.next {
            ready.push(bytes);
            self.next += 1;
            while let Some(bytes) = self.held.remove(&self.next) {
                self.held_bytes -= bytes.len();
                ready.push(bytes);
                self.next += 1;
            }
            self.unwritten_bytes += ready.iter().map(Vec::len).sum::<usize>();
        } else {
            self.held_bytes += bytes.len();
            self.held.insert(seq, bytes);
        }
        self.update_hole(!ready.is_empty(), now);
        Ok(ready)
    }

    /// Take the other side's `fin`. True when the stream in this direction is now complete.
    pub fn finish(&mut self, seq: u32, now: Instant) -> Result<bool, Violation> {
        match self.fin {
            Some(fin) if fin != seq => return Err(Violation::FinMoved),
            Some(_) => return Ok(self.is_complete()),
            None => {}
        }
        // A `fin` below what was already delivered, or below a segment already held, says that
        // bytes which exist were never sent.
        if seq < self.next
            || self
                .held
                .keys()
                .next_back()
                .is_some_and(|&last| last >= seq)
        {
            return Err(Violation::FinMoved);
        }
        self.fin = Some(seq);
        self.update_hole(false, now);
        Ok(self.is_complete())
    }

    /// Every segment up to the `fin` has been handed out.
    pub fn is_complete(&self) -> bool {
        self.fin == Some(self.next)
    }

    /// Whether a hole has been waited on longer than [`GAP_TIMEOUT`].
    pub fn gap_expired(&self, now: Instant) -> bool {
        self.hole_since
            .is_some_and(|since| now.duration_since(since) >= GAP_TIMEOUT)
    }

    /// When the hole being waited on will have been waited on too long, if there is one.
    pub fn gap_deadline(&self) -> Option<Instant> {
        self.hole_since.map(|since| since + GAP_TIMEOUT)
    }

    /// Report segments written to the socket. Returns the `ack` to send, when one is due.
    ///
    /// Acknowledged once *written*, not once received: that is what makes the window mean "what
    /// the far socket has accepted", and so what carries TCP's back-pressure across the tunnel.
    pub fn written(&mut self, segments: u32, bytes: usize) -> Option<u32> {
        self.written += segments;
        self.unwritten_bytes = self.unwritten_bytes.saturating_sub(bytes);
        self.unacked_segments += segments;
        self.unacked_bytes += bytes;
        if self.unacked_segments >= ACK_EVERY_SEGMENTS || self.unacked_bytes >= ACK_EVERY_BYTES {
            self.unacked_segments = 0;
            self.unacked_bytes = 0;
            return Some(self.written);
        }
        None
    }

    /// A hole is anything held past `next`, or a `fin` that `next` has not reached. The clock
    /// starts when one appears and starts again whenever the prefix moves, so a slow stream that
    /// keeps making progress is never mistaken for a broken one.
    fn update_hole(&mut self, progressed: bool, now: Instant) {
        let waiting = !self.held.is_empty() || self.fin.is_some_and(|fin| fin > self.next);
        self.hole_since = match (waiting, self.hole_since) {
            (false, _) => None,
            (true, Some(_)) if progressed => Some(now),
            (true, Some(since)) => Some(since),
            (true, None) => Some(now),
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SID: &str = "6f1c2a7e-0000-4000-8000-000000000001";

    /// The format, pinned as text. The Swift mirror pins the same strings; a field renamed on
    /// one side shows up here, not as a tunnel that silently never opens.
    #[test]
    fn a_pow_refusal_carries_its_difficulty() {
        assert_eq!(pow_reason(20), "pow 20");
        assert_eq!(pow_required("pow 20"), Some(20));
        assert_eq!(pow_required("pow"), None);
        assert_eq!(pow_required("powder 3"), None);
        assert_eq!(pow_required("not matrix"), None);
        assert_eq!(pow_required("pow 24"), Some(24));
        assert_eq!(pow_required("pow 25"), None, "past the ceiling is as good as nothing");
        StreamFrame::rst(SID, &pow_reason(MAX_POW_BITS)).validate().unwrap();
    }

    #[test]
    fn frames_are_exactly_this_json() {
        let cases = [
            (
                StreamFrame::open(SID, "matrix-client.matrix.org", 443, b"hi"),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"open","host":"matrix-client.matrix.org","port":443,"seq":0,"data":"aGk="}"#,
            ),
            (
                StreamFrame::opened(SID),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"opened"}"#,
            ),
            (
                StreamFrame::data(SID, 7, b"hi"),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"data","seq":7,"data":"aGk="}"#,
            ),
            (
                StreamFrame::ack(SID, 12),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"ack","ack":12}"#,
            ),
            (
                StreamFrame::fin(SID, 13),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"fin","seq":13}"#,
            ),
            (
                StreamFrame::rst(SID, reason::NOT_MATRIX),
                r#"{"v":2,"sid":"6f1c2a7e-0000-4000-8000-000000000001","op":"rst","reason":"not matrix"}"#,
            ),
        ];
        for (frame, json) in cases {
            frame.validate().unwrap();
            assert_eq!(serde_json::to_string(&frame).unwrap(), json);
            assert_eq!(serde_json::from_str::<StreamFrame>(json).unwrap(), frame);
        }
    }

    #[test]
    fn a_frame_with_a_field_its_op_does_not_carry_is_refused() {
        let mut ack = StreamFrame::ack(SID, 3);
        ack.seq = Some(3);
        assert!(ack.validate().is_err());

        let mut data = StreamFrame::data(SID, 1, b"x");
        data.host = Some("matrix.org".into());
        assert!(data.validate().is_err());
    }

    #[test]
    fn a_frame_missing_a_field_its_op_needs_is_refused() {
        let mut open = StreamFrame::open(SID, "matrix.org", 443, b"x");
        open.port = None;
        assert!(open.validate().is_err());

        let mut data = StreamFrame::data(SID, 1, b"x");
        data.seq = None;
        assert!(data.validate().is_err());
    }

    #[test]
    fn open_is_segment_zero_and_nothing_else() {
        let mut open = StreamFrame::open(SID, "matrix.org", 443, b"x");
        open.seq = Some(1);
        assert!(open.validate().is_err());
    }

    #[test]
    fn a_v1_or_future_frame_is_refused() {
        for v in [1, 3] {
            let mut frame = StreamFrame::opened(SID);
            frame.v = v;
            assert!(matches!(
                frame.validate(),
                Err(ProtoError::UnsupportedVersion(_))
            ));
        }
    }

    #[test]
    fn an_oversized_segment_is_refused_before_it_is_decoded() {
        let frame = StreamFrame::data(SID, 1, &vec![0; MAX_SEGMENT + 3]);
        assert!(frame.validate().is_err());
        StreamFrame::data(SID, 1, &vec![0; MAX_SEGMENT])
            .validate()
            .unwrap();
    }

    #[test]
    fn a_full_segment_fits_one_nip44_payload() {
        let frame = StreamFrame::data(SID, u32::MAX, &vec![0xff; crate::DEFAULT_SEGMENT]);
        let json = serde_json::to_vec(&frame).unwrap();
        assert!(
            json.len() < crate::MAX_NIP44_PLAINTEXT,
            "{} bytes",
            json.len()
        );
    }

    // ---- The receiver: the same questions the Swift implementation is asked. ----

    fn seg(n: u8) -> Vec<u8> {
        vec![n; 10]
    }

    #[test]
    fn in_order_segments_go_straight_out() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        assert_eq!(inbound.accept(0, seg(0), now).unwrap(), vec![seg(0)]);
        assert_eq!(inbound.accept(1, seg(1), now).unwrap(), vec![seg(1)]);
        assert!(!inbound.gap_expired(now + GAP_TIMEOUT * 2));
    }

    /// Segment 2 before 1: held, then both go out, in order, when 1 arrives.
    #[test]
    fn a_reordered_segment_waits_for_the_hole_and_then_both_go() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        assert!(inbound.accept(2, seg(2), now).unwrap().is_empty());
        assert_eq!(
            inbound.accept(1, seg(1), now).unwrap(),
            vec![seg(1), seg(2)]
        );
        assert!(inbound.gap_deadline().is_none());
    }

    #[test]
    fn a_duplicate_is_nothing_whether_delivered_or_held() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        inbound.accept(2, seg(2), now).unwrap();
        assert!(inbound.accept(0, seg(0), now).unwrap().is_empty());
        assert!(inbound.accept(2, seg(2), now).unwrap().is_empty());
        assert_eq!(
            inbound.accept(1, seg(1), now).unwrap(),
            vec![seg(1), seg(2)]
        );
    }

    /// A segment no relay delivered never comes. The hole is a reset, not a wait.
    #[test]
    fn a_hole_is_given_up_on_after_the_gap_timeout() {
        let mut inbound = Inbound::new();
        let start = Instant::now();
        inbound.accept(0, seg(0), start).unwrap();
        inbound.accept(2, seg(2), start).unwrap();
        assert!(!inbound.gap_expired(start + GAP_TIMEOUT - Duration::from_millis(1)));
        assert!(inbound.gap_expired(start + GAP_TIMEOUT));
    }

    /// A stream with two holes that fills one keeps going: progress restarts the clock.
    #[test]
    fn progress_restarts_the_gap_clock() {
        let mut inbound = Inbound::new();
        let start = Instant::now();
        inbound.accept(1, seg(1), start).unwrap();
        inbound.accept(3, seg(3), start).unwrap();
        let later = start + Duration::from_secs(4);
        inbound.accept(0, seg(0), later).unwrap();
        assert!(!inbound.gap_expired(start + GAP_TIMEOUT));
        assert!(inbound.gap_expired(later + GAP_TIMEOUT));
    }

    /// `fin` can overtake the last `data` — different relays, different speeds.
    #[test]
    fn fin_before_the_last_data_waits_for_it() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        assert!(!inbound.finish(2, now).unwrap());
        assert!(
            inbound.gap_deadline().is_some(),
            "a fin ahead of the data is a hole too"
        );
        assert_eq!(inbound.accept(1, seg(1), now).unwrap(), vec![seg(1)]);
        assert!(inbound.is_complete());
        assert!(inbound.gap_deadline().is_none());
    }

    #[test]
    fn a_duplicate_fin_is_fine_and_a_different_one_is_not() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        assert!(inbound.finish(1, now).unwrap());
        assert!(inbound.finish(1, now).unwrap());
        assert_eq!(inbound.finish(2, now), Err(Violation::FinMoved));
    }

    #[test]
    fn data_at_or_after_fin_is_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        inbound.finish(1, now).unwrap();
        assert_eq!(inbound.accept(1, seg(1), now), Err(Violation::DataAfterFin));
    }

    #[test]
    fn a_fin_below_what_exists_is_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        inbound.accept(0, seg(0), now).unwrap();
        inbound.accept(1, seg(1), now).unwrap();
        assert_eq!(inbound.finish(1, now), Err(Violation::FinMoved));

        let mut held = Inbound::new();
        held.accept(3, seg(3), now).unwrap();
        assert_eq!(held.finish(3, now), Err(Violation::FinMoved));
    }

    #[test]
    fn a_segment_past_the_window_is_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        assert_eq!(
            inbound.accept(WINDOW_SEGMENTS, seg(0), now),
            Err(Violation::BeyondWindow)
        );
        inbound.accept(WINDOW_SEGMENTS - 1, seg(0), now).unwrap();
    }

    /// A sender that ignores acknowledgements is refused even when it sends in order: what has
    /// not reached the socket counts against the window as much as what is waiting on a hole.
    #[test]
    fn in_order_segments_past_an_unwritten_window_are_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        for seq in 0..WINDOW_SEGMENTS {
            assert_eq!(inbound.accept(seq, seg(0), now).unwrap().len(), 1);
        }
        assert_eq!(
            inbound.accept(WINDOW_SEGMENTS, seg(0), now),
            Err(Violation::BeyondWindow)
        );
        inbound.written(1, 10);
        assert_eq!(
            inbound.accept(WINDOW_SEGMENTS, seg(0), now).unwrap().len(),
            1
        );
    }

    #[test]
    fn unwritten_bytes_past_the_window_are_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        let big = vec![0; MAX_SEGMENT];
        let mut seq = 0;
        let refused = loop {
            match inbound.accept(seq, big.clone(), now) {
                Ok(_) => seq += 1,
                Err(violation) => break violation,
            }
        };
        assert_eq!(refused, Violation::BeyondWindow);
        inbound.written(seq, seq as usize * MAX_SEGMENT);
        inbound.accept(seq, big, now).unwrap();
    }

    #[test]
    fn held_bytes_past_the_window_are_a_violation() {
        let mut inbound = Inbound::new();
        let now = Instant::now();
        let big = vec![0; MAX_SEGMENT];
        let mut seq = 1;
        let refused = loop {
            match inbound.accept(seq, big.clone(), now) {
                Ok(_) => seq += 1,
                Err(violation) => break violation,
            }
        };
        assert_eq!(refused, Violation::BeyondWindow);
        assert!((seq as usize) * MAX_SEGMENT > WINDOW_BYTES);
    }

    #[test]
    fn acks_come_every_eight_segments() {
        let mut inbound = Inbound::new();
        for n in 1..ACK_EVERY_SEGMENTS {
            assert_eq!(inbound.written(1, 10), None, "segment {n}");
        }
        assert_eq!(inbound.written(1, 10), Some(ACK_EVERY_SEGMENTS));
        assert_eq!(inbound.written(1, 10), None);
    }

    #[test]
    fn or_every_quarter_mebibyte() {
        let mut inbound = Inbound::new();
        assert_eq!(inbound.written(1, ACK_EVERY_BYTES - 1), None);
        assert_eq!(inbound.written(1, 1), Some(2));
    }

    // ---- The sender. ----

    #[test]
    fn the_window_closes_at_its_byte_limit_and_an_ack_opens_it() {
        let mut outbound = Outbound::after_open(100);
        let chunk = 24 * 1024;
        while outbound.has_room(chunk) {
            outbound.push(chunk);
        }
        assert!(outbound.unacked_bytes() + chunk > WINDOW_BYTES);
        let sent = outbound.next_seq();
        outbound.ack(sent).unwrap();
        assert_eq!(outbound.unacked_bytes(), 0);
        assert!(outbound.has_room(chunk));
    }

    #[test]
    fn the_window_closes_at_its_segment_limit_however_small_they_are() {
        let mut outbound = Outbound::default();
        while outbound.is_open() {
            outbound.push(1);
        }
        assert_eq!(outbound.next_seq(), WINDOW_SEGMENTS);
        outbound.ack(1).unwrap();
        assert!(outbound.is_open());
    }

    #[test]
    fn an_empty_window_admits_one_segment_of_any_size() {
        let outbound = Outbound::default();
        assert!(outbound.has_room(WINDOW_BYTES * 4));
    }

    /// A late ack from a slow relay is old news, not a violation.
    #[test]
    fn a_stale_ack_changes_nothing() {
        let mut outbound = Outbound::default();
        for _ in 0..4 {
            outbound.push(10);
        }
        outbound.ack(3).unwrap();
        outbound.ack(1).unwrap();
        assert_eq!(outbound.unacked_bytes(), 10);
    }

    #[test]
    fn an_ack_beyond_what_was_sent_is_a_violation() {
        let mut outbound = Outbound::default();
        outbound.push(10);
        assert_eq!(outbound.ack(2), Err(Violation::AckBeyondSent));
        outbound.ack(1).unwrap();
    }

    /// The two halves together: a sender that respects the window can never make a receiver
    /// refuse, whatever order the relays deliver in.
    #[test]
    fn a_sender_inside_its_window_never_trips_the_receiver() {
        let mut outbound = Outbound::default();
        let mut inbound = Inbound::new();
        let now = Instant::now();
        let mut queued: Vec<(u32, Vec<u8>)> = Vec::new();
        let mut delivered = 0;
        for round in 0..20 {
            while outbound.has_room(24 * 1024) {
                let seq = outbound.push(24 * 1024);
                queued.push((seq, vec![round as u8; 24 * 1024]));
            }
            // Delivered newest first: the worst order there is.
            for (seq, bytes) in queued.drain(..).rev() {
                let ready = inbound.accept(seq, bytes, now).unwrap();
                for segment in ready {
                    delivered += 1;
                    if let Some(ack) = inbound.written(1, segment.len()) {
                        outbound.ack(ack).unwrap();
                    }
                }
            }
        }
        assert_eq!(delivered, outbound.next_seq());
    }
}
