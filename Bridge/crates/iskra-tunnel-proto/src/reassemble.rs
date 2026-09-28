//! Putting the chunks back together, from whoever sends them.
//!
//! Everything here arrives from a relay, which is to say from anybody, so this is written as if
//! the sender were hostile rather than merely buggy. Three things follow from that and none of
//! them are optional:
//!
//! - **Duplicates are normal.** An event is published to every relay and comes back from every
//!   relay, so the same chunk arrives several times. It is not an error and must not count twice
//!   against anything.
//! - **Partial messages are held in memory, so they are capped** — in chunks, in bytes, in how
//!   many may be open at once, and in how long one may stay open. An uncapped reassembler is a
//!   bridge that anybody can exhaust by starting ten thousand messages and finishing none.
//! - **Nothing is assumed about order.** Chunk 7 may arrive before chunk 0, which means the head —
//!   the method, the path, the status — may not be there yet when a body chunk is.

use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

use crate::Envelope;

/// What the reassembler does with a chunk.
#[derive(Debug)]
pub enum Accepted {
    /// Every chunk is in. The head envelope, and the body it describes.
    Complete { head: Envelope, body: Vec<u8> },
    /// Taken, and waiting for the rest.
    Waiting,
    /// Dropped, with the reason — for the log, never for the sender.
    Refused(&'static str),
}

/// The ceilings. Chosen to be generous for a Matrix session and mean for a flood.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Most chunks one message may be cut into.
    pub max_chunks: u32,
    /// Most bytes one message may add up to, after decoding.
    pub max_bytes: usize,
    /// Most messages that may be half-arrived at once, across all senders.
    pub max_in_flight: usize,
    /// How long a half-arrived message is kept before it is forgotten.
    pub ttl: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            // 512 × 24 KiB is 12 MB of chunks for an 8 MB ceiling: the chunk count is not the
            // binding limit, the byte count is, and both are checked.
            max_chunks: 512,
            max_bytes: 8 * 1024 * 1024,
            max_in_flight: 64,
            ttl: Duration::from_secs(60),
        }
    }
}

struct Partial {
    total: u32,
    /// By sequence number. `None` until that chunk arrives, which is also how a duplicate is
    /// recognised — the slot is already full.
    chunks: Vec<Option<Vec<u8>>>,
    head: Option<Envelope>,
    bytes: usize,
    arrived: u32,
    started: Instant,
}

/// Collects chunks until a message is whole.
///
/// `K` is whatever tells two senders apart. The bridge keys by (client, message id), because the
/// id is chosen by the client and two clients may pick the same one; the app keys by id alone,
/// having exactly one peer.
pub struct Reassembler<K: Eq + Hash + Clone> {
    partials: HashMap<K, Partial>,
    /// Messages already refused, and when. Without this a refusal is not one: the next chunk of
    /// the same message finds no partial, opens a new one and starts filling it again — so a
    /// message too large to accept would be accepted, refused, reopened and refused once per
    /// chunk, and a rate-limited one would be charged and answered once per chunk.
    refused: HashMap<K, Instant>,
    limits: Limits,
}

impl<K: Eq + Hash + Clone> Reassembler<K> {
    pub fn new(limits: Limits) -> Self {
        Self {
            partials: HashMap::new(),
            refused: HashMap::new(),
            limits,
        }
    }

    pub fn in_flight(&self) -> usize {
        self.partials.len()
    }

    /// Whether this message has been seen before — half-arrived, or already refused.
    ///
    /// What the bridge asks before charging a chunk to the rate limit: a request is charged once,
    /// on the first of its chunks to arrive, not once per chunk.
    pub fn knows(&self, key: &K) -> bool {
        self.partials.contains_key(key) || self.refused.contains_key(key)
    }

    /// Refuse a message from outside — the rate limit — so that the rest of its chunks are
    /// dropped quietly instead of each reopening it.
    pub fn refuse(&mut self, key: K, now: Instant) {
        self.partials.remove(&key);
        bury(&mut self.refused, key, now);
    }

