//! The bridge as a pipe for somebody else's TLS.
//!
//! A client asks for `host:443` and sends its ClientHello in the same frame. The bridge reads the
//! server name out of it, decides whether it will go there (`blind.rs`), connects to the address it
//! checked, and from then on moves bytes it cannot read: TLS runs end to end between the SDK and
//! the homeserver, certificate checked by the SDK, and the token, the paths and the bodies are on
//! the far side of it.
//!
//! What the bridge keeps for a stream is the socket and the window, and nothing else. No cache of
//! answers, no sync on anybody's behalf — there is nothing it could cache, because it cannot see
//! what it carries.
//!
//! The log says a stream opened, closed, how many bytes it moved, how long it lived, and why it
//! ended, in one word. **Not the host** — not even on a refusal.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use iskra_tunnel_proto::stream::COALESCE;
use iskra_tunnel_proto::{
    pow_reason, reason, seal_frame, Inbound, Outbound, StreamFrame, StreamOp, Violation,
    KIND_STREAM_BRIDGE,
};
use nostr_sdk::prelude::*;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::{sleep_until, timeout};

use crate::blind::Destinations;
use crate::config::StreamLimits;
use crate::ratelimit::ByteLimit;
use crate::sni::{self, Hello};

/// A stream nothing moves on for this long is closed. Not less: sliding sync holds a long-poll
/// open for up to thirty seconds, and a connection pool keeps idle connections for a while longer.
const IDLE: Duration = Duration::from_secs(5 * 60);
/// No stream lives longer than this, however busy. A connection pool reconnects without anybody
/// noticing; a stream that never ends is a socket the bridge holds forever.
const LIFETIME: Duration = Duration::from_secs(60 * 60);
/// How long the ClientHello may take to arrive whole, from the first frame of the stream.
const HELLO_DEADLINE: Duration = Duration::from_secs(10);
/// How long connecting to the host may take, every address together.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Frames queued for one stream's task. The other side's window keeps an honest sender far below
/// this; one that fills it is not respecting the window, and the stream is reset.
const QUEUE: usize = 256;
/// How long a closed stream's id is remembered, so that a late frame — a slow relay's copy of the
/// `open` — does not open it again. And how many are remembered, at most.
const TOMBSTONE_FOR: Duration = Duration::from_secs(10 * 60);
const MAX_TOMBSTONES: usize = 16 * 1024;

type Key = (PublicKey, String);

pub struct Streams {
    shared: Arc<Shared>,
}

struct Shared {
    keys: Keys,
    client: Client,
    destinations: Destinations,
    bytes: ByteLimit,
    limits: StreamLimits,
    max_segment: usize,
    pow_bits: u8,
    table: StdMutex<Table>,
}

#[derive(Default)]
struct Table {
    live: HashMap<Key, mpsc::Sender<StreamFrame>>,
    per_client: HashMap<PublicKey, usize>,
    dead: HashMap<Key, Instant>,
}

impl Table {
    fn bury(&mut self, key: Key, now: Instant) {
        if self.dead.len() >= MAX_TOMBSTONES {
            self.dead
                .retain(|_, when| now.duration_since(*when) < TOMBSTONE_FOR);
            if self.dead.len() >= MAX_TOMBSTONES {
                self.dead.clear();
            }
        }
        self.dead.insert(key, now);
    }

    fn is_dead(&self, key: &Key, now: Instant) -> bool {
        self.dead
            .get(key)
            .is_some_and(|when| now.duration_since(*when) < TOMBSTONE_FOR)
    }

    fn remove(&mut self, key: &Key) {
        if self.live.remove(key).is_some() {
            if let Some(count) = self.per_client.get_mut(&key.0) {
                *count -= 1;
                if *count == 0 {
                    self.per_client.remove(&key.0);
                }
            }
        }
    }
}

