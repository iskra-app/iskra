import Foundation
import Testing
@testable import IskraCore

/// What a QR code holds, and everything one made by somebody else's app might.
@Suite("Matrix links")
struct MatrixLinkTests {
    @Test("a person's link is matrix.to, and reads back as the person")
    func personRoundTrips() {
        let link = MatrixLink.user("@boris:matrix.org")
        #expect(link.url.absoluteString == "https://matrix.to/#/@boris:matrix.org")
        #expect(MatrixLink(parsing: link.url.absoluteString) == link)
    }

    @Test("a room alias is escaped in the fragment, and its servers ride along")
    func roomRoundTrips() {
        let alias = MatrixLink.room("#iskra:matrix.org", via: [])
        #expect(alias.url.absoluteString == "https://matrix.to/#/%23iskra:matrix.org")
        #expect(MatrixLink(parsing: alias.url.absoluteString) == alias)

        let id = MatrixLink.room("!abc:matrix.org", via: ["matrix.org", "example.com"])
        #expect(id.url.absoluteString == "https://matrix.to/#/!abc:matrix.org?via=matrix.org&via=example.com")
        #expect(MatrixLink(parsing: id.url.absoluteString) == id)
    }

    @Test("every spelling another app might have used is read")
    func otherSpellings() {
        #expect(MatrixLink(parsing: "https://matrix.to/#/#iskra:matrix.org") == .room("#iskra:matrix.org", via: []))
        #expect(MatrixLink(parsing: "https://matrix.to/#/!abc:matrix.org/$event?via=matrix.org")
                == .room("!abc:matrix.org", via: ["matrix.org"]))
        #expect(MatrixLink(parsing: "matrix:u/boris:matrix.org") == .user("@boris:matrix.org"))
        #expect(MatrixLink(parsing: "matrix:u/boris:matrix.org?action=chat") == .user("@boris:matrix.org"))
        #expect(MatrixLink(parsing: "matrix:r/iskra:matrix.org") == .room("#iskra:matrix.org", via: []))
        #expect(MatrixLink(parsing: "matrix:roomid/abc:matrix.org?via=example.com")
                == .room("!abc:matrix.org", via: ["example.com"]))
        #expect(MatrixLink(parsing: " @boris:matrix.org\n") == .user("@boris:matrix.org"))
        #expect(MatrixLink(parsing: "#iskra:matrix.org") == .room("#iskra:matrix.org", via: []))
    }

    @Test("anything that is not a person or a room is not a link")
    func strangers() {
        #expect(MatrixLink(parsing: "https://example.com/#/@boris:matrix.org") == nil)
        #expect(MatrixLink(parsing: "WIFI:S:home;T:WPA;P:secret;;") == nil)
        #expect(MatrixLink(parsing: "https://matrix.to/") == nil)
        #expect(MatrixLink(parsing: "matrix:x/boris:matrix.org") == nil)
        #expect(MatrixLink(parsing: "boris") == nil)
        #expect(MatrixLink(parsing: "") == nil)
    }
}
