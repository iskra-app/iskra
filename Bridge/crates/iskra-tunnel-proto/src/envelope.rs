//! The JSON that travels inside an encrypted nostr event.

use std::collections::BTreeMap;

use base64::prelude::{Engine as _, BASE64_STANDARD};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ProtoError;

pub const PROTOCOL_VERSION: u8 = 1;

/// One chunk of one HTTP message.
///
/// `method`, `path` and `headers` (request) and `status` (response) ride on `seq == 0` only.
/// Repeating them in every chunk would be paid for in bytes on every chunk, and the bytes are the
/// scarce thing here: the relay's event size limit is the ceiling the whole protocol lives under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u8,
    pub id: String,
    pub seq: u32,
    pub total: u32,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headers: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,

    /// Base64 of this chunk's slice of the body. Empty string for an empty body.
    pub body_chunk: String,
}

impl Envelope {
    /// Reject anything self-contradictory before it reaches code that assumes it is sane.
    ///
    /// A malformed envelope arrives from the network, which means it arrives from anybody, so this
    /// runs on every chunk on both sides.
    pub fn validate(&self) -> Result<(), ProtoError> {
        if self.v != PROTOCOL_VERSION {
            return Err(ProtoError::UnsupportedVersion(self.v));
        }
        if self.total == 0 {
            return Err(ProtoError::Malformed("total is zero"));
        }
        if self.seq >= self.total {
            return Err(ProtoError::Malformed("seq is past total"));
        }
        if self.id.is_empty() {
            return Err(ProtoError::Malformed("id is empty"));
        }
        let is_head = self.seq == 0;
        let carries_head = self.method.is_some() || self.path.is_some() || self.status.is_some();
        if carries_head && !is_head {
            return Err(ProtoError::Malformed("head fields on a non-first chunk"));
        }
        Ok(())
    }

    /// The chunk's slice of the body, decoded.
    pub fn body(&self) -> Result<Vec<u8>, ProtoError> {
        if self.body_chunk.is_empty() {
            return Ok(Vec::new());
        }
        Ok(BASE64_STANDARD.decode(&self.body_chunk)?)
    }
}

/// An HTTP request as the client hands it to the tunnel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    pub id: String,
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpRequest {
    pub fn new(method: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            method: method.into(),
            path: path.into(),
            headers: BTreeMap::new(),
            body: Vec::new(),
        }
    }

    /// Stage 1 only: the whole request in one envelope, no chunking.
    ///
    /// Stage 2 replaces this with the chunker; until then a body larger than one chunk is refused
    /// loudly rather than silently truncated.
    pub fn into_single_envelope(self) -> Envelope {
        Envelope {
            v: PROTOCOL_VERSION,
            id: self.id,
            seq: 0,
            total: 1,
            method: Some(self.method),
            path: Some(self.path),
            headers: Some(self.headers),
            status: None,
            body_chunk: BASE64_STANDARD.encode(&self.body),
        }
    }

    /// Rebuild a request from a head envelope plus the body the reassembler produced.
    pub fn from_head(envelope: &Envelope, body: Vec<u8>) -> Result<Self, ProtoError> {
        envelope.validate()?;
        let method = envelope
            .method
            .clone()
            .ok_or(ProtoError::Malformed("request has no method"))?;
        let path = envelope
            .path
            .clone()
            .ok_or(ProtoError::Malformed("request has no path"))?;
        Ok(Self {
            id: envelope.id.clone(),
            method,
            path,
            headers: envelope.headers.clone().unwrap_or_default(),
            body,
        })
    }
}

/// An HTTP response as the bridge hands it back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub id: String,
    pub status: u16,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn into_single_envelope(self) -> Envelope {
        Envelope {
            v: PROTOCOL_VERSION,
            id: self.id,
            seq: 0,
            total: 1,
            method: None,
            path: None,
            headers: Some(self.headers),
            status: Some(self.status),
            body_chunk: BASE64_STANDARD.encode(&self.body),
        }
    }

    pub fn from_head(envelope: &Envelope, body: Vec<u8>) -> Result<Self, ProtoError> {
        envelope.validate()?;
        let status = envelope
            .status
            .ok_or(ProtoError::Malformed("response has no status"))?;
        Ok(Self {
            id: envelope.id.clone(),
            status,
            headers: envelope.headers.clone().unwrap_or_default(),
            body,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head() -> Envelope {
        HttpRequest::new("GET", "/_matrix/client/versions").into_single_envelope()
    }

    #[test]
    fn a_single_chunk_request_survives_the_round_trip() {
        let mut request = HttpRequest::new("POST", "/_matrix/client/v3/login");
        request
            .headers
            .insert("content-type".into(), "application/json".into());
        request.body = br#"{"type":"m.login.password"}"#.to_vec();

        let envelope = request.clone().into_single_envelope();
        envelope.validate().unwrap();
        let body = envelope.body().unwrap();
        let back = HttpRequest::from_head(&envelope, body).unwrap();

        assert_eq!(back, request);
    }

    #[test]
    fn a_response_round_trips_with_its_status() {
        let response = HttpResponse {
            id: "abc".into(),
            status: 404,
            headers: BTreeMap::new(),
            body: b"{}".to_vec(),
        };
        let envelope = response.clone().into_single_envelope();
        let body = envelope.body().unwrap();
        assert_eq!(HttpResponse::from_head(&envelope, body).unwrap(), response);
    }

    #[test]
    fn an_empty_body_is_an_empty_string_not_a_missing_field() {
        let envelope = head();
        assert_eq!(envelope.body_chunk, "");
        assert!(envelope.body().unwrap().is_empty());
    }

    #[test]
    fn a_future_protocol_version_is_refused_rather_than_guessed_at() {
        let mut envelope = head();
        envelope.v = PROTOCOL_VERSION + 1;
        assert!(matches!(
            envelope.validate(),
            Err(ProtoError::UnsupportedVersion(_))
        ));
    }

    #[test]
    fn seq_past_total_is_refused() {
        let mut envelope = head();
        envelope.seq = 1;
        envelope.total = 1;
        assert!(envelope.validate().is_err());
    }

    #[test]
    fn total_of_zero_is_refused() {
        let mut envelope = head();
        envelope.total = 0;
        assert!(envelope.validate().is_err());
    }

    #[test]
    fn head_fields_on_a_later_chunk_are_refused() {
        let mut envelope = head();
        envelope.total = 3;
        envelope.seq = 2;
        // method is still Some from the head — exactly the shape a confused sender produces.
        assert!(envelope.validate().is_err());
    }

    #[test]
    fn a_body_that_is_not_base64_is_an_error_not_a_panic() {
        let mut envelope = head();
        envelope.body_chunk = "this is not base64!!".into();
        assert!(matches!(envelope.body(), Err(ProtoError::BadBase64(_))));
    }

    #[test]
    fn head_fields_are_omitted_from_the_json_when_absent() {
        let envelope = HttpResponse {
            id: "x".into(),
            status: 200,
            headers: BTreeMap::new(),
            body: Vec::new(),
        }
        .into_single_envelope();
        let json = serde_json::to_string(&envelope).unwrap();
        assert!(!json.contains("method"));
        assert!(!json.contains("\"path\""));
        assert!(json.contains("\"status\":200"));
    }
}
