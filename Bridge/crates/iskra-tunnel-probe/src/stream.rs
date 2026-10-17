//! Streams over nostr, and an HTTP `CONNECT` proxy in front of them.
//!
//! What `NostrStreamTunnel` and `LocalConnectProxy` will do in Swift, done here first so the blind
//! bridge can be proven end to end — with a real TLS client on top and, through
//! [`StreamClient::serve_connect`], with reqwest itself: the HTTP client inside the Matrix SDK,
//! talking to an ordinary `http://` proxy and never knowing there is nostr underneath.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::Result;
use base64::prelude::{Engine as _, BASE64_STANDARD};
use iskra_tunnel_proto::stream::COALESCE;
use iskra_tunnel_proto::{
    new_stream_id, open_frame, reason, seal_frame, Inbound, Outbound, StreamFrame, StreamOp,
    DEFAULT_SEGMENT, KIND_STREAM_BRIDGE, KIND_STREAM_CLIENT,
};
use nostr_sdk::prelude::*;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

type Routes = Arc<Mutex<HashMap<String, mpsc::UnboundedSender<StreamFrame>>>>;

/// How a stream ended, as far as this side knows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Both halves closed in order.
    Closed,
    /// Reset, with the reason — the bridge's word for it when the bridge sent it.
    Reset(String),
}

/// One stream. Read and write `io` as if it were the TCP connection to the host; `outcome` says
/// how it ended once it has.
pub struct TunnelStream {
    pub io: DuplexStream,
    pub outcome: oneshot::Receiver<Outcome>,
}

pub struct StreamClient {
    shared: Arc<Shared>,
    dispatch: JoinHandle<()>,
}

struct Shared {
    keys: Keys,
    bridge: PublicKey,
    client: Client,
    routes: Routes,
}

impl StreamClient {
    /// Connect, subscribe once, and start one dispatcher for the life of the connection.
    ///
    /// One subscription, not one per stream: a subscription per stream leaves the Nth stream with
    /// N live subscriptions on every relay, each delivering its own copy of every frame, and relays
    /// are entitled to start refusing them.
    ///
    /// One reader, not one per stream, for a sharper reason. Notifications arrive on a bounded
    /// broadcast channel. Give every stream its own receiver and each one sees *every* other
    /// stream's traffic, so the work is quadratic in streams open and the channel overflows under
    /// load — at which point a receiver is handed `Lagged`, and frames that did arrive are lost to
    /// the stream waiting for them. Here one reader drains the channel and routes each frame by
    /// its stream id.
    pub async fn connect(keys: Keys, bridge: PublicKey, relays: &[String]) -> Result<Self> {
        let client = Client::new(keys.clone());
        for relay in relays {
            client.add_relay(relay).await?;
        }
        client.connect().await;
        let notifications = client.notifications();
        let filter = Filter::new()
            .kind(Kind::Custom(KIND_STREAM_BRIDGE))
            .author(bridge)
            .pubkey(keys.public_key())
            .since(Timestamp::now());
        client.subscribe(filter, None).await?;

        let routes: Routes = Arc::new(Mutex::new(HashMap::new()));
        let dispatch = tokio::spawn(dispatch(
            notifications,
            keys.secret_key().clone(),
            bridge,
            Arc::clone(&routes),
        ));
        Ok(Self {
            shared: Arc::new(Shared {
                keys,
                bridge,
                client,
                routes,
            }),
            dispatch,
        })
    }

    pub fn public_key(&self) -> PublicKey {
        self.shared.keys.public_key()
    }

    /// A stream to `host:port`. Nothing is sent until the first bytes are written to `io`: they
    /// ride in the `open`, so a cold connection costs no extra trip through a relay.
    pub fn open(&self, host: &str, port: u16) -> TunnelStream {
        let sid = new_stream_id();
        let (theirs, ours) = tokio::io::duplex(256 * 1024);
        let (frames_tx, frames) = mpsc::unbounded_channel();
        self.shared
            .routes
            .lock()
            .expect("routes")
            .insert(sid.clone(), frames_tx);
        let (done, outcome) = oneshot::channel();
        let shared = Arc::clone(&self.shared);
        let host = host.to_string();
        tokio::spawn(async move {
            let ended = pump(&shared, &sid, &host, port, ours, frames).await;
            shared.routes.lock().expect("routes").remove(&sid);
            let _ = done.send(ended);
        });
        TunnelStream {
            io: theirs,
            outcome,
        }
    }

