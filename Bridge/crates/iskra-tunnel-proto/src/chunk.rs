//! Cutting one HTTP message into envelopes.
//!
//! One chunker, used by both ends. A client that cuts a body one way and a bridge that puts it
//! back together another way fails only under load, only sometimes, and only in production — so
//! there is one of each, here, and the tests below are the specification.
//!
//! The head fields (`method`, `path`, `headers`, `upstream`, `status`) ride on chunk 0 alone.
//! Repeating them would be paid for on every chunk, and bytes are the scarce thing: the relay's
//! event size limit is the ceiling the whole protocol lives under.

use base64::prelude::{Engine as _, BASE64_STANDARD};

use crate::{Envelope, HttpRequest, HttpResponse, PROTOCOL_VERSION};

/// How many chunks a body of `len` bytes becomes at this budget.
///
/// An empty body is one chunk, not none: a request with nothing in it is still a request, and a
/// message of zero envelopes is a message nobody can reassemble.
pub fn chunk_count(len: usize, max_body_chunk: usize) -> u32 {
    let max = max_body_chunk.max(1);
    (len.div_ceil(max)).max(1) as u32
}

fn slices(body: &[u8], max_body_chunk: usize) -> Vec<&[u8]> {
    let max = max_body_chunk.max(1);
    if body.is_empty() {
        return vec![&[]];
    }
    body.chunks(max).collect()
}

impl HttpRequest {
    /// The request as envelopes, in order, ready to be sealed one at a time.
    pub fn into_envelopes(self, max_body_chunk: usize) -> Vec<Envelope> {
        let parts = slices(&self.body, max_body_chunk);
        let total = parts.len() as u32;
        parts
            .into_iter()
            .enumerate()
            .map(|(seq, part)| Envelope {
                v: PROTOCOL_VERSION,
                id: self.id.clone(),
                seq: seq as u32,
                total,
                method: (seq == 0).then(|| self.method.clone()),
                path: (seq == 0).then(|| self.path.clone()),
                headers: (seq == 0).then(|| self.headers.clone()),
                status: None,
                upstream: if seq == 0 { self.upstream.clone() } else { None },
                body_chunk: BASE64_STANDARD.encode(part),
            })
            .collect()
    }
}

impl HttpResponse {
    pub fn into_envelopes(self, max_body_chunk: usize) -> Vec<Envelope> {
        let parts = slices(&self.body, max_body_chunk);
        let total = parts.len() as u32;
        parts
            .into_iter()
            .enumerate()
            .map(|(seq, part)| Envelope {
                v: PROTOCOL_VERSION,
                id: self.id.clone(),
                seq: seq as u32,
                total,
                method: None,
                path: None,
                headers: (seq == 0).then(|| self.headers.clone()),
                status: (seq == 0).then_some(self.status),
                upstream: None,
                body_chunk: BASE64_STANDARD.encode(part),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DEFAULT_MAX_BODY_CHUNK;

    fn request(body: Vec<u8>) -> HttpRequest {
        let mut request = HttpRequest::new("POST", "/_matrix/media/v3/upload");
        request
            .headers
            .insert("content-type".into(), "image/jpeg".into());
        request.body = body;
        request.to("https://matrix.org")
    }

    #[test]
    fn an_empty_body_is_one_chunk_and_not_none() {
        let envelopes = HttpRequest::new("GET", "/_matrix/client/versions").into_envelopes(64);
        assert_eq!(envelopes.len(), 1);
        assert_eq!(envelopes[0].total, 1);
        assert_eq!(envelopes[0].body_chunk, "");
        envelopes[0].validate().unwrap();
    }

    #[test]
    fn a_body_that_fits_is_still_one_chunk() {
        let envelopes = request(vec![7; 64]).into_envelopes(64);
        assert_eq!(envelopes.len(), 1);
    }

    #[test]
    fn one_byte_more_than_fits_is_two_chunks() {
        let envelopes = request(vec![7; 65]).into_envelopes(64);
        assert_eq!(envelopes.len(), 2);
        assert_eq!(envelopes[1].total, 2);
        assert_eq!(envelopes[1].seq, 1);
    }

    /// The head fields are on chunk 0 and nowhere else — which is not a saving, it is what
    /// `Envelope::validate` refuses to accept otherwise.
    #[test]
    fn only_the_first_chunk_carries_the_head() {
        let envelopes = request(vec![1; 200]).into_envelopes(64);
        assert!(envelopes.len() > 2);
        assert_eq!(envelopes[0].method.as_deref(), Some("POST"));
        assert_eq!(envelopes[0].upstream.as_deref(), Some("https://matrix.org"));
        assert!(envelopes[0].headers.is_some());
        for envelope in &envelopes[1..] {
            assert!(envelope.method.is_none());
            assert!(envelope.path.is_none());
            assert!(envelope.headers.is_none());
            assert!(envelope.upstream.is_none());
        }
        for envelope in &envelopes {
            envelope.validate().unwrap();
        }
    }

    #[test]
    fn a_response_chunks_the_same_way_and_keeps_its_status_on_the_head() {
        let response = HttpResponse {
            id: "abc".into(),
            status: 200,
            headers: Default::default(),
            body: vec![9; 150],
        };
        let envelopes = response.into_envelopes(64);
        assert_eq!(envelopes.len(), 3);
        assert_eq!(envelopes[0].status, Some(200));
        assert!(envelopes[1].status.is_none());
    }

    #[test]
    fn every_chunk_of_a_body_at_the_default_budget_fits_one_nip44_payload() {
        // The whole point of the budget: a chunk plus its envelope has to survive base64 twice and
        // still be under the NIP-44 ceiling. Checked at the size that is actually sent.
        let envelopes = request(vec![0; DEFAULT_MAX_BODY_CHUNK * 3 + 1])
            .into_envelopes(DEFAULT_MAX_BODY_CHUNK);
        assert_eq!(envelopes.len(), 4);
        for envelope in &envelopes {
            let json = serde_json::to_vec(envelope).unwrap();
            assert!(json.len() < crate::MAX_NIP44_PLAINTEXT, "{} bytes", json.len());
        }
    }

    #[test]
    fn the_count_matches_what_the_chunker_produces() {
        for len in [0, 1, 63, 64, 65, 1000] {
            assert_eq!(
                chunk_count(len, 64),
                request(vec![0; len]).into_envelopes(64).len() as u32
            );
        }
    }
}
