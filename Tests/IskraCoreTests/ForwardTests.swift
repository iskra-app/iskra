import Testing
import Foundation
@testable import IskraCore

/// Which messages offer to be forwarded. The send itself crosses rooms and the network, so it is
/// exercised on a device — but the rule for *whether* a message can be forwarded is a pure property
/// of the message, and it is pinned here.
struct ForwardTests {
    private func message(_ kind: MessageKind) -> Message {
        Message(id: "$e",
                kind: kind,
                senderID: "@a:example.org",
                senderName: "А",
                senderAvatarURL: nil,
                isOwn: false,
                timestamp: Date(timeIntervalSince1970: 0),
                delivery: nil,
                isEdited: false,
                reactions: [])
    }

    @Test("words can be forwarded")
    func textForwards() {
        #expect(message(.text("hi")).canForward)
        #expect(message(.notice("system")).canForward)
        #expect(message(.emote("waves")).canForward)
    }

    @Test("a deleted message cannot be forwarded — there is nothing left to send")
    func deletedDoesNotForward() {
        #expect(!message(.deleted).canForward)
    }

    @Test("an unreadable message cannot be forwarded")
    func unreadableDoesNotForward() {
        #expect(!message(.unreadable).canForward)
    }
}
