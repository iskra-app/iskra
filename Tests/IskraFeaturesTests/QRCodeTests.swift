import CoreGraphics
import Testing
@testable import IskraCore
@testable import IskraFeatures

/// The code this app draws is one this app — and so any reader — can read back.
@Suite("QR codes")
struct QRCodeTests {
    @Test("a person's code reads back as the same link")
    func roundTrips() throws {
        let link = MatrixLink.user("@boris:matrix.org").url.absoluteString
        let image = try #require(QRCode.image(for: link))

        // One pixel per module is too small for a detector; drawn up as it is on screen.
        let scale = 8
        let context = try #require(CGContext(data: nil, width: image.width * scale, height: image.height * scale,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
        let large = try #require(context.makeImage())

        #expect(QRCode.read(large) == [link])
    }
}