impl Streams {
    pub fn new(
        keys: Keys,
        client: Client,
        destinations: Destinations,
        limits: StreamLimits,
        max_segment: usize,
        pow_bits: u8,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                keys,
                client,
                bytes: ByteLimit::new(limits.bytes_per_min, limits.bytes_per_min_total),
                destinations,
                limits,
                max_segment,
                pow_bits,
                table: StdMutex::new(Table::default()),
            }),
        }
    }

    /// Streams open right now.
    pub fn open_count(&self) -> usize {
        self.shared.table.lock().expect("stream table").live.len()
    }

    /// Forget what is old enough to forget: quiet clients' byte allowances, old tombstones.
    pub fn tidy(&self) {
        self.shared.bytes.retain_recent();
        self.shared.destinations.tidy();
        let now = Instant::now();
        self.shared
            .table
            .lock()
            .expect("stream table")
            .dead
            .retain(|_, when| now.duration_since(*when) < TOMBSTONE_FOR);
    }

    /// Hand one decrypted, validated frame to its stream — opening the stream if it is an `open`
    /// the bridge has not heard before, mined to `pow` NIP-13 bits.
    ///
    /// Called from the relay loop and never awaits: one slow stream must not stop the bridge
    /// hearing the rest.
    pub fn deliver(&self, from: PublicKey, frame: StreamFrame, pow: u8) {
        let key = (from, frame.sid.clone());
        let now = Instant::now();
        let mut table = self.shared.table.lock().expect("stream table");

        if table.is_dead(&key, now) {
            return;
        }
        if let Some(queue) = table.live.get(&key) {
            match queue.try_send(frame) {
                Ok(()) => {}
                Err(mpsc::error::TrySendError::Full(_)) => {
                    // Dropping the sender ends the task, which says why in the log.
                    table.remove(&key);
                    table.bury(key.clone(), now);
                    drop(table);
                    tracing::info!(client = %from, reason = reason::WINDOW, "stream flooded");
                    self.shared.publish(&from, StreamFrame::rst(&key.1, reason::WINDOW));
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {}
            }
            return;
        }

        // Only an `open` starts a stream: it is the one frame that carries proof of work, and a
        // stream started by anything else would be a stream started for free. A segment that
        // overtook its `open` on a faster relay is lost, and the hole it leaves resets the stream;
        // the client sends nothing after the ClientHello until the server answers, so this is
        // rare, and cheap when it happens.
        if frame.op != StreamOp::Open {
            return;
        }
        if pow < self.shared.pow_bits {
            table.bury(key.clone(), now);
            drop(table);
            tracing::info!(client = %from, reason = reason::POW, "stream refused");
            self.shared
                .publish(&from, StreamFrame::rst(&key.1, &pow_reason(self.shared.pow_bits)));
            return;
        }
        let mine = table.per_client.get(&from).copied().unwrap_or(0);
        if mine >= self.shared.limits.per_client || table.live.len() >= self.shared.limits.total {
            table.bury(key.clone(), now);
            drop(table);
            tracing::info!(client = %from, reason = reason::BUSY, "stream refused");
            // Said out loud, never silence: the client has to tell "busy" from "down".
            self.shared
                .publish(&from, StreamFrame::rst(&key.1, reason::BUSY));
            return;
        }

        let (queue, frames) = mpsc::channel(QUEUE);
        queue.try_send(frame).expect("a fresh queue has room");
        table.live.insert(key.clone(), queue);
        *table.per_client.entry(from).or_insert(0) += 1;
        drop(table);

        let shared = Arc::clone(&self.shared);
        tokio::spawn(async move {
            let started = Instant::now();
            let mut tally = Tally::default();
            let ended = run(Arc::clone(&shared), from, &key.1, frames, &mut tally).await;
            {
                let mut table = shared.table.lock().expect("stream table");
                table.remove(&key);
                table.bury(key.clone(), Instant::now());
            }
            if let Ended::Reset(reason) = ended {
                shared.publish(&from, StreamFrame::rst(&key.1, reason));
            }
            tracing::info!(
                client = %from,
                reason = ended.as_str(),
                up_bytes = tally.up,
                down_bytes = tally.down,
                lived_ms = started.elapsed().as_millis() as u64,
                "stream closed"
            );
        });
    }
}

impl Shared {
    /// Seal one frame and publish it to every relay — **without waiting for any of them to say
    /// `OK`**. What the other side waits for is the next frame, not this one's acknowledgement,
    /// and `send_event` waits ten seconds on a relay that is down. A stream that waited would move
    /// at the pace of the slowest relay in the list.
    fn publish(&self, to: &PublicKey, frame: StreamFrame) {
        let content = match seal_frame(self.keys.secret_key(), to, &frame) {
            Ok(content) => content,
            Err(error) => {
                tracing::warn!(%error, "a stream frame did not seal");
                return;
            }
        };
        let event = match EventBuilder::new(Kind::Custom(KIND_STREAM_BRIDGE), content)
            .tag(Tag::public_key(*to))
            .sign_with_keys(&self.keys)
        {
            Ok(event) => event,
            Err(error) => {
                tracing::warn!(%error, "a stream frame did not sign");
                return;
            }
        };
        let client = self.client.clone();
        tokio::spawn(async move {
            if let Err(error) = client.send_event(&event).await {
                tracing::debug!(%error, "a stream frame was not published");
            }
        });
    }
}