    /// An HTTP `CONNECT` proxy on `listener`, every connection a stream. This is what reqwest is
    /// pointed at with `Proxy::all("http://iskra:<secret>@127.0.0.1:<port>")`.
    ///
    /// `secret`, when given, must arrive as `Proxy-Authorization: Basic base64(iskra:<secret>)`,
    /// which reqwest sends by itself from the credentials in the proxy URL. Anything on the device
    /// can knock on a loopback port; without the secret the answer is `407`.
    pub async fn serve_connect(self: Arc<Self>, listener: TcpListener, secret: Option<String>) {
        let expected = secret.map(|secret| BASE64_STANDARD.encode(format!("iskra:{secret}")));
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                return;
            };
            let this = Arc::clone(&self);
            let expected = expected.clone();
            tokio::spawn(async move {
                let _ = this.proxy_one(socket, expected.as_deref()).await;
            });
        }
    }

    async fn proxy_one(&self, mut socket: TcpStream, expected: Option<&str>) -> Result<()> {
        let mut head = Vec::new();
        let mut buffer = [0u8; 2048];
        let end = loop {
            let n = socket.read(&mut buffer).await?;
            if n == 0 {
                return Ok(());
            }
            head.extend_from_slice(&buffer[..n]);
            if let Some(end) = head.windows(4).position(|w| w == b"\r\n\r\n") {
                break end + 4;
            }
            if head.len() > 8192 {
                socket.write_all(b"HTTP/1.1 431 Too Large\r\n\r\n").await?;
                return Ok(());
            }
        };
        let text = String::from_utf8_lossy(&head[..end]).to_string();
        let mut lines = text.split("\r\n");
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split(' ');
        let (Some("CONNECT"), Some(authority)) = (parts.next(), parts.next()) else {
            socket
                .write_all(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                .await?;
            return Ok(());
        };
        if let Some(expected) = expected {
            let given = lines
                .filter_map(|line| line.split_once(':'))
                .find(|(name, _)| name.trim().eq_ignore_ascii_case("proxy-authorization"))
                .and_then(|(_, value)| value.trim().split_once(' '))
                .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("basic"))
                .map(|(_, token)| token.trim().to_string());
            if given.as_deref() != Some(expected) {
                socket
                    .write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"iskra\"\r\n\r\n")
                    .await?;
                return Ok(());
            }
        }
        let Some((host, port)) = split_authority(authority) else {
            socket
                .write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n")
                .await?;
            return Ok(());
        };

        // Answered at once, before the bridge has said anything: the client's ClientHello is what
        // the `open` carries, and it does not come until this goes out.
        socket
            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
            .await?;
        let mut stream = self.open(&host, port);
        if head.len() > end {
            stream.io.write_all(&head[end..]).await?;
        }
        let _ = tokio::io::copy_bidirectional(&mut socket, &mut stream.io).await;
        Ok(())
    }

    pub async fn shutdown(&self) {
        self.dispatch.abort();
        self.shared.client.disconnect().await;
    }
}

impl Drop for StreamClient {
    fn drop(&mut self) {
        self.dispatch.abort();
    }
}

fn split_authority(authority: &str) -> Option<(String, u16)> {
    let (host, port) = authority.rsplit_once(':')?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    if host.is_empty() {
        return None;
    }
    Some((host.to_string(), port.parse().ok()?))
}

impl Shared {
    /// Published without waiting for any relay's `OK` — see the bridge's `publish` for why.
    fn publish(&self, frame: StreamFrame) {
        let Ok(content) = seal_frame(self.keys.secret_key(), &self.bridge, &frame) else {
            return;
        };
        let Ok(event) = EventBuilder::new(Kind::Custom(KIND_STREAM_CLIENT), content)
            .tag(Tag::public_key(self.bridge))
            .sign_with_keys(&self.keys)
        else {
            return;
        };
        let client = self.client.clone();
        tokio::spawn(async move {
            if let Err(error) = client.send_event(&event).await {
                tracing::debug!(%error, "no relay took a stream frame");
            }
        });
    }
}

enum Read {
    Segment(Vec<u8>),
    Eof,
    Failed,
}