    /// Take one chunk.
    ///
    /// `now` is passed in rather than read here so that the expiry rule can be tested without
    /// sleeping through it.
    pub fn accept(&mut self, key: K, envelope: Envelope, now: Instant) -> Accepted {
        if envelope.validate().is_err() {
            return Accepted::Refused("malformed envelope");
        }
        self.expire(now);

        if self.refused.contains_key(&key) {
            return Accepted::Refused("refused earlier");
        }

        let body = match envelope.body() {
            Ok(body) => body,
            Err(_) => return Accepted::Refused("body is not base64"),
        };

        // The common case, and the one worth keeping cheap: a whole message in one chunk never
        // touches the map at all.
        if envelope.total == 1 {
            return Accepted::Complete {
                head: envelope,
                body,
            };
        }

        if envelope.total > self.limits.max_chunks {
            bury(&mut self.refused, key, now);
            return Accepted::Refused("too many chunks");
        }

        // Read before the entry is taken, because taking it borrows the map.
        let at_capacity = self.partials.len() >= self.limits.max_in_flight;

        match self.partials.entry(key) {
            Entry::Occupied(mut entry) => {
                let partial = entry.get_mut();
                if partial.total != envelope.total {
                    // The same message id with two different lengths. One of them is a lie.
                    let (key, _) = entry.remove_entry();
                    bury(&mut self.refused, key, now);
                    return Accepted::Refused("total changed mid-message");
                }
                let slot = &mut partial.chunks[envelope.seq as usize];
                if slot.is_some() {
                    // Every relay delivers its own copy. Ordinary, and already counted.
                    return Accepted::Waiting;
                }
                if partial.bytes + body.len() > self.limits.max_bytes {
                    let (key, _) = entry.remove_entry();
                    bury(&mut self.refused, key, now);
                    return Accepted::Refused("message is too large");
                }
                partial.bytes += body.len();
                partial.arrived += 1;
                *slot = Some(body);
                if envelope.seq == 0 {
                    partial.head = Some(envelope);
                }

                if partial.arrived < partial.total {
                    return Accepted::Waiting;
                }
                let partial = entry.remove();
                Self::finish(partial)
            }
            Entry::Vacant(slot) => {
                if at_capacity {
                    // Refusing the new one rather than evicting an old one: eviction would let
                    // anybody flush a message somebody else was halfway through sending.
                    bury(&mut self.refused, slot.into_key(), now);
                    return Accepted::Refused("too many messages in flight");
                }
                if body.len() > self.limits.max_bytes {
                    bury(&mut self.refused, slot.into_key(), now);
                    return Accepted::Refused("message is too large");
                }
                let mut chunks = vec![None; envelope.total as usize];
                let seq = envelope.seq as usize;
                let bytes = body.len();
                chunks[seq] = Some(body);
                slot.insert(Partial {
                    total: envelope.total,
                    chunks,
                    head: (envelope.seq == 0).then(|| envelope.clone()),
                    bytes,
                    arrived: 1,
                    started: now,
                });
                Accepted::Waiting
            }
        }
    }

    fn finish(partial: Partial) -> Accepted {
        // A message whose chunk 0 never arrived has no method, path or status, so there is nothing
        // to serve even though every byte is here.
        let Some(head) = partial.head else {
            return Accepted::Refused("no head chunk");
        };
        let mut body = Vec::with_capacity(partial.bytes);
        for chunk in partial.chunks.into_iter() {
            match chunk {
                Some(part) => body.extend_from_slice(&part),
                None => return Accepted::Refused("a chunk went missing"),
            }
        }
        Accepted::Complete { head, body }
    }

    /// Forget half-arrived messages nobody finished, and refusals old enough to be moot.
    fn expire(&mut self, now: Instant) {
        let ttl = self.limits.ttl;
        self.partials
            .retain(|_, partial| now.duration_since(partial.started) < ttl);
        self.refused.retain(|_, when| now.duration_since(*when) < ttl);
    }
}

/// How many refusals are remembered at most. Each is a key and a timestamp; the ceiling is there so
/// that a stranger with many keys cannot make the list itself the thing that fills memory.
const MAX_REFUSED: usize = 4096;

