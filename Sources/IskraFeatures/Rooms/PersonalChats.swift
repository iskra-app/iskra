import SwiftUI
import IskraCore

/// Writing to somebody you have met in a room: the conversation you already have with them, or a
/// new one if you do not.
///
/// Handed down through the environment like `Forwarding`, and for the same reason — it is a thing a
/// screen deep inside one room needs to do to *another* room, and wiring the member profile to the
/// whole session to do it would make a screen that only ever shows one person depend on everything.
///
/// The lookup is deliberately not "find a room in the list with these two people in it". See
/// `UserSession.directChat(with:)`: a personal chat is the room the account's own `m.direct` data
/// names, which is what every other client signed into this account calls the conversation with
/// that person. A guess from the room list would be right most of the time, and the rest of the
/// time it would reopen a room the user had left.
@MainActor
@Observable
public final class PersonalChats {
    private let session: UserSession

    public init(session: UserSession) {
        self.session = session
    }

    /// The chat that is already there, if there is one. Cheap and synchronous — it reads the local
    /// store — so a button may ask it while deciding what to call itself.
    public func existing(with userID: String) -> String? {
        session.directChat(with: userID)
    }

    /// The chat, opened: the existing one, or a new one made and waited for. `nil` when the server
    /// refused, which the caller says out loud rather than swallowing — a button that appears to do
    /// nothing is worse than an error.
    public func open(with userID: String) async -> String? {
        try? await session.openDirectChat(with: userID)
    }
}

public extension EnvironmentValues {
    /// Writing to one person. Nil until a session is up.
    @Entry var personalChats: PersonalChats?

    /// Putting a conversation on the screen, from anywhere in the app.
    ///
    /// The selected room lives at the root — it is what the split view's detail column is — and the
    /// screens that want to change it are several pushes deep in that same column. This is the one
    /// wire between them, rather than a binding threaded through every view in between.
    ///
    /// Nil where nothing can act on it, which is not only previews: on a screen with no room list
    /// behind it there is no "go to the chat", and a button that calls nobody should not be drawn.
    @Entry var openRoom: ((String) -> Void)?
}
