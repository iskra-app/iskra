import SwiftUI
import IskraCore
import IskraDesign

/// Something that happened in the room that nobody said: a person arriving, the room being
/// renamed, the day it was encrypted.
///
/// One grey line down the middle of the conversation, and deliberately the quietest thing on
/// the screen. It is not a message — there is no bubble, no avatar, no side of the screen it
/// belongs to, nothing to react to and nothing to answer. It is a note in the margin, and the
/// eye should be able to skip it.
///
/// The sentence itself is composed in `IskraCore` (`RoomEvent.text`), because five people
/// joining and one person joining are the same event with a different list in it, and pooling
/// them is not something a view can do to finished sentences.
struct RoomEventRow: View {
    let event: RoomEvent

    var body: some View {
        Text(event.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.close)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.betweenSenders)
    }
}
