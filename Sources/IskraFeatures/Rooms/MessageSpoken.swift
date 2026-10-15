import Foundation
import IskraCore

/// What a message is called and what it sounds like, for the two timelines that both need it.
///
/// None of this is a fact about a bubble or about a line — it is a fact about the message —
/// so it hangs off `Message` rather than off either row. In `IskraFeatures` and not in Core,
/// because every word here is a `Strings` lookup and the model layer does not do words about
/// itself.
extension Message {
    /// Who sent it, in the one form that works when the message is looked at away from the
    /// side of the screen it was on: a name, and "you" where the name would be your own.
    ///
    /// The word is `Spoken.you` — the one VoiceOver reads out — and it is deliberately not a
    /// second string with the same two letters in it. A translation duplicated is a translation
    /// that drifts, and there is no sentence in which the app would want to call the user one
    /// thing aloud and another on screen.
    var spokenSender: String {
        isOwn ? String(app: Strings.Message.Spoken.you) : senderName
    }

    /// The whole message as one sentence: who, and what they said or did.
    var spokenLabel: String {
        let who = spokenSender

        // A message body is the sender's own words, so it is read back as written.
        // Everything else is a description of what they did, and is translated.
        let what: String = switch kind {
        case let .text(body): body
        case let .notice(body): body
        case let .emote(body): body
        case .image: String(app: Strings.Message.Spoken.sentPhoto)
        case let .sticker(attachment):
            if let description = attachment.caption {
                String(app: Strings.Message.Spoken.sentStickerNamed(description))
            } else {
                String(app: Strings.Message.Spoken.sentSticker)
            }
        case .video: String(app: Strings.Message.Spoken.sentVideo)
        case .videoNote: String(app: Strings.Message.Spoken.sentVideoNote)
        case .voice: String(app: Strings.Message.Spoken.sentVoice)
        case .audio: String(app: Strings.Message.Spoken.sentAudio)
        case .file: String(app: Strings.Message.Spoken.sentFile)
        case .location: String(app: Strings.Message.Spoken.sentLocation)
        case let .poll(poll): String(app: Strings.Message.Spoken.sentPoll(poll.question))
        case .unreadable: String(app: Strings.Message.Spoken.sentUnreadable)
        case .deleted: String(app: Strings.Message.Spoken.deletedMessage)
        case .unsupported: String(app: Strings.Message.Spoken.sentUnsupported)
        }

        // The row is one combined element, so the badge's own button is flattened into it
        // and VoiceOver never lands on it. The reason therefore has to be said here, or a
        // blind user would be the only one who cannot find out why nothing was delivered.
        if case let .failed(failure)? = delivery {
            return "\(who): \(what). \(String(app: Strings.Message.Delivery.failed)). \(String(localized: failure.explanation))"
        }
        return "\(who): \(what)"
    }

    /// Whether the message has something inside it that has to be *pressed* — a play button, a
    /// photograph that opens, a file that opens.
    ///
    /// It decides how the row is presented to VoiceOver, and the decision matters more than it
    /// looks. `.combine` flattens a row into one element with one sentence, which is exactly right
    /// for a message made of words: "Аня: привет, 14:32" is one thought, and making somebody swipe
    /// through three fragments to hear it would be worse. But flattening a row also flattens the
    /// button inside it — and for a voice message, a video note, a photograph or a file, that
    /// button is the *entire message*. It was possible to hear that Аня had sent a voice message
    /// and impossible to play it.
    ///
    /// So a row whose content can be pressed is a container to be entered rather than a sentence
    /// to be read. Everything else stays one sentence.
    var hasPressableContent: Bool {
        switch kind {
        case .voice, .audio, .image, .video, .videoNote, .file: true
        default: false
        }
    }
}
