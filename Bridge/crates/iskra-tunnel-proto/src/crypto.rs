//! NIP-44 around the envelope, and nothing invented.
//!
//! The conversation key is ECDH(our secret, their public), so both sides derive the same one from
//! opposite halves and there is no key to ship in the event. None of this is our cryptography —
//! it is `nostr`'s NIP-44 v2, called correctly and not reimplemented.

use nostr_sdk::nips::nip44::{self, Version};
use nostr_sdk::prelude::{PublicKey, SecretKey};

use crate::{Envelope, ProtoError, MAX_NIP44_PLAINTEXT};

/// Serialize an envelope and encrypt it for `recipient`.
pub fn seal(
    sender_secret: &SecretKey,
    recipient: &PublicKey,
    envelope: &Envelope,
) -> Result<String, ProtoError> {
    let json = serde_json::to_vec(envelope)?;
    if json.len() > MAX_NIP44_PLAINTEXT {
        return Err(ProtoError::TooLarge(json.len()));
    }
    nip44::encrypt(sender_secret, recipient, json, Version::V2)
        .map_err(|_| ProtoError::Undecryptable)
}

/// Decrypt an event's content and parse the envelope inside it.
///
/// Anyone can publish an event tagged at us, so failure here is ordinary rather than exceptional:
/// it means "not for us, or not from who we think", and the caller drops it quietly.
pub fn open(
    recipient_secret: &SecretKey,
    sender: &PublicKey,
    content: &str,
) -> Result<Envelope, ProtoError> {
    let plaintext = nip44::decrypt(recipient_secret, sender, content)
        .map_err(|_| ProtoError::Undecryptable)?;
    let envelope: Envelope = serde_json::from_str(&plaintext)?;
    envelope.validate()?;
    Ok(envelope)
}

#[cfg(test)]
mod tests {
    use nostr_sdk::prelude::Keys;

    use super::*;
    use crate::HttpRequest;

    fn envelope() -> Envelope {
        HttpRequest::new("GET", "/_matrix/client/versions").into_single_envelope()
    }

    #[test]
    fn what_one_side_seals_the_other_side_opens() {
        let client = Keys::generate();
        let bridge = Keys::generate();
        let original = envelope();

        let content = seal(client.secret_key(), &bridge.public_key(), &original).unwrap();
        let opened = open(bridge.secret_key(), &client.public_key(), &content).unwrap();

        assert_eq!(opened, original);
    }

    #[test]
    fn the_ciphertext_does_not_carry_the_path_in_the_clear() {
        let client = Keys::generate();
        let bridge = Keys::generate();
        let content = seal(client.secret_key(), &bridge.public_key(), &envelope()).unwrap();
        assert!(!content.contains("_matrix"));
    }

    #[test]
    fn a_third_party_key_does_not_open_it() {
        let client = Keys::generate();
        let bridge = Keys::generate();
        let eavesdropper = Keys::generate();

        let content = seal(client.secret_key(), &bridge.public_key(), &envelope()).unwrap();
        let result = open(eavesdropper.secret_key(), &client.public_key(), &content);

        assert!(matches!(result, Err(ProtoError::Undecryptable)));
    }

    #[test]
    fn garbage_content_is_an_error_not_a_panic() {
        let bridge = Keys::generate();
        let client = Keys::generate();
        let result = open(bridge.secret_key(), &client.public_key(), "not a payload");
        assert!(matches!(result, Err(ProtoError::Undecryptable)));
    }
}