/// Remember a refusal. Past the ceiling the whole list goes rather than the oldest entry: losing
/// refusals only means a refused message may be reopened and refused again, which is the
/// inefficiency this exists to avoid, not a hole in anything.
fn bury<K: Eq + Hash>(refused: &mut HashMap<K, Instant>, key: K, now: Instant) {
    if refused.len() >= MAX_REFUSED {
        refused.clear();
    }
    refused.insert(key, now);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{HttpRequest, HttpResponse};

    fn envelopes(len: usize, max: usize) -> Vec<Envelope> {
        let mut request = HttpRequest::new("POST", "/_matrix/media/v3/upload");
        request.body = (0..len).map(|i| i as u8).collect();
        request.into_envelopes(max)
    }

    fn complete(accepted: Accepted) -> (Envelope, Vec<u8>) {
        match accepted {
            Accepted::Complete { head, body } => (head, body),
            other => panic!("expected a complete message, got {other:?}"),
        }
    }

    #[test]
    fn chunks_in_order_come_back_as_the_body_that_went_in() {
        let mut reassembler = Reassembler::new(Limits::default());
        let parts = envelopes(1000, 64);
        let now = Instant::now();

        let last = parts.len() - 1;
        for (index, envelope) in parts.into_iter().enumerate() {
            let accepted = reassembler.accept("client", envelope, now);
            if index < last {
                assert!(matches!(accepted, Accepted::Waiting));
            } else {
                let (head, body) = complete(accepted);
                assert_eq!(head.method.as_deref(), Some("POST"));
                assert_eq!(body, (0..1000).map(|i| i as u8).collect::<Vec<_>>());
            }
        }
        assert_eq!(reassembler.in_flight(), 0);
    }

    /// Relays do not agree on order, so the head is not guaranteed to be first — and a body chunk
    /// that arrives before it must not be dropped for having no method on it.
    #[test]
    fn chunks_out_of_order_are_fine_including_the_head_arriving_last() {
        let mut reassembler = Reassembler::new(Limits::default());
        let mut parts = envelopes(300, 64);
        parts.reverse();
        let now = Instant::now();

        let last = parts.len() - 1;
        for (index, envelope) in parts.into_iter().enumerate() {
            let accepted = reassembler.accept("client", envelope, now);
            if index == last {
                let (head, body) = complete(accepted);
                assert_eq!(head.seq, 0);
                assert_eq!(body.len(), 300);
            }
        }
    }

    /// The same chunk from three relays is one chunk.
    #[test]
    fn duplicates_are_not_counted_twice() {
        let mut reassembler = Reassembler::new(Limits::default());
        let parts = envelopes(200, 64);
        let now = Instant::now();

        for _ in 0..3 {
            assert!(matches!(
                reassembler.accept("client", parts[0].clone(), now),
                Accepted::Waiting
            ));
        }
        for envelope in &parts[1..parts.len() - 1] {
            reassembler.accept("client", envelope.clone(), now);
        }
        let (_, body) = complete(reassembler.accept("client", parts[parts.len() - 1].clone(), now));
        assert_eq!(body.len(), 200);
    }

    #[test]
    fn two_senders_using_the_same_message_id_do_not_mix() {
        let mut reassembler = Reassembler::new(Limits::default());
        let now = Instant::now();

        let mut ann = HttpRequest::new("PUT", "/ann");
        ann.id = "same".into();
        ann.body = vec![1; 100];
        let mut bob = HttpRequest::new("PUT", "/bob");
        bob.id = "same".into();
        bob.body = vec![2; 100];

        let ann = ann.into_envelopes(64);
        let bob = bob.into_envelopes(64);

        reassembler.accept(("ann", "same"), ann[0].clone(), now);
        reassembler.accept(("bob", "same"), bob[0].clone(), now);
        let (ann_head, ann_body) = complete(reassembler.accept(("ann", "same"), ann[1].clone(), now));
        let (bob_head, bob_body) = complete(reassembler.accept(("bob", "same"), bob[1].clone(), now));

        assert_eq!(ann_head.path.as_deref(), Some("/ann"));
        assert_eq!(bob_head.path.as_deref(), Some("/bob"));
        assert_eq!(ann_body, vec![1; 100]);
        assert_eq!(bob_body, vec![2; 100]);
    }

    #[test]
    fn a_message_with_more_chunks_than_allowed_is_refused_at_the_first_one() {
        let limits = Limits {
            max_chunks: 4,
            ..Limits::default()
        };
        let mut reassembler = Reassembler::new(limits);
        let parts = envelopes(1000, 64);
        assert!(matches!(
            reassembler.accept("client", parts[0].clone(), Instant::now()),
            Accepted::Refused("too many chunks")
        ));
        assert_eq!(reassembler.in_flight(), 0);
    }

    #[test]
    fn a_message_that_grows_past_the_byte_ceiling_is_dropped() {
        let limits = Limits {
            max_bytes: 100,
            ..Limits::default()
        };
        let mut reassembler = Reassembler::new(limits);
        let parts = envelopes(300, 64);
        let now = Instant::now();

        // 64 bytes in is fine; the second chunk takes it past 100 and the whole message goes.
        reassembler.accept("client", parts[0].clone(), now);
        assert!(matches!(
            reassembler.accept("client", parts[1].clone(), now),
            Accepted::Refused("message is too large")
        ));
        assert_eq!(reassembler.in_flight(), 0);
    }

    /// Ten thousand messages begun and none finished is the cheapest attack there is on something
    /// that holds chunks in memory.
    #[test]
    fn a_flood_of_unfinished_messages_is_refused_rather_than_held() {
        let limits = Limits {
            max_in_flight: 2,
            ..Limits::default()
        };
        let mut reassembler = Reassembler::new(limits);
        let now = Instant::now();

        for index in 0..2 {
            let parts = envelopes(300, 64);
            assert!(matches!(
                reassembler.accept(index, parts[0].clone(), now),
                Accepted::Waiting
            ));
        }
        let parts = envelopes(300, 64);
        assert!(matches!(
            reassembler.accept(99, parts[0].clone(), now),
            Accepted::Refused("too many messages in flight")
        ));
    }

    /// And the one that makes the cap survivable: a sender who goes away does not hold a slot for
    /// the life of the process.
    #[test]
    fn half_arrived_messages_are_forgotten_after_their_time() {
        let mut reassembler = Reassembler::new(Limits::default());
        let parts = envelopes(300, 64);
        let start = Instant::now();

        reassembler.accept("client", parts[0].clone(), start);
        assert_eq!(reassembler.in_flight(), 1);

        let later = start + Duration::from_secs(61);
        reassembler.accept("other", parts[0].clone(), later);
        assert_eq!(reassembler.in_flight(), 1);
    }

    #[test]
    fn a_total_that_changes_mid_message_is_a_lie_and_the_message_goes() {
        let mut reassembler = Reassembler::new(Limits::default());
        let now = Instant::now();
        let parts = envelopes(300, 64);
        let mut liar = parts[1].clone();
        liar.total += 1;

        reassembler.accept("client", parts[0].clone(), now);
        assert!(matches!(
            reassembler.accept("client", liar, now),
            Accepted::Refused("total changed mid-message")
        ));
        assert_eq!(reassembler.in_flight(), 0);
    }

    /// A refusal is final. Without this the chunk after a refused one finds no partial, opens a
    /// fresh one and starts filling it — refused, reopened and refused again, once per chunk.
    #[test]
    fn the_rest_of_a_refused_message_does_not_reopen_it() {
        let limits = Limits {
            max_bytes: 100,
            ..Limits::default()
        };
        let mut reassembler = Reassembler::new(limits);
        let parts = envelopes(300, 64);
        let now = Instant::now();

        reassembler.accept("client", parts[0].clone(), now);
        assert!(matches!(
            reassembler.accept("client", parts[1].clone(), now),
            Accepted::Refused("message is too large")
        ));
        for envelope in &parts[2..] {
            assert!(matches!(
                reassembler.accept("client", envelope.clone(), now),
                Accepted::Refused("refused earlier")
            ));
        }
        assert_eq!(reassembler.in_flight(), 0);
    }

    /// The bridge charges a request to the rate limit once, on its first chunk — which needs to
    /// know whether a chunk is the first of a message or one more of a message already known.
    #[test]
    fn a_message_is_known_from_its_first_chunk_until_it_is_done() {
        let mut reassembler = Reassembler::new(Limits::default());
        let parts = envelopes(200, 64);
        let now = Instant::now();

        assert!(!reassembler.knows(&"client"));
        reassembler.accept("client", parts[0].clone(), now);
        assert!(reassembler.knows(&"client"));
        for envelope in &parts[1..] {
            reassembler.accept("client", envelope.clone(), now);
        }
        assert!(!reassembler.knows(&"client"));
    }

    /// And refused from outside — the rate limit — the rest of the message goes quietly.
    #[test]
    fn a_message_refused_from_outside_stays_refused_until_its_time_is_up() {
        let mut reassembler = Reassembler::new(Limits::default());
        let parts = envelopes(200, 64);
        let start = Instant::now();

        reassembler.accept("client", parts[0].clone(), start);
        reassembler.refuse("client", start);
        assert_eq!(reassembler.in_flight(), 0);
        assert!(reassembler.knows(&"client"));
        assert!(matches!(
            reassembler.accept("client", parts[1].clone(), start),
            Accepted::Refused("refused earlier")
        ));

        let later = start + Duration::from_secs(61);
        assert!(matches!(
            reassembler.accept("client", parts[1].clone(), later),
            Accepted::Waiting
        ));
    }

    #[test]
    fn a_response_reassembles_with_its_status() {
        let mut reassembler = Reassembler::new(Limits::default());
        let now = Instant::now();
        let response = HttpResponse {
            id: "r".into(),
            status: 206,
            headers: Default::default(),
            body: vec![4; 200],
        };
        let parts = response.into_envelopes(64);
        let last = parts.len() - 1;
        for (index, envelope) in parts.into_iter().enumerate() {
            let accepted = reassembler.accept("bridge", envelope, now);
            if index == last {
                let (head, body) = complete(accepted);
                assert_eq!(head.status, Some(206));
                assert_eq!(body, vec![4; 200]);
            }
        }
    }
}