#[derive(Default)]
struct Tally {
    /// Client → host.
    up: usize,
    /// Host → client.
    down: usize,
}

/// How a stream ended.
enum Ended {
    /// Both halves closed in order.
    Closed,
    /// The client reset it, or went away.
    ByClient,
    /// The bridge reset it, for this reason — sent to the client on the way out.
    Reset(&'static str),
    /// Dropped by the table for flooding its queue; the `rst` has already gone.
    Flooded,
}

impl Ended {
    fn as_str(&self) -> &'static str {
        match self {
            Ended::Closed => "closed",
            Ended::ByClient => "reset by client",
            Ended::Reset(reason) => reason,
            Ended::Flooded => reason::WINDOW,
        }
    }
}

impl From<Violation> for Ended {
    fn from(violation: Violation) -> Self {
        Ended::Reset(violation.reason())
    }
}

/// One stream, start to finish.
async fn run(
    shared: Arc<Shared>,
    client: PublicKey,
    sid: &str,
    mut frames: mpsc::Receiver<StreamFrame>,
    tally: &mut Tally,
) -> Ended {
    let started = Instant::now();
    let mut inbound = Inbound::new();

    // ---- Until the ClientHello is whole: no socket, nothing resolved, nothing promised. ----
    let mut target: Option<(String, u16)> = None;
    let mut prefix = Vec::new();
    let mut prefix_segments = 0u32;
    let hello_deadline = tokio::time::Instant::from_std(started + HELLO_DEADLINE);

    let (host, port) = loop {
        let deadline = earliest(Some(hello_deadline), inbound.gap_deadline());
        let frame = tokio::select! {
            frame = frames.recv() => frame,
            _ = sleep_until(deadline) => {
                return Ended::Reset(if inbound.gap_expired(Instant::now()) { reason::GAP } else { reason::NOT_TLS });
            }
        };
        let Some(frame) = frame else {
            return Ended::Flooded;
        };
        let now = Instant::now();
        match frame.op {
            StreamOp::Open => {
                let asked = (
                    frame.host.clone().unwrap_or_default(),
                    frame.port.unwrap_or(0),
                );
                if target.as_ref().is_some_and(|known| *known != asked) {
                    return Ended::Reset(reason::PROTOCOL);
                }
                target = Some(asked);
                let Ok(bytes) = frame.payload() else {
                    return Ended::Reset(reason::PROTOCOL);
                };
                match inbound.accept(0, bytes, now) {
                    Ok(ready) => take_into(&mut prefix, &mut prefix_segments, ready),
                    Err(violation) => return violation.into(),
                }
            }
            StreamOp::Data => {
                let Ok(bytes) = frame.payload() else {
                    return Ended::Reset(reason::PROTOCOL);
                };
                match inbound.accept(frame.seq.unwrap_or(0), bytes, now) {
                    Ok(ready) => take_into(&mut prefix, &mut prefix_segments, ready),
                    Err(violation) => return violation.into(),
                }
            }
            StreamOp::Fin => {
                if let Err(violation) = inbound.finish(frame.seq.unwrap_or(0), now) {
                    return violation.into();
                }
            }
            StreamOp::Rst => return Ended::ByClient,
            // Nothing has been sent, so nothing can be acknowledged; and `opened` is the bridge's.
            StreamOp::Ack if frame.ack == Some(0) => {}
            StreamOp::Ack | StreamOp::Opened => return Ended::Reset(reason::PROTOCOL),
        }

        let Some((host, port)) = &target else {
            continue;
        };
        match sni::parse(&prefix) {
            Hello::Incomplete if prefix.len() < sni::MAX_HELLO && !inbound.is_complete() => {
                continue
            }
            Hello::Incomplete | Hello::NotTls => return Ended::Reset(reason::NOT_TLS),
            Hello::Unnamed => return Ended::Reset(reason::NO_SNI),
            Hello::Named(name) if name != sni::normalise(host) => {
                return Ended::Reset(reason::SNI_MISMATCH)
            }
            Hello::Named(_) => break (host.clone(), *port),
        }
    };

    // ---- Where, and whether. Then a connection to exactly the address that was judged. ----
    let addresses = match shared.destinations.admit(&client, &host, port).await {
        Ok(addresses) => addresses,
        Err(refusal) => return Ended::Reset(refusal.as_str()),
    };
    let socket = match timeout(CONNECT_TIMEOUT, connect_any(&addresses)).await {
        Ok(Some(socket)) => socket,
        _ => return Ended::Reset(reason::UNREACHABLE),
    };
    let _ = socket.set_nodelay(true);
    shared.publish(&client, StreamFrame::opened(sid));
    tracing::info!(client = %client, "stream opened");

    let (read_half, mut write_half) = socket.into_split();

    // Host → client. One segment at a time through a queue of one, so that a full window is a
    // reader that is not being listened to — and so a socket that is not being read.
    let (segments_tx, mut segments) = mpsc::channel::<Read>(1);
    let reader = tokio::spawn(read_upstream(
        read_half,
        shared.max_segment,
        segments_tx,
        Arc::clone(&shared),
        client,
    ));
    let _reader = AbortOnDrop(reader);

    // Client → host. Written in order, then reported back so that `ack` follows the socket.
    let (jobs_tx, mut jobs) = mpsc::unbounded_channel::<Job>();
    let (done_tx, mut done) = mpsc::unbounded_channel::<Done>();
    let limits = Arc::clone(&shared);
    let writer = tokio::spawn(async move {
        while let Some(job) = jobs.recv().await {
            match job {
                Job::Write { bytes, segments } => {
                    // Over the allowance, this waits — and while it waits nothing is acknowledged,
                    // so the client's window closes and its own socket stops being read.
                    limits.bytes.take(&client, bytes.len()).await;
                    if write_half.write_all(&bytes).await.is_err() {
                        let _ = done_tx.send(Done::Failed);
                        return;
                    }
                    let _ = done_tx.send(Done::Written {
                        segments,
                        bytes: bytes.len(),
                    });
                }
                Job::Shutdown => {
                    let _ = write_half.shutdown().await;
                    let _ = done_tx.send(Done::ShutDown);
                    return;
                }
            }
        }
    });
    let _writer = AbortOnDrop(writer);

    send(std::mem::take(&mut prefix), prefix_segments, &jobs_tx);
    let mut shutdown_queued = false;
    if inbound.is_complete() {
        let _ = jobs_tx.send(Job::Shutdown);
        shutdown_queued = true;
    }

    let mut outbound = Outbound::default();
    let mut upstream_done = false;
    let mut client_done = false;
    let mut last_activity = Instant::now();
    let lifetime = tokio::time::Instant::from_std(started + LIFETIME);

    loop {
        if upstream_done && client_done {
            return Ended::Closed;
        }
        let idle = tokio::time::Instant::from_std(last_activity + IDLE);
        let deadline = earliest(Some(idle.min(lifetime)), inbound.gap_deadline());
        let window_open = !upstream_done && outbound.has_room(shared.max_segment);

        tokio::select! {
            frame = frames.recv() => {
                let Some(frame) = frame else { return Ended::Flooded };
                last_activity = Instant::now();
                match frame.op {
                    StreamOp::Data | StreamOp::Open => {
                        let Ok(bytes) = frame.payload() else { return Ended::Reset(reason::PROTOCOL) };
                        let seq = frame.seq.unwrap_or(0);
                        match inbound.accept(seq, bytes, last_activity) {
                            Ok(ready) => {
                                let segments = ready.len() as u32;
                                send(ready.concat(), segments, &jobs_tx);
                            }
                            Err(violation) => return violation.into(),
                        }
                    }
                    StreamOp::Fin => match inbound.finish(frame.seq.unwrap_or(0), last_activity) {
                        Ok(_) => {}
                        Err(violation) => return violation.into(),
                    },
                    StreamOp::Ack => {
                        if let Err(violation) = outbound.ack(frame.ack.unwrap_or(0)) {
                            return violation.into();
                        }
                    }
                    StreamOp::Rst => return Ended::ByClient,
                    StreamOp::Opened => return Ended::Reset(reason::PROTOCOL),
                }
                if inbound.is_complete() && !shutdown_queued {
                    let _ = jobs_tx.send(Job::Shutdown);
                    shutdown_queued = true;
                }
            }
            read = segments.recv(), if window_open => {
                last_activity = Instant::now();
                match read {
                    Some(Read::Segment(bytes)) => {
                        let seq = outbound.push(bytes.len());
                        tally.down += bytes.len();
                        shared.publish(&client, StreamFrame::data(sid, seq, &bytes));
                    }
                    Some(Read::Eof) => {
                        shared.publish(&client, StreamFrame::fin(sid, outbound.next_seq()));
                        upstream_done = true;
                    }
                    Some(Read::Failed) | None => return Ended::Reset(reason::UPSTREAM),
                }
            }
            // Not once the writer has shut down: it is gone then, and its closed queue would read
            // as a broken upstream while the host is still answering.
            result = done.recv(), if !client_done => {
                match result {
                    Some(Done::Written { segments, bytes }) => {
                        tally.up += bytes;
                        if let Some(ack) = inbound.written(segments, bytes) {
                            shared.publish(&client, StreamFrame::ack(sid, ack));
                        }
                    }
                    Some(Done::ShutDown) => client_done = true,
                    Some(Done::Failed) | None => return Ended::Reset(reason::UPSTREAM),
                }
            }
            _ = sleep_until(deadline) => {
                let now = Instant::now();
                if inbound.gap_expired(now) {
                    return Ended::Reset(reason::GAP);
                }
                if now >= started + LIFETIME {
                    return Ended::Reset(reason::EXPIRED);
                }
                if now >= last_activity + IDLE {
                    return Ended::Reset(reason::IDLE);
                }
            }
        }
    }
}

