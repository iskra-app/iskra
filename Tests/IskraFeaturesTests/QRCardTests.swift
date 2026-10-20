import Testing
import SwiftUI
@testable import IskraFeatures
import IskraCore

/// What "Share" on the QR page sends — see `QRCodeSheet.card`.
@MainActor
@Suite("QR card")
struct QRCardTests {
    private let link = MatrixLink.user("@kai:matrix.org")

    private func card(_ holo: Holo = .resting) throws -> CGImage {
        let face = QRCardFace(name: "Kai", picture: nil, seed: "@kai:matrix.org", shape: .circle,
                              blobatarEnabled: true, forceBlobatar: false)
        return try #require(QRCodeSheet.card(name: "Kai", subtitle: "@kai:matrix.org", link: link,
                                             face: face, holo: holo))
    }

    @Test("the shared picture is a code a camera reads back as the same link")
    func readable() throws {
        #expect(QRCode.read(try card()).contains(link.url.absoluteString))
    }

    @Test("the rainbow at its brightest does not reach the code")
    func readableUnderWatermark() throws {
        let bright = Holo(phase: .pi / 2, strength: 1)
        #expect(QRCode.read(try card(bright)).contains(link.url.absoluteString))
    }

    @Test("the card is rounded: its corners are transparent, not a white rectangle")
    func roundedCorners() throws {
        let image = try card()
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The top-left pixel, drawn alone into a one-pixel context.
        context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        #expect(pixel[3] == 0)
    }
}
