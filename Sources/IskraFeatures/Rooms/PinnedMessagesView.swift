import SwiftUI
import IskraCore
import IskraDesign

/// The strip across the top of a room that has something pinned.
///
/// It shows the *latest* pinned message, and only that one. A room with six pinned messages
/// does not get a strip six lines tall — it gets one line and a way to see the rest, which is
/// what pressing it does. The number beside it is how many there are, and it is there so that
/// pressing the strip is an informed act rather than a guess.
///
/// Glass, and legitimately so: it floats over the conversation and belongs to the navigation
/// layer, which is exactly what `navigationGlass` is for.
struct PinnedStrip: View {
    let pinned: PinnedStore

    /// Goes to the message in the conversation. Pressing the strip is *about* the message it is
    /// showing you, so that is what it does.
    ///
    /// It used to open the list, with a note here saying a future version would go to the message
    /// instead — while `RoomView` had already written the comment describing the behaviour as if
    /// it existed, and threw the `Message` away. Two files, one of them describing a thing that
    /// was never built and the other apologising for not having built it.
    let onGoTo: (Message) -> Void

    /// The rest of them, which is the chevron's job. The strip shows the latest pinned message;
    /// the way to the other five is the arrow at the end of it.
    let onOpenList: () -> Void

    @Environment(\.accent) private var accent

    /// The most recently pinned message. The timeline hands them over oldest first, so it is
    /// the last one — and nil in the moment before the pinned timeline has answered, which is
    /// why the strip draws nothing rather than an empty row.
    private var latest: Message? {
        pinned.messages.last
    }

    var body: some View {
        if let latest {
            // Two buttons on one surface: the strip goes to the message, the chevron opens the
            // rest. Both inside one piece of glass, because they are one control to look at — and
            // `contentShape` on each half so the halves are pressable rather than the labels.
            HStack(spacing: Theme.Spacing.close) {
                Button {
                    onGoTo(latest)
                } label: {
                    HStack(spacing: Theme.Spacing.close) {
                        Image(systemName: "pin.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent.color)

                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Theme.Spacing.tight) {
                                Text(Strings.Room.pinned)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(accent.color)

                                // Only where there is more than one. "Pinned 1" is a number nobody
                                // asked for; "Pinned 4" is the reason to press it.
                                if pinned.messages.count > 1 {
                                    Text(pinned.messages.count, format: .number)
                                        .font(.caption2.weight(.medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(summary(of: latest))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    onOpenList()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Spacing.roomy, height: Theme.Spacing.roomy)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.Room.pinnedTitle))
            }
            .padding(.horizontal, Theme.Spacing.roomy)
            .padding(.vertical, Theme.Spacing.close)
            .frame(maxWidth: .infinity)
            .navigationGlass(in: .rect(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.bottom, Theme.Spacing.close)
        }
    }

    private func summary(of message: Message) -> String {
        MessageSummary.text(of: message)
    }
}

/// Everything the room has pinned, oldest at the top.
///
/// A **list**, not a conversation, and that is a decision rather than a shortcut. These
/// messages were pinned so they could be found again, and what a reader does here is scan them
/// — so they are rows with a name and a line, in the order they were pinned, not bubbles on
/// alternating sides of a screen with reactions climbing onto them. Reusing `MessageRow` would
/// have brought its whole context menu along, offering to reply to and delete messages on a
/// screen that has no composer and no timeline to do it in.
///
/// The one thing this screen *can* do is take a message off the list, and a `List` is what
/// makes that the gesture people already know: swipe.
struct PinnedMessagesView: View {
    let pinned: PinnedStore
    let isOneToOne: Bool

    var body: some View {
        Group {
            if !pinned.hasLoaded {
                ProgressView()
            } else if pinned.messages.isEmpty {
                ContentUnavailableView(String(app: Strings.Room.pinnedEmpty),
                                       systemImage: "pin.slash")
            } else {
                List {
                    ForEach(pinned.messages) { message in
                        row(for: message)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await pinned.unpin(messageID: message.id) }
                                } label: {
                                    Label(Strings.Room.unpin, systemImage: "pin.slash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(String(app: Strings.Room.pinnedTitle))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(for message: Message) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.normal) {
            // In a chat with one other person there is nobody to tell apart, exactly as in the
            // conversation itself — so the face comes off and the line gets the width.
            if !isOneToOne {
                Avatar(name: message.senderName,
                       url: message.senderAvatarURL,
                       size: Theme.Size.avatarSmall,
                       seed: message.senderID)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack {
                    Text(message.senderName)
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 0)

                    Text(message.timestamp, format: .dateTime.day().month())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(MessageSummary.text(of: message))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }
}

/// One line describing a message, wherever a message has to be named rather than drawn.
///
/// The strip above the conversation, the strip above the composer, and the reply quote all ask
/// the same question — "what does this message say, in one line?" — and they used to answer it
/// three times. The words where there are words; the kind of thing it is where there are not.
enum MessageSummary {
    static func text(of message: Message) -> String {
        if let text = message.editableText { return text }

        return switch message.kind {
        case .image: String(app: Strings.Message.Spoken.sentPhoto)
        case .video: String(app: Strings.Message.Spoken.sentVideo)
        case .videoNote: String(app: Strings.Message.Spoken.sentVideoNote)
        case .voice: String(app: Strings.Message.Spoken.sentVoice)
        case .audio: String(app: Strings.Message.Spoken.sentAudio)
        case .file: String(app: Strings.Message.Spoken.sentFile)
        case .location: String(app: Strings.Location.title)
        case .unreadable: String(app: Strings.Message.Spoken.sentUnreadable)
        case .deleted: String(app: Strings.Message.deleted)
        default: String(app: Strings.Message.unsupported)
        }
    }
}
