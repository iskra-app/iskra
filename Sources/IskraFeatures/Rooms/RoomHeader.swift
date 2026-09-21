import SwiftUI
import IskraCore
import IskraDesign

/// Who you are talking to, at the top of the conversation.
///
/// This *is* the title — the system's own is removed in `RoomView`, not drawn underneath.
/// And it is a button: the name of a chat is the thing people press when they want to know
/// more about it, in every messenger anyone has ever used, so pressing it here opens the room.
///
/// It comes in two shapes, because a title bar is a different amount of space on a phone
/// than it is on a Mac:
///
/// - `RoomHeader` — picture, name and subtitle in a row, against the leading edge. Mac and
///   iPad, where the bar is wide and a heading belongs at the start of it, aligned with the
///   conversation beneath.
/// - `RoomTitle` + `RoomAvatarButton` — the name centred where a phone expects its title,
///   the picture alone at the trailing edge, under the thumb. iPhone.
///
/// The names are bare words. No pill, no plate, nothing under them.
///
/// They wore one briefly, on the reasoning that a title bar has no floor of its own on 26 and a
/// pale bubble scrolling up behind the name would take it away. That is a real risk and this is
/// not the cure: a capsule of glass around the heading of a screen makes it read as a stray
/// control floating in the middle of the bar rather than as the name of what you are looking at,
/// which is a cost paid on every single screenful to insure against the occasional one. Legibility
/// over a bright bubble is the *material's* job — the toolbar dims what passes under it — and
/// where it is not enough the answer is the bar, not a badge around the words.
///
/// The avatar button beside it keeps its glass, and the difference is the point: it is a control,
/// and the back button facing it across the bar is a control on a glass circle of exactly the same
/// kind. A title is not a control even when it happens to be tappable.
///
/// The lock is a glyph, not a control. It used to be a button that explained itself in a
/// popover, and it cannot stay one: a button inside a button is ambiguous to the eye and
/// a mess for VoiceOver. The sentence it used to show now has a row of its own on the
/// room-info screen — which is one press away, and is where somebody asking "is this
/// private?" is going anyway.
///
/// All of them take plain values rather than the store, so they can be looked at in a
/// preview and a test without a signed-in session behind them.
struct RoomHeader: View {
    let name: String
    let avatarURL: String?
    /// See `TimelineStore.roomAvatarSeed`.
    var avatarSeed: String?
    let privacy: PrivacyStatus

    /// The line under the name: how many people are here, or — in a chat with one other
    /// person — their Matrix ID. Absent until the room has synced enough to say, because
    /// a header that reads "0 participants" for a moment is worse than one that is briefly
    /// just a name.
    let subtitle: String?

    var onOpenDetails: () -> Void

    var body: some View {
        Button(action: onOpenDetails) {
            HStack(spacing: Theme.Spacing.close) {
                Avatar(name: name, url: avatarURL, size: Theme.Size.avatarSmall, seed: avatarSeed)
                RoomIdentity(name: name, privacy: privacy, subtitle: subtitle, alignment: .leading)
            }
            // A title bar is a crowded place and a long room name will happily eat the
            // buttons on either side of it. This keeps the header honest about how much
            // room it is allowed to take, and lets the name truncate instead.
            .frame(maxWidth: Theme.Size.roomHeader, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .roomHeaderAccessibility(name: name, privacy: privacy, subtitle: subtitle)
    }
}

/// The iPhone title: the name in the middle of the bar, and nothing else in the middle of
/// the bar. The picture is not here — it is `RoomAvatarButton`, at the trailing edge — because
/// a phone's title bar is about a third the width of a Mac's, and an avatar in the centre
/// spends that width on decoration rather than on the name.
struct RoomTitle: View {
    let name: String
    let privacy: PrivacyStatus
    let subtitle: String?

    var onOpenDetails: () -> Void

    var body: some View {
        Button(action: onOpenDetails) {
            RoomIdentity(name: name, privacy: privacy, subtitle: subtitle, alignment: .center)
                .frame(maxWidth: Theme.Size.roomHeader)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .roomHeaderAccessibility(name: name, privacy: privacy, subtitle: subtitle)
    }
}

/// The chat's picture, alone at the trailing end of an iPhone's title bar, and the second
/// way into the same room-info screen the title opens.
///
/// This one *does* sit on glass, unlike the name across the bar from it, and the difference is the
/// point: it is a control, and the back button facing it is a control on a glass circle of exactly
/// the same kind. Left bare it read as a picture that had been dropped into the bar rather than as
/// the button it is.
///
/// The glass is *ours*, though, and that is the whole trick — the toolbar's own shared
/// background is hidden at the item (see `RoomView`). A shared background sizes itself to the
/// item it wraps, with the toolbar's own margins around it, and a round picture inside those
/// margins came out with a crescent of glass to its left and its right: an oval with an avatar
/// marooned in the middle of it. `.buttonBorderShape(.circle)` rounds that oval and does not
/// shrink it, because the padding is the bar's, not the button's, and it is not ours to argue
/// with — it is only ours to step out of.
///
/// So: a circle of glass cut to the picture plus `Theme.Spacing.tight` of ring, which is what
/// takes the whole control to exactly the 44pt a finger needs. Nothing phantom left in it.
struct RoomAvatarButton: View {
    let name: String
    let avatarURL: String?
    /// See `TimelineStore.roomAvatarSeed`.
    var avatarSeed: String?

    var onOpenDetails: () -> Void

    var body: some View {
        Button(action: onOpenDetails) {
            Avatar(name: name, url: avatarURL, size: Theme.Size.avatarToolbar, seed: avatarSeed)
                .padding(Theme.Spacing.tight)
                .navigationGlass(in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Room.detailsTitle))
        .accessibilityHint(Text(Strings.Room.openDetails))
    }
}

/// The name, the lock and the line underneath — the part both layouts have in common, told
/// only which way to align.
private struct RoomIdentity: View {
    let name: String
    let privacy: PrivacyStatus
    let subtitle: String?
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)

                // The same closed lock as the room list, and the only encryption
                // vocabulary on this screen.
                if privacy == .protected {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private extension View {
    /// One sentence: who, how private, and how many. VoiceOver reads the header as a
    /// thought rather than as three fragments, and the lock — which is silent to the eye
    /// on purpose — is finally said out loud.
    func roomHeaderAccessibility(name: String,
                                 privacy: PrivacyStatus,
                                 subtitle: String?) -> some View {
        var parts = [name]
        if privacy == .protected {
            parts.append(String(app: Strings.RoomList.privateChat))
        }
        if let subtitle {
            parts.append(subtitle)
        }

        return accessibilityElement(children: .combine)
            .accessibilityLabel(parts.joined(separator: ", "))
            .accessibilityHint(Text(Strings.Room.openDetails))
            .accessibilityAddTraits(.isButton)
    }
}
