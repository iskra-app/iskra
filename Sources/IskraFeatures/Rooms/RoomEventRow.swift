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

    /// Whether the note directly above this one is also a note.
    ///
    /// A room opening is never one event: it was created, it was named, it was given a picture,
    /// someone was invited, someone joined — five lines about the same minute. Spaced as if each
    /// were a separate announcement they fill the screen and read as five separate announcements.
    /// Closed up they read as one paragraph, which is what they are, and the gap only opens where
    /// the run begins.
    var followsEvent: Bool = false

    var body: some View {
        Text(event.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.tight)
            .frame(maxWidth: .infinity)
            .padding(.top, followsEvent ? 0 : Theme.Spacing.betweenSenders)
    }
}
