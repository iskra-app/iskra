import CoreGraphics
import SwiftUI
import IskraDesign
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

/// The spark in the middle costs the code nothing a reader would notice.
@Suite("QR codes with the spark")
struct QRCodeSparkTests {
    @Test("the clear square is odd, so it lies on whole modules")
    func centreIsOdd() {
        for width in stride(from: 21, through: 177, by: 4) {
            #expect(QRCode.centreSize(forWidth: width) % 2 == 1)
        }
    }

    @Test("a code with the spark drawn in reads back as the same link")
    func readsWithSpark() throws {
        let link = MatrixLink.user("@boris:matrix.org").url.absoluteString
        let image = try #require(QRCode.image(for: link))

        let scale = 8
        let side = CGFloat(image.width * scale)
        let context = try #require(CGContext(data: nil, width: Int(side), height: Int(side),
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // As `QRCodeImage` draws it: the spark, black, in the middle.
        let sparkSide = side * QRCode.sparkFraction(forWidth: image.width)
        let rect = CGRect(x: (side - sparkSide) / 2, y: (side - sparkSide) / 2, width: sparkSide, height: sparkSide)
        context.addPath(SparkGlyph().path(in: rect).cgPath)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillPath(using: .evenOdd)
        let large = try #require(context.makeImage())

        #expect(QRCode.read(large) == [link])
    }
}
