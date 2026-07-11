import SwiftUI
import IskraCore
import IskraDesign

/// One message in the timeline.
struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.close) {
            if message.isOwn { Spacer(minLength: 60) }

            // Only the first message in a run carries an avatar; the rest are indented
            // to line up under it.
            if !message.isOwn {
                if message.isContinuation {
                    Color.clear.frame(width: Theme.Size.avatarSmall)
                } else {
                    Avatar(name: message.senderName, url: message.senderAvatarURL, size: Theme.Size.avatarSmall)
                }
            }

            VStack(alignment: message.isOwn ? .trailing : .leading, spacing: Theme.Spacing.tight) {
                if !message.isOwn && !message.isContinuation {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Theme.Spacing.close)
                }

                content

                if message.isOwn, let delivery = message.delivery {
                    DeliveryTick(status: delivery)
                }
            }

            if !message.isOwn { Spacer(minLength: 60) }
        }
        .padding(.top, message.isContinuation ? Theme.Spacing.withinRun : Theme.Spacing.betweenSenders)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case let .text(body):
            bubble { Text(body) }

        case let .notice(body):
            bubble { Text(body).italic() }

        case let .emote(body):
            Text(body)
                .font(.callout.italic())
                .foregroundStyle(.secondary)

        case let .videoNote(attachment):
            // The signature shape: a circle, not a bubble. No bubble background, so
            // no rounded-rectangle peeking out behind the mask.
            VideoNoteView(attachment: attachment)

        case let .voice(attachment, waveform):
            bubble { VoiceMessageView(attachment: attachment, waveform: waveform, isOwn: message.isOwn) }

        // A caption is the sender's own words, so it wins. Only the fallback is ours
        // to translate.
        case let .image(attachment):
            AttachmentPlaceholder(systemImage: "photo",
                                  title: attachment.caption ?? String(localized: CoreStrings.Preview.photo))
                .messageBubble(isOwn: message.isOwn)

        case let .video(attachment):
            AttachmentPlaceholder(systemImage: "play.rectangle",
                                  title: attachment.caption ?? String(localized: CoreStrings.Preview.video))
                .messageBubble(isOwn: message.isOwn)

        case let .audio(attachment):
            AttachmentPlaceholder(systemImage: "waveform", title: attachment.filename)
                .messageBubble(isOwn: message.isOwn)

        case let .file(attachment):
            AttachmentPlaceholder(systemImage: "doc", title: attachment.filename)
                .messageBubble(isOwn: message.isOwn)

        case .unreadable:
            // Not an error the user caused, and not one they can fix. Say what
            // happened without the word "decrypt".
            bubble {
                Label { Text(Strings.Message.unreadable) } icon: { Image(systemName: "lock.slash") }
                    .font(.footnote)
            }

        case .deleted:
            bubble {
                Text(Strings.Message.deleted)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
            }

        case .unsupported:
            bubble {
                Text(Strings.Message.unsupported)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bubble(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .font(.body)
            .messageBubble(isOwn: message.isOwn)
    }

    private var accessibilityLabel: String {
        let who = message.isOwn ? String(app: Strings.Message.Spoken.you) : message.senderName

        // A message body is the sender's own words, so it is read back as written.
        // Everything else is a description of what they did, and is translated.
        let what: String = switch message.kind {
        case let .text(body): body
        case let .notice(body): body
        case let .emote(body): body
        case .image: String(app: Strings.Message.Spoken.sentPhoto)
        case .video: String(app: Strings.Message.Spoken.sentVideo)
        case .videoNote: String(app: Strings.Message.Spoken.sentVideoNote)
        case .voice: String(app: Strings.Message.Spoken.sentVoice)
        case .audio: String(app: Strings.Message.Spoken.sentAudio)
        case .file: String(app: Strings.Message.Spoken.sentFile)
        case .unreadable: String(app: Strings.Message.Spoken.sentUnreadable)
        case .deleted: String(app: Strings.Message.Spoken.deletedMessage)
        case .unsupported: String(app: Strings.Message.Spoken.sentUnsupported)
        }
        return "\(who): \(what)"
    }
}

/// Sending, sent, read. Shown only on your own messages, and never as a raw word.
private struct DeliveryTick: View {
    let status: DeliveryStatus

    var body: some View {
        Group {
            switch status {
            case .sending:
                Image(systemName: "clock")
            case .sent:
                Image(systemName: "checkmark")
            case .read:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .font(.caption2)
        .foregroundStyle(status == .failed ? Color.orange : Color.secondary)
        .padding(.trailing, Theme.Spacing.tight)
        .accessibilityLabel(Text(label))
    }

    private var label: LocalizedStringResource {
        switch status {
        case .sending: Strings.Message.Delivery.sending
        case .sent: Strings.Message.Delivery.sent
        case .read: Strings.Message.Delivery.read
        case .failed: Strings.Message.Delivery.failed
        }
    }
}

/// Round video messages. A circle, masked, exactly as recorded.
private struct VideoNoteView: View {
    let attachment: Attachment

    var body: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: Theme.Size.videoNote, height: Theme.Size.videoNote)
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .overlay(alignment: .bottom) {
                if let duration = attachment.duration {
                    Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.close)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(.bottom, Theme.Spacing.normal)
                }
            }
    }
}

/// A voice message: a play button and the shape of the sound.
private struct VoiceMessageView: View {
    let attachment: Attachment
    let waveform: [Float]
    let isOwn: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            Image(systemName: "play.fill")
                .font(.body)

            // The waveform the sender's device computed, so both sides see the same
            // shape rather than each guessing at one.
            HStack(spacing: 2) {
                ForEach(Array(waveform.prefix(40).enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .frame(width: 2, height: max(3, CGFloat(sample) * 24))
                }
            }
            .opacity(0.8)

            if let duration = attachment.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

/// Media we can show a bubble for but have not wired to a player yet.
private struct AttachmentPlaceholder: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.body)
            .lineLimit(1)
    }
}
