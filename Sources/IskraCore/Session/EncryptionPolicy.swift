import MatrixRustSDK

/// Who gets the keys to what this account writes, and whose messages this account will read.
///
/// Said out loud rather than left to the SDK's default, because the default is a choice too — and
/// it was the one MSC4153 calls not recommended: keys shared with every device, a replaced
/// identity included, without a word.
///
/// **Keys go to every device, except that it stops when somebody the user verified no longer
/// checks out** — their identity replaced, or a device they have not confirmed themselves. Then the
/// message waits, the bubble says why, and "Send anyway" is the user's to press
/// (`TimelineStore.sendAnyway`). Somebody never verified gets a banner in the room instead
/// (`IdentityChangesStore`) and no hold-up: a message nobody can receive until they have verified
/// each other in person is an app nobody can use.
///
/// Stricter, `identityBasedStrategy`, would stop sharing with every device its owner has not
/// signed — correct by the spec, and the end of conversations with anybody on an older client.
/// Decided with the project's owner, 2026-09-30; not a detail to change in passing.
enum EncryptionPolicy {
    static let recipients: CollectStrategy = .errorOnVerifiedUserProblem

    /// Messages are decrypted whoever sent them. Refusing unverified senders would be the
    /// receiving half of `identityBasedStrategy`, and goes with it if that is ever chosen.
    static let decryption = DecryptionSettings(senderDeviceTrustRequirement: .untrusted)
}

extension ClientBuilder {
    /// The two settings above, applied. One place, so the demo and the real account cannot drift.
    func encryptionPolicy() -> ClientBuilder {
        roomKeyRecipientStrategy(strategy: EncryptionPolicy.recipients)
            .decryptionSettings(decryptionSettings: EncryptionPolicy.decryption)
    }
}