fn send(bytes: Vec<u8>, segments: u32, jobs: &mpsc::UnboundedSender<Job>) {
    if !bytes.is_empty() || segments > 0 {
        let _ = jobs.send(Job::Write { bytes, segments });
    }
}

/// The host's side of the socket, as segments, paced by the byte allowance. Stops at the first
/// end or error, and says which.
async fn read_upstream(
    mut socket: tokio::net::tcp::OwnedReadHalf,
    max: usize,
    out: mpsc::Sender<Read>,
    shared: Arc<Shared>,
    client: PublicKey,
) {
    loop {
        let read = match next_segment(&mut socket, max).await {
            Ok(Some(bytes)) => {
                shared.bytes.take(&client, bytes.len()).await;
                Read::Segment(bytes)
            }
            Ok(None) => Read::Eof,
            Err(_) => Read::Failed,
        };
        let last = !matches!(read, Read::Segment(_));
        if out.send(read).await.is_err() || last {
            return;
        }
    }
}

/// Segments that became contiguous before the socket exists wait in the prefix.
fn take_into(prefix: &mut Vec<u8>, segments: &mut u32, ready: Vec<Vec<u8>>) {
    for segment in ready {
        prefix.extend_from_slice(&segment);
        *segments += 1;
    }
}

fn earliest(a: Option<tokio::time::Instant>, b: Option<Instant>) -> tokio::time::Instant {
    let b = b.map(tokio::time::Instant::from_std);
    match (a, b) {
        (Some(a), Some(b)) => a.min(b),
        (Some(a), None) => a,
        (None, Some(b)) => b,
        (None, None) => tokio::time::Instant::now() + LIFETIME,
    }
}

