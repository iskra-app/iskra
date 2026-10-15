import Foundation
import Testing
@testable import IskraCore
import MatrixRustSDK

/// Which photos become one album — see `Album`.
@Suite("Albums")
struct AlbumTests {
    private func photo(_ id: String, at second: TimeInterval, from sender: String = "@a:example.org",
                       caption: String? = nil, replying: Bool = false) throws -> TimelineRow {
        let attachment = Attachment(source: try MediaSource.fromUrl(url: "mxc://example.org/\(id)"),
                                    thumbnailSource: nil, filename: "\(id).jpg", caption: caption,
                                    width: 400, height: 300, duration: nil, mimeType: "image/jpeg",
                                    blurhash: nil)
        return .message(Message(id: id, kind: .image(attachment), senderID: sender, senderName: "А",
                                senderAvatarURL: nil, isOwn: false,
                                timestamp: Date(timeIntervalSince1970: second), delivery: nil,
                                isEdited: false,
                                replyTo: replying ? ReplyPreview(eventID: "$q", senderName: "Б", senderID: "@b:example.org", text: "?") : nil,
                                reactions: []))
    }

    private func text(_ id: String, at second: TimeInterval) -> TimelineRow {
        .message(Message(id: id, kind: .text("…"), senderID: "@a:example.org", senderName: "А",
                         senderAvatarURL: nil, isOwn: false, timestamp: Date(timeIntervalSince1970: second),
                         delivery: nil, isEdited: false, reactions: []))
    }

    /// What the grouped rows look like: each row's message IDs, joined.
    private func shape(_ rows: [TimelineRow]) -> [String] {
        Album.grouping(rows).map { row in
            row.message.map { $0.members.map(\.id).joined(separator: "+") } ?? row.id
        }
    }

    @Test("photos sent together are one row, named after the first")
    func together() throws {
        let rows = Album.grouping([try photo("a", at: 0), try photo("b", at: 2), try photo("c", at: 5)])
        #expect(rows.count == 1)
        #expect(rows[0].id == "a")
        #expect(rows[0].message?.album?.map(\.id) == ["a", "b", "c"])
    }

    @Test("a long pause between two photos keeps them apart")
    func apart() throws {
        #expect(shape([try photo("a", at: 0), try photo("b", at: 60)]) == ["a", "b"])
    }

    /// The gap is between neighbours: a slow upload of ten photos takes a while in all, and is
    /// still one album.
    @Test("the gap is measured between neighbours")
    func neighbours() throws {
        let rows = try (0..<5).map { try photo("p\($0)", at: TimeInterval($0) * 12) }
        #expect(shape(rows) == ["p0+p1+p2+p3+p4"])
    }

    @Test("two people's photos are never one album")
    func senders() throws {
        #expect(shape([try photo("a", at: 0), try photo("b", at: 1, from: "@b:example.org")]) == ["a", "b"])
    }

    @Test("anything said in between breaks it")
    func interrupted() throws {
        #expect(shape([try photo("a", at: 0), text("t", at: 1), try photo("b", at: 2)]) == ["a", "t", "b"])
    }

    @Test("a caption may only open an album")
    func captionOpens() throws {
        let rows = [try photo("a", at: 0, caption: "море"), try photo("b", at: 1), try photo("c", at: 2)]
        #expect(shape(rows) == ["a+b+c"])
        #expect(Album.grouping(rows).first?.message?.albumCaption == "море")
        // One further in starts the next album.
        let two = [try photo("a", at: 0), try photo("b", at: 1, caption: "пляж"), try photo("c", at: 2)]
        #expect(shape(two) == ["a", "b+c"])
    }

    @Test("a reply may only start an album")
    func replies() throws {
        #expect(shape([try photo("a", at: 0, replying: true), try photo("b", at: 1)]) == ["a+b"])
        #expect(shape([try photo("a", at: 0), try photo("b", at: 1, replying: true)]) == ["a", "b"])
    }

    @Test("ten to an album")
    func limit() throws {
        let rows = try (0..<12).map { try photo("p\($0)", at: TimeInterval($0)) }
        #expect(Album.grouping(rows).compactMap { $0.message?.members.count } == [10, 2])
    }

    @Test("a picture inside an album is found by its own ID")
    func lookup() throws {
        let rows = Album.grouping([try photo("a", at: 0), try photo("b", at: 1)])
        #expect(rows.message(withID: "b")?.id == "b")
    }
}

/// The words under a picture — see `MediaCaption`.
@Suite("Media captions")
struct MediaCaptionTests {
    @Test("a plain caption has no HTML")
    func plain() throws {
        let caption = try #require(MediaCaption(text: "  закат  ", mentions: []))
        #expect(caption.body == "закат")
        #expect(caption.html == nil)
    }

    @Test("an empty caption is no caption")
    func empty() {
        #expect(MediaCaption(text: " \n ", mentions: []) == nil)
    }

    @Test("one star is bold, as in the composer")
    func bold() throws {
        let caption = try #require(MediaCaption(text: "это *важно* & <да>", mentions: []))
        #expect(caption.html == "это <strong>важно</strong> &amp; &lt;да&gt;")
    }

    @Test("a mention becomes a link and goes in m.mentions")
    func mention() throws {
        let kai = ComposerMention(userID: "@kai:m.org", name: "Kai")
        let caption = try #require(MediaCaption(text: "смотри, @Kai", mentions: [kai]))
        #expect(caption.mentionedUserIDs == ["@kai:m.org"])
        #expect(caption.html == "смотри, <a href=\"https://matrix.to/#/@kai:m.org\">@Kai</a>")
        // The body is the Markdown, so an edit can find the mention again.
        #expect(ComposerMentions.unlinked(caption.body).mentions == [kai])
    }
}
