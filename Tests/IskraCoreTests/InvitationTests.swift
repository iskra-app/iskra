import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore

/// Being asked into a room, which the app could not do at all until now.
///
/// The list had always *carried* invitations — the SDK's filter is `.nonLeft`, and an invitation
/// you have not answered is not a room you have left — and had never said so. An invited room came
/// through as an ordinary chat with no last message, sank to the bottom of the list under every
/// conversation the user had ever had, opened onto an empty conversation, and refused everything
/// typed into it, because you are not in the room. These are the rules that end that.
@MainActor
struct InvitationTests {
    private func room(_ id: String,
                      at activity: Date?,
                      membership: RoomMembership = .joined) -> RoomSummary {
        RoomSummary(id: id,
                    name: id,
                    lastActivity: activity,
                    membership: membership)
    }

    /// The one that matters, and the one the old sort got exactly backwards.
    ///
    /// An invited room has no messages in it, so it has no `lastActivity` — and the recency sort
    /// puts a room with no recency *last*. So the single row that is asking the user a question
    /// would have been the very last one they ever scrolled to.
    @Test("an invitation goes to the top, above every conversation")
    func invitationsSortFirst() {
        let now = Date.now
        let sorted = RoomListStore.byRecency([
            room("recent", at: now),
            room("older", at: now.addingTimeInterval(-3600)),
            room("invite", at: nil, membership: .invited)
        ])

        #expect(sorted.map(\.id) == ["invite", "recent", "older"])
    }

    /// Two invitations do not reshuffle each other on every rebuild.
    @Test("invitations keep a stable order among themselves")
    func invitationsAreStableAmongThemselves() {
        let sorted = RoomListStore.byRecency([
            room("first", at: nil, membership: .invited),
            room("second", at: nil, membership: .invited),
            room("chat", at: .now)
        ])

        #expect(sorted.map(\.id) == ["first", "second", "chat"])
    }

    /// A room in a state the list has no business showing is *dropped*, not guessed at.
    ///
    /// `RoomSummary.init?` fails on anything that is neither joined nor invited, and that is the
    /// point of it: defaulting to `.joined` would render a room you had been banned from as an
    /// ordinary chat you could sit and type into, which is the whole class of bug this type exists
    /// to end.
    @Test("only joined and invited are rooms; the rest are not rows at all")
    func onlyJoinedAndInvitedBecomeRows() {
        #expect(RoomMembership(.joined) == .joined)
        #expect(RoomMembership(.invited) == .invited)

        #expect(RoomMembership(.left) == nil)
        #expect(RoomMembership(.banned) == nil)
        #expect(RoomMembership(.knocked) == nil)
    }

    /// An invitation names who sent it, in both languages — and names them without guessing at
    /// their gender, which Russian would otherwise force us to do on every name in every room.
    @Test("an invitation says who is asking, in both languages, and guesses nobody's gender")
    func theInvitationNamesTheInviter() {
        var russian = CoreStrings.Push.invite("Аня")
        russian.locale = Locale(identifier: "ru")
        #expect(String(localized: russian) == "Аня приглашает вас в чат")

        var english = CoreStrings.Push.invite("Аня")
        english.locale = Locale(identifier: "en")
        #expect(String(localized: english) == "Аня invites you to the chat")
    }

    /// Both ways an invitation can be refused have a sentence, in both languages. Declining is the
    /// one worth having its own: the user believes they are rid of the room, and they are not.
    @Test("a refused invitation explains itself in both languages")
    func refusalsAreExplained() {
        for failure in [RoomActionFailure.acceptInvite, .declineInvite] {
            for language in ["en", "ru"] {
                var explanation = failure.explanation
                explanation.locale = Locale(identifier: language)
                let sentence = String(localized: explanation)

                #expect(!sentence.hasPrefix("roomAction."), "\(sentence) is a key, not a sentence")
                #expect(sentence.count > 10, "\(failure) says too little to act on")
            }
        }
    }
}
