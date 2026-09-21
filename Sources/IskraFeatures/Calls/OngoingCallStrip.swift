import SwiftUI
import IskraCore
import IskraDesign

/// The strip above a conversation where a call is already happening.
///
/// It sits above the pinned message rather than below it, and the order is the argument: a pinned
/// message has been there for days and a call is happening this second. Two strips at once is
/// rare and looks fine; two strips in the wrong order puts the urgent one underneath.
///
/// It says who is in there, because that is the question somebody actually has. "Call in progress"
/// on its own is a fact about the room; three faces are a reason to join or not to.
struct OngoingCallStrip: View {
    let participants: [String]
    let onJoin: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            Image(systemName: "phone.fill")
                .foregroundStyle(accent.color)

            Text(Strings.Call.ongoing)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            faces

            Spacer(minLength: Theme.Spacing.close)

            Button(String(app: Strings.Call.join), action: onJoin)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.color)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.close)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    /// A few faces, not all of them.
    ///
    /// The same person appears twice in the SDK's list when they joined from two devices — that is
    /// a fact about sessions and not about who is in the room, so it is folded away here. Four at
    /// most: past that it is a crowd, and a crowd is not read, it is counted.
    private var faces: some View {
        HStack(spacing: -Theme.Spacing.tight) {
            ForEach(shown, id: \.self) { userID in
                // No picture, on purpose: fetching a photograph for every person in a call, to
                // draw it at 28 points on a strip that lasts as long as the call does, is a
                // round trip per face for an ornament. The seed gives a creature, and a
                // creature is computed on the device from the ID that is already here.
                Avatar(name: userID, url: nil, size: Theme.Size.avatarSmall, seed: userID)
            }
        }
    }

    private var shown: [String] {
        var seen: Set<String> = []
        return participants.filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }
}
