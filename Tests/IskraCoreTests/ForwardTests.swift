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

    @Test("a forward says it is one, names nobody, and mentions nobody")
    func forwardContent() throws {
        let content = try #require(Forwarded.content(forwarding: message(.text("hi"))))
        #expect(content["body"] as? String == "hi")
        #expect(content["msgtype"] as? String == "m.text")
        let forwarded = try #require(content["m.forwarded"] as? [String: Any])
        // Neither who wrote it nor where — see `Forwarded.content`.
        #expect(forwarded["sender"] == nil && forwarded["displayname"] == nil)
        // Never where it came from — see `Forwarded.content`.
        #expect(forwarded["event_id"] == nil && forwarded["room_id"] == nil)
        #expect((forwarded["content"] as? [String: Any])?["body"] as? String == "hi")
        #expect((content["m.mentions"] as? [String: Any])?.isEmpty == true)

        // And it reads back as the origin it was written from.
        let origin = try #require(Forwarded.origin(inContent: content))
        #expect(origin.senderID == nil)
        #expect(origin.displayName == nil)
        #expect(origin.timestamp == Date(timeIntervalSince1970: 0))
    }

    @Test("a forward of a forward does not carry the original's author on either")
    func forwardOfForward() throws {
        var forward = message(.text("hi"))
        forward.forwardedFrom = ForwardOrigin(senderID: "@first:example.org", senderName: "Первый", eventID: "$first")
        let content = try #require(Forwarded.content(forwarding: forward))
        let origin = try #require(Forwarded.origin(inContent: content))
        #expect(origin.senderID == nil && origin.displayName == nil && origin.eventID == nil)
    }

    @Test("an event read off the wire: MSC2723's shape, with or without a name")
    func originFromJSON() {
        let json = #"{"type":"m.room.message","content":{"msgtype":"m.text","body":"x","m.forwarded":{"sender":"@b:x","origin_server_ts":1000}}}"#
        let origin = Forwarded.origin(inEventJSON: json)
        #expect(origin?.displayName == "@b:x")
        #expect(origin?.timestamp == Date(timeIntervalSince1970: 1))
        #expect(Forwarded.origin(inEventJSON: #"{"content":{"body":"x"}}"#) == nil)
    }

    @Test("only words are sent marked")
    func onlyWords() {
        #expect(Forwarded.content(forwarding: message(.deleted)) == nil)
    }
}
