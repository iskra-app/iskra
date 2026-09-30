import Testing
import SwiftUI
import Foundation
@testable import IskraCore
@testable import IskraDesign
@testable import IskraFeatures

#if os(macOS)
import AppKit
#endif

/// Renders a conversation to a PNG so the bubbles can actually be looked at.
///
/// The same trick as `ComposerLayoutTests`. It works here because bubbles are *content*
/// and content is opaque: unlike the glass in the composer and the search field, an
/// opaque fill is something `ImageRenderer` can draw. So the one part of the design that
/// can be checked without signing into a homeserver is checked here.
@MainActor
struct MessageRowLayoutTests {
    /// Where the images land. Set `ISKRA_RENDER_DIR` to collect them.
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["ISKRA_RENDER_DIR"].map { URL(filePath: $0) }
    }

    private func message(_ text: String,
                         isOwn: Bool,
                         at minute: Int,
                         delivery: DeliveryStatus? = nil,
                         isContinuation: Bool = false,
                         reactions: [MessageReaction] = [],
                         kind: MessageKind? = nil,
                         deletedAt: Date? = nil) -> Message {
        Message(id: UUID().uuidString,
                kind: kind ?? .text(text),
                senderID: isOwn ? "@me:matrix.org" : "@nadia:matrix.org",
                senderName: isOwn ? "Me" : "Nadia Petrova",
                senderAvatarURL: nil,
                isOwn: isOwn,
                timestamp: Date(timeIntervalSince1970: 1_770_000_000 + Double(minute) * 60),
                delivery: delivery,
                isEdited: false,
                reactions: reactions,
                deletedAt: deletedAt,
                isContinuation: isContinuation)
    }

    /// A one-line message must come out a capsule and a wrapped one a rounded rectangle,
    /// which is the whole point of a single large radius. Both shapes appear here.
    ///
    /// Reactions appear on both sides, because they hang off opposite edges: under an
    /// incoming message they line up with the bubble's left edge — past the avatar, not
    /// under it — and under your own they line up with its right.
    private var conversation: [Message] {
        [
            message("Hey", isOwn: false, at: 0),
            message("Are you around this evening? I wanted to show you the thing we were talking about.",
                    isOwn: false, at: 1, isContinuation: true,
                    reactions: [MessageReaction(key: "👍", count: 2, isMine: true),
                                MessageReaction(key: "🙏", count: 1, isMine: false)]),
            message("Yes", isOwn: true, at: 3, delivery: .read,
                    reactions: [MessageReaction(key: "😂", count: 4, isMine: false)]),
            message("Give me twenty minutes and I’ll call you back.", isOwn: true, at: 4, delivery: .sent),
            // A message that was taken back. It keeps its place in the conversation, its
            // clock, and — under a long press — the two dates that are all it has left to
            // say; what it does not keep is anything you can do to it.
            message("", isOwn: true, at: 4, delivery: .sent, kind: .deleted,
                    deletedAt: Date(timeIntervalSince1970: 1_770_000_600)),
            // A failed one, because the badge beside it is the loudest thing on the screen
            // and the only way to check it is aimed at the middle of the bubble — and not,
            // as it would be if it rode in the clock's row, at the bubble's last line.
            message("Test", isOwn: true, at: 5, delivery: .failed(.server))
        ]
    }

    @Test("a direct chat renders without avatars or names, with the time beside each bubble")
    func directChat() throws {
        try render(isOneToOne: true, named: "messages-direct")
    }

    @Test("a room keeps the avatar and the sender's name")
    func room() throws {
        try render(isOneToOne: false, named: "messages-room")
    }

    /// The badge's popover, side by side in both shapes: with "Send again" where trying
    /// again can work, and without it where it cannot. Delete is in both, because a message
    /// that can never be sent is exactly the one the user most needs to be rid of. A popover
    /// cannot be presented offscreen, so `SendFailureReason` is rendered directly —
    /// otherwise the only way to see this layout would be to tap a simulator and take its
    /// word for it.
    @Test("the failure popover offers Send again only where it can work, and Delete always")
    func failureReasons() throws {
        let view = HStack(alignment: .top, spacing: Theme.Spacing.roomy) {
            SendFailureReason(failure: .server, onRetry: {}, onDiscard: {})
            SendFailureReason(failure: .missingMedia, onRetry: {}, onDiscard: {})
        }
        .padding()
        .background(.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        #if os(macOS)
        let image = try #require(renderer.nsImage, "the popover failed to render at all")
        #expect(image.size.height > 60)

        guard let directory = outputDirectory else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(component: "failure-reasons.png"))
        #endif
    }

    /// Both identity banners, in Russian, at a phone's width — the longer language, where a title
    /// that ran out of room would be cut first. And the popover for a message stopped on trust,
    /// which offers "Send anyway" and not "Send again".
    @Test("the identity banners and Send anyway fit a phone, in Russian")
    func identityBanners() throws {
        let changed = IdentityChange(userID: "@anya:iskra.demo", name: "Аня Смирнова", kind: .changed)
        let serious = IdentityChange(userID: "@anya:iskra.demo", name: "Аня Смирнова", kind: .changedAfterVerification)
        let view = VStack(spacing: Theme.Spacing.roomy) {
            IdentityChangeBanner(change: changed, onAcknowledge: {})
            IdentityChangeBanner(change: serious, onAcknowledge: {})
            SendFailureReason(failure: .identityChanged, onRetry: {}, onDiscard: {})
        }
        .frame(width: 390)
        .background(.background)
        .environment(\.locale, Locale(identifier: "ru"))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        #if os(macOS)
        let image = try #require(renderer.nsImage, "the banners failed to render at all")
        #expect(image.size.height > 200)

        guard let directory = outputDirectory else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(component: "identity-banners.png"))
        #endif
    }

    /// The same conversation, drawn as the plain column instead — see `CompactMessageRow`.
    ///
    /// The fixture earns its keep unchanged: the second message is a continuation, so the run
    /// header has to appear exactly once and the line under it has to indent to the same column;
    /// the deleted one exercises the tombstone with no bubble around it to sit in; the failed
    /// one puts the badge at the end of a line rather than in front of it.
    @Test("the plain column draws one header per run, and lines under it")
    func compactRoom() throws {
        try render(named: "messages-compact") { message in
            CompactMessageRow(message: message)
        }
    }

    #if os(macOS)
    /// Your own message and somebody else's come out the same height, because both carry a name.
    ///
    /// This is the decision that has no analogue in the bubbles, and the one most likely to be
    /// "tidied" away by somebody who notices the app never named your own messages before. It
    /// cannot be checked by handing the row an `isOneToOne` — it has none, deliberately — so
    /// what is checked is the consequence: nothing in the plain column may depend on whose
    /// message it is, and a header dropped from your own would show up here as two different
    /// heights.
    @Test("the plain column names you as readily as anybody else")
    func compactNamesEverySender() throws {
        let mine = try #require(rendered([message("Yes", isOwn: true, at: 0)]) {
            CompactMessageRow(message: $0)
        })
        let theirs = try #require(rendered([message("Yes", isOwn: false, at: 0)]) {
            CompactMessageRow(message: $0)
        })

        #expect(mine.size.height == theirs.size.height,
                "your own line came out \(mine.size.height)pt against \(theirs.size.height)pt — one of them is missing its name")
    }

    /// The reason anybody chooses this: a run of one person talking is *shorter* without the
    /// bubbles. A conversation that alternates would prove nothing — the plain column pays a
    /// header per speaker, and the bubbles pay a name — so the fixture here is one long run.
    @Test("a run of one person talking is shorter without the bubbles")
    func aRunIsShorterWithoutBubbles() throws {
        let run = (0..<5).map {
            message("Same person, still talking, line \($0)",
                    isOwn: false, at: $0, isContinuation: $0 > 0)
        }

        let bubbles = try #require(rendered(run) { MessageRow(message: $0, isOneToOne: false) })
        let compact = try #require(rendered(run) { CompactMessageRow(message: $0) })

        #expect(compact.size.height < bubbles.size.height,
                "the plain column came out \(compact.size.height)pt against the bubbles' \(bubbles.size.height)pt — it is not saving anything")
    }
    #endif

    private func render(isOneToOne: Bool, named name: String) throws {
        try render(named: name) { message in
            MessageRow(message: message, isOneToOne: isOneToOne)
        }
    }

    private func render(named name: String,
                        @ViewBuilder row: @escaping (Message) -> some View) throws {
        #if os(macOS)
        let image = try #require(rendered(conversation, row: row),
                                 "the conversation failed to render at all")

        // A conversation that renders as a sliver is broken, whatever the picture shows.
        #expect(image.size.width > 380)
        #expect(image.size.height > 100)

        guard let directory = outputDirectory else { return }

        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(component: "\(name).png"))
        #endif
    }

    #if os(macOS)
    /// One conversation, drawn by whichever row was asked for.
    ///
    /// `timelineWidth` is what `RoomView` measures and hands down in the app. Without it the rows
    /// are drawn with no idea how wide the conversation is, and the one thing that depends on
    /// that — how far a bubble may run before the far edge pushes back — would be tested at a
    /// width the app never uses. See `MessageRow.emptyColumn`.
    private func rendered(_ messages: [Message],
                          @ViewBuilder row: @escaping (Message) -> some View) -> NSImage? {
        let view = VStack(spacing: 0) {
            ForEach(messages) { message in
                row(message)
            }
        }
        .frame(width: 390)
        .environment(\.timelineWidth, 390)
        .padding()
        .background(.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }
    #endif
}