async fn connect_any(addresses: &[SocketAddr]) -> Option<TcpStream> {
    for address in addresses {
        if let Ok(socket) = TcpStream::connect(address).await {
            return Some(socket);
        }
    }
    None
}

enum Read {
    Segment(Vec<u8>),
    Eof,
    Failed,
}

enum Job {
    Write { bytes: Vec<u8>, segments: u32 },
    Shutdown,
}

enum Done {
    Written { segments: u32, bytes: usize },
    ShutDown,
    Failed,
}

struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Read a socket into segments: as much as arrives without a pause of [`COALESCE`], up to `max`.
///
/// One event per `read` would be an event per TLS record — a few hundred bytes each, hundreds of
/// events for one room — and public relays ban for less.
pub(crate) async fn next_segment<R: AsyncRead + Unpin>(
    reader: &mut R,
    max: usize,
) -> std::io::Result<Option<Vec<u8>>> {
    let mut buffer = vec![0; max.max(1)];
    let first = reader.read(&mut buffer).await?;
    if first == 0 {
        return Ok(None);
    }
    let mut filled = first;
    while filled < buffer.len() {
        match timeout(COALESCE, reader.read(&mut buffer[filled..])).await {
            Err(_) | Ok(Ok(0)) => break,
            Ok(Ok(n)) => filled += n,
            // What was read is still owed; the error comes back on the next call.
            Ok(Err(_)) => break,
        }
    }
    buffer.truncate(filled);
    Ok(Some(buffer))
}