async fn pump(
    shared: &Shared,
    sid: &str,
    host: &str,
    port: u16,
    local: DuplexStream,
    mut frames: mpsc::UnboundedReceiver<StreamFrame>,
) -> Outcome {
    let max = DEFAULT_SEGMENT;
    let (mut reader, mut writer) = tokio::io::split(local);

    let first = match next_segment(&mut reader, max).await {
        Ok(Some(first)) => first,
        _ => return Outcome::Closed,
    };
    shared.publish(StreamFrame::open(sid, host, port, &first));
    let mut outbound = Outbound::after_open(first.len());

    let (segments_tx, mut segments) = mpsc::channel::<Read>(1);
    let reading = tokio::spawn(async move {
        loop {
            let read = match next_segment(&mut reader, max).await {
                Ok(Some(bytes)) => Read::Segment(bytes),
                Ok(None) => Read::Eof,
                Err(_) => Read::Failed,
            };
            let last = !matches!(read, Read::Segment(_));
            if segments_tx.send(read).await.is_err() || last {
                return;
            }
        }
    });
    let _reading = AbortOnDrop(reading);

    let mut inbound = Inbound::new();
    let mut local_done = false;
    let mut remote_done = false;

    let reset = |why: &str| {
        shared.publish(StreamFrame::rst(sid, why));
        Outcome::Reset(why.to_string())
    };

    loop {
        if local_done && remote_done {
            return Outcome::Closed;
        }
        let gap = inbound
            .gap_deadline()
            .map(tokio::time::Instant::from_std)
            .unwrap_or_else(|| tokio::time::Instant::now() + std::time::Duration::from_secs(3600));
        let window_open = !local_done && outbound.has_room(max);

        tokio::select! {
            frame = frames.recv() => {
                let Some(frame) = frame else { return Outcome::Reset(reason::CLOSED.into()) };
                let now = Instant::now();
                match frame.op {
                    StreamOp::Opened => {}
                    StreamOp::Data => {
                        let Ok(bytes) = frame.payload() else { return reset(reason::PROTOCOL) };
                        match inbound.accept(frame.seq.unwrap_or(0), bytes, now) {
                            Ok(ready) => {
                                for segment in ready {
                                    if writer.write_all(&segment).await.is_err() {
                                        return reset(reason::CLOSED);
                                    }
                                    if let Some(ack) = inbound.written(1, segment.len()) {
                                        shared.publish(StreamFrame::ack(sid, ack));
                                    }
                                }
                            }
                            Err(violation) => return reset(violation.reason()),
                        }
                    }
                    StreamOp::Fin => {
                        if let Err(violation) = inbound.finish(frame.seq.unwrap_or(0), now) {
                            return reset(violation.reason());
                        }
                    }
                    StreamOp::Ack => {
                        if let Err(violation) = outbound.ack(frame.ack.unwrap_or(0)) {
                            return reset(violation.reason());
                        }
                    }
                    StreamOp::Rst => {
                        return Outcome::Reset(frame.reason.unwrap_or_default());
                    }
                    StreamOp::Open => return reset(reason::PROTOCOL),
                }
                if inbound.is_complete() && !remote_done {
                    let _ = writer.shutdown().await;
                    remote_done = true;
                }
            }
            read = segments.recv(), if window_open => match read {
                Some(Read::Segment(bytes)) => {
                    let seq = outbound.push(bytes.len());
                    shared.publish(StreamFrame::data(sid, seq, &bytes));
                }
                Some(Read::Eof) => {
                    shared.publish(StreamFrame::fin(sid, outbound.next_seq()));
                    local_done = true;
                }
                Some(Read::Failed) | None => return reset(reason::CLOSED),
            },
            _ = tokio::time::sleep_until(gap) => {
                if inbound.gap_expired(Instant::now()) {
                    return reset(reason::GAP);
                }
            }
        }
    }
}

struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// The bridge's coalescing, the same rule: what arrives without a [`COALESCE`] pause, up to `max`.
async fn next_segment<R: AsyncRead + Unpin>(
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
        match tokio::time::timeout(COALESCE, reader.read(&mut buffer[filled..])).await {
            Err(_) | Ok(Ok(0)) | Ok(Err(_)) => break,
            Ok(Ok(n)) => filled += n,
        }
    }
    buffer.truncate(filled);
    Ok(Some(buffer))
}

async fn dispatch(
    mut notifications: tokio::sync::broadcast::Receiver<RelayPoolNotification>,
    secret: SecretKey,
    bridge: PublicKey,
    routes: Routes,
) {
    loop {
        let notification = match notifications.recv().await {
            Ok(notification) => notification,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                tracing::warn!(missed, "fell behind the relay stream");
                continue;
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        };
        let RelayPoolNotification::Event { event, .. } = notification else {
            continue;
        };
        if event.kind != Kind::Custom(KIND_STREAM_BRIDGE) || event.pubkey != bridge {
            continue;
        }
        let Ok(frame) = open_frame(&secret, &bridge, &event.content) else {
            continue;
        };
        let route = routes.lock().expect("routes").get(&frame.sid).cloned();
        if let Some(route) = route {
            let _ = route.send(frame);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorities_split_including_ipv6() {
        assert_eq!(
            split_authority("matrix.org:443"),
            Some(("matrix.org".into(), 443))
        );
        assert_eq!(split_authority("[::1]:8448"), Some(("::1".into(), 8448)));
        assert_eq!(split_authority("matrix.org"), None);
        assert_eq!(split_authority(":443"), None);
    }
}
