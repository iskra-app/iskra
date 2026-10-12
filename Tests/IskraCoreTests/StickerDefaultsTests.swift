import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import MatrixRustSDK
@testable import IskraCore

/// A real WebP, small enough to write out. ImageIO reads WebP and cannot write it, so one cannot
/// be made in the test.
enum StickerFixtures {
    /// One pixel, lossless.
    static let webP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
}

@Suite("WebP as a sticker")
struct StickerPictureTests {
    @Test("a WebP is a sticker, kept as it is when there is nothing in it but the picture")
    func webP() {
        guard case let .ready(picture) = StickerPicture.prepare(StickerFixtures.webP) else {
            Issue.record("a WebP was not taken as a sticker")
            return
        }
        #expect(picture.data == StickerFixtures.webP)
        #expect(picture.mimeType == "image/webp")
        #expect(picture.filename == "sticker.webp")
        #expect(picture.width == 1 && picture.height == 1)
        #expect(!picture.isAnimated)
    }

    @Test("anything else is a photo — whatever its name says")
    func notWebP() {
        #expect(StickerPicture.prepare(StickerArt.happy.png()) == .notASticker)
        #expect(StickerPicture.prepare(Data("not a picture".utf8)) == .notASticker)
    }

    @Test("what is drawn as a sticker on arrival")
    func receiving() {
        #expect(StickerPicture.isSticker(mimeType: "image/webp"))
        #expect(StickerPicture.isSticker(mimeType: "IMAGE/WEBP"))
        #expect(!StickerPicture.isSticker(mimeType: "image/png"))
        #expect(!StickerPicture.isSticker(mimeType: nil))
    }

    /// The encrypted way: an `m.image` of type `image/webp`. The chat list and the lock screen
    /// read it through `MessagePreview`, and must say "Sticker" as the timeline draws one.
    @Test("an encrypted WebP image reads as a sticker in the chat list and on the lock screen")
    func preview() throws {
        func image(_ mimeType: String) throws -> MessageType {
            .image(content: ImageMessageContent(filename: "x",
                                                caption: nil,
                                                formattedCaption: nil,
                                                source: try MediaSource.fromUrl(url: "mxc://x/y"),
                                                info: ImageInfo(height: 1, width: 1, mimetype: mimeType, size: 1,
                                                                thumbnailInfo: nil, thumbnailSource: nil,
                                                                blurhash: nil, isAnimated: false)))
        }
        #expect(MessagePreview.text(for: try image("image/webp")) == String(core: CoreStrings.Preview.sticker))
        #expect(MessagePreview.text(for: try image("image/jpeg")) == String(core: CoreStrings.Preview.photo))
    }
}

@Suite("The built-in pack")
@MainActor
struct BuiltInStickerTests {
    final class Server: Sendable {
        let data = Mutex<[String: String]>([:])
        let uploads = Mutex<Int>(0)
    }

    private func library(_ server: Server, failing: Bool = false) -> StickerLibrary {
        StickerLibrary(
            readAccountData: { type in server.data.withLock { $0[type] } },
            writeAccountData: { type, content in server.data.withLock { $0[type] = content } },
            send: { _ in ProxiedResponse(status: 404) },
            upload: { mimeType, data in
                if failing { throw StickerFailure.add }
                #expect(mimeType == "image/png" && !data.isEmpty)
                let number = server.uploads.withLock { count in
                    count += 1
                    return count
                }
                return "mxc://x/builtin\(number)"
            })
    }

    @Test("uploaded once per account, then read back on any device without uploading again")
    func uploadedOnce() async throws {
        let server = Server()
        let first = library(server)
        await first.load(roomID: nil)

        let pack = try #require(first.packs.last)
        #expect(pack.isBuiltIn)
        #expect(pack.stickers.map(\.shortcode) == StickerArt.allCases.map(\.rawValue))
        #expect(pack.stickers.first?.body == "😊")
        #expect(pack.stickers.allSatisfy { $0.url.hasPrefix("mxc://") && $0.mimeType == "image/png" })
        #expect(server.uploads.withLock { $0 } == StickerArt.allCases.count)

        // The sheet opened again, and on another device: nothing more goes up.
        await first.load(roomID: nil)
        let second = library(server)
        await second.load(roomID: nil)
        #expect(server.uploads.withLock { $0 } == StickerArt.allCases.count)
        #expect(second.packs.last?.stickers.map(\.url) == pack.stickers.map(\.url))
    }

    @Test("a set drawn by an older version is uploaded again")
    func versioned() async {
        let server = Server()
        server.data.withLock {
            $0[StickerLibrary.builtInType] = #"{"version": 0, "images": {"happy": {"url": "mxc://x/old"}}}"#
        }

        let library = library(server)
        await library.load(roomID: nil)
        #expect(library.packs.last?.stickers.contains { $0.url == "mxc://x/old" } == false)
        #expect(server.uploads.withLock { $0 } == StickerArt.allCases.count)
    }

    @Test("with no network the first time there is no pack, and nothing is written")
    func offline() async {
        let server = Server()
        let library = library(server, failing: true)
        await library.load(roomID: nil)
        #expect(library.packs.isEmpty)
        #expect(server.data.withLock { $0[StickerLibrary.builtInType] } == nil)
    }

    @Test("every drawing is a square with nothing round it")
    func drawings() throws {
        // Set `ISKRA_RENDER_DIR` to look at them.
        let output = ProcessInfo.processInfo.environment["ISKRA_RENDER_DIR"].map { URL(filePath: $0) }
        for art in StickerArt.allCases {
            let data = art.png()
            try output.map { try data.write(to: $0.appending(component: "sticker-\(art.rawValue).png")) }
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == StickerArt.side && image.height == StickerArt.side, "\(art)")

            // The corner is outside every shape, and must be see-through.
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let alpha = try #require(context.data).assumingMemoryBound(to: UInt8.self)[3]
            #expect(alpha == 0, "\(art)")
        }
    }
}
