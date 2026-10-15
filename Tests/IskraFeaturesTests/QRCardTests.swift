import Testing
import SwiftUI
@testable import IskraFeatures
import IskraCore

/// What "Share" on the QR page sends — see `QRCodeSheet.card`.
@MainActor
@Suite("QR card")
struct QRCardTests {
    @Test("the shared picture is a code a camera reads back as the same link")
    func readable() throws {
        let link = MatrixLink.user("@kai:matrix.org")
        let image = try #require(QRCodeSheet.card(name: "Kai", subtitle: "@kai:matrix.org", link: link))
        #expect(QRCode.read(image).contains(link.url.absoluteString))
    }
}
