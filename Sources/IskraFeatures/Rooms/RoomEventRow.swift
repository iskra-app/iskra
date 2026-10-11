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

    /// Whether a date sits directly above this note and has already given it its air —
    /// see `MessageRow.opensDay`.
    var opensDay: Bool = false

    /// Where a pressed name goes — the person's page. Nil outside a room (a peek), and then the
    /// names are only words.
    @Environment(\.openProfile) private var openProfile

    var body: some View {
        Text(Self.linked(event, linking: openProfile != nil))
            .font(.caption)
            .foregroundStyle(.secondary)
            // The names are the room's people, not links out of the app: drawn as the line's own
            // grey, only heavier, the way Telegram draws them — and pressing one opens the page of
            // the person it names rather than a browser.
            .tint(.secondary)
            .environment(\.openURL, OpenURLAction { url in
                guard let userID = Self.userID(in: url) else { return .systemAction }
                openProfile?(userID)
                return .handled
            })
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.normal)
            .padding(.vertical, Theme.Spacing.tight)
            .frame(maxWidth: .infinity)
            .padding(.top, followsEvent || opensDay ? 0 : Theme.Spacing.betweenSenders)
    }

    /// The sentence, with every name in it that belongs to a person made into a link to them.
    ///
    /// Found in the finished sentence rather than built into it, because the sentence is composed
    /// in the reader's language (`RoomEvent.text`) and where a name falls in it is that language's
    /// business. The first occurrence of each name is the one linked — names are long enough, and the
    /// words around them short enough, that the first is the name.
    static func linked(_ event: RoomEvent, linking: Bool) -> AttributedString {
        var text = AttributedString(event.text)
        guard linking else { return text }

        for person in event.people where !person.name.isEmpty {
            guard let range = text.range(of: person.name),
                  let url = link(to: person.userID) else { continue }
            text[range].link = url
            text[range].font = .caption.weight(.semibold)
        }
        return text
    }

    /// A link that only this row understands: `iskra-person:` and the Matrix ID.
    static func link(to userID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.path = userID
        return components.url
    }

    static func userID(in url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }

    private static let scheme = "iskra-person"
}

extension EnvironmentValues {
    /// Opens a person's page, by Matrix ID — set by the room, read by anything in it that names
    /// somebody: a grey line, a face beside a message.
    @Entry var openProfile: ((String) -> Void)?
}
