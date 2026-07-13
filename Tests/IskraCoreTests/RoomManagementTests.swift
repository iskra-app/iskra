import Testing
import Foundation
@testable import IskraCore

/// The rules that decide who may do what to whom in a room.
///
/// These are the app's own reading of the homeserver's power levels, and every one of them
/// is a *hiding* rule: what it says "no" to is not shown at all. Getting one wrong is
/// therefore invisible until somebody presses a button the server then refuses — which is
/// exactly the failure mode this app is written against, and the reason the rules live in
/// functions that can be asked without a room.
@MainActor
struct RoomManagementTests {
    private func member(_ id: String, _ level: Int, role: RoomRole = .member) -> RoomMemberSummary {
        RoomMemberSummary(id: id,
                          name: id,
                          avatarURL: nil,
                          role: role,
                          authority: .level(level),
                          isNameAmbiguous: false)
    }

    /// The rule is *strictly* above, and the equal case is the one that matters: two
    /// administrators both read as "Administrator", both hold 100, and neither may remove
    /// the other. Offering a "Remove" between them would be a button the room refuses.
    @Test("you may act only on people below you, and never on yourself")
    func authorityIsStrict() {
        let admin = member("@admin:matrix.org", 100, role: .administrator)
        let moderator = member("@mod:matrix.org", 50, role: .moderator)
        let plain = member("@boris:matrix.org", 0)

        #expect(RoomDetailsStore.canManage(plain, asUser: "@admin:matrix.org", holding: .level(100)))
        #expect(RoomDetailsStore.canManage(moderator, asUser: "@admin:matrix.org", holding: .level(100)))

        // An equal is not below you.
        #expect(!RoomDetailsStore.canManage(admin, asUser: "@other:matrix.org", holding: .level(100)))
        // Neither are you.
        #expect(!RoomDetailsStore.canManage(admin, asUser: "@admin:matrix.org", holding: .level(100)))
        // And a moderator does not outrank an administrator.
        #expect(!RoomDetailsStore.canManage(admin, asUser: "@mod:matrix.org", holding: .level(50)))
    }

    /// A room created under version 12 gives its creator an infinite power level, and the
    /// SDK models it as a case rather than as a big number. It has to sort above every
    /// level there is, or an administrator on 100 would be offered a "Remove" on the
    /// founder of the room.
    @Test("the room's creator stands above every number")
    func infinitePowerOutranksEveryone() {
        let creator = RoomMemberSummary(id: "@creator:matrix.org",
                                        name: "creator",
                                        avatarURL: nil,
                                        role: .administrator,
                                        authority: .unlimited,
                                        isNameAmbiguous: false)

        #expect(!RoomDetailsStore.canManage(creator, asUser: "@admin:matrix.org", holding: .level(100)))
        #expect(RoomDetailsStore.canManage(member("@admin:matrix.org", 100, role: .administrator),
                                           asUser: "@creator:matrix.org",
                                           holding: .unlimited))
    }

    /// You may raise somebody to your own level and no further. A moderator who could
    /// appoint an administrator would be handing out power they do not have, and the
    /// homeserver would say so.
    @Test("you can grant your own rank, and nothing above it")
    func rolesAreGrantedUpToYourOwn() {
        #expect(RoomDetailsStore.roles(grantableBy: .level(100)) == [.administrator, .moderator, .member])
        #expect(RoomDetailsStore.roles(grantableBy: .level(50)) == [.moderator, .member])
        #expect(RoomDetailsStore.roles(grantableBy: .level(0)) == [.member])
    }

    /// Checked before the invitation is sent, because the homeserver answers a malformed ID
    /// and an ID it has never heard of with the same shrug — and the person who typed it
    /// needs to know which of the two happened.
    @Test("a Matrix ID is @name:server, and nothing else")
    func matrixIDsAreRecognised() {
        #expect(RoomDetailsStore.isMatrixID("@boris:matrix.org"))
        #expect(RoomDetailsStore.isMatrixID("  @boris:matrix.org "))
        // A server name may carry a port, and the colon in it is not a second separator.
        #expect(RoomDetailsStore.isMatrixID("@boris:matrix.org:8448"))

        #expect(!RoomDetailsStore.isMatrixID("boris"))
        #expect(!RoomDetailsStore.isMatrixID("boris@matrix.org"))
        #expect(!RoomDetailsStore.isMatrixID("@boris"))
        #expect(!RoomDetailsStore.isMatrixID("@:matrix.org"))
        #expect(!RoomDetailsStore.isMatrixID("@boris:"))
        #expect(!RoomDetailsStore.isMatrixID(""))
    }

    /// Every refusal has to be a sentence, in both languages. A missing one surfaces as the
    /// alert reading "roomAction.banFailed", which is the failure `LocalizationTests` exists
    /// to catch — so the refusals are put through the same check, driven from `allCases` so
    /// that an act added later without a sentence fails here.
    @Test("every refused change explains itself in both languages")
    func failuresAreTranslated() {
        for failure in RoomActionFailure.allCases {
            for language in ["en", "ru"] {
                var explanation = failure.explanation
                explanation.locale = Locale(identifier: language)
                let sentence = String(localized: explanation)

                #expect(!sentence.hasPrefix("roomAction."), "\(sentence) is a key, not a sentence")
                #expect(sentence.count > 10, "\(failure) says too little to act on")
            }
        }

        var russian = RoomActionFailure.remove.explanation
        russian.locale = Locale(identifier: "ru")
        #expect(String(localized: russian).contains("остался в чате"))
    }

    /// A room that was not created fails in two different ways, and the user can only fix
    /// one of them — so they are told which one it was.
    @Test("a room that was not created says why in both languages")
    func creationFailuresAreTranslated() {
        for failure in RoomCreationFailure.allCases {
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
