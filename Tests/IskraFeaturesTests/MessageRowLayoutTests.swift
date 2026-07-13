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
        try render(isDirectChat: true, named: "messages-direct")
    }

    @Test("a room keeps the avatar and the sender's name")
    func room() throws {
        try render(isDirectChat: false, named: "messages-room")
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

    private func render(isDirectChat: Bool, named name: String) throws {
        let view = VStack(spacing: 0) {
            ForEach(conversation) { message in
                MessageRow(message: message, isDirectChat: isDirectChat)
            }
        }
        .frame(width: 390)
        .padding()
        .background(.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        #if os(macOS)
        let image = try #require(renderer.nsImage, "the conversation failed to render at all")

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
}
