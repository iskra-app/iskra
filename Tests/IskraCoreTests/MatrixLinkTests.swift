import Foundation
import Testing
@testable import IskraCore

/// What a QR code holds, and everything one made by somebody else's app might.
@Suite("Matrix links")
struct MatrixLinkTests {
    @Test("a person's link is s.iskra.wtf, and reads back as the person")
    func personRoundTrips() {
        let link = MatrixLink.user("@boris:matrix.org")
        #expect(link.url.absoluteString == "https://s.iskra.wtf/@boris:matrix.org")
        #expect(MatrixLink(parsing: link.url.absoluteString) == link)
    }

    @Test("a room alias is escaped in the path, and its servers ride along")
    func roomRoundTrips() {
        let alias = MatrixLink.room("#iskra:matrix.org", via: [])
        #expect(alias.url.absoluteString == "https://s.iskra.wtf/%23iskra:matrix.org")
        #expect(MatrixLink(parsing: alias.url.absoluteString) == alias)

        let id = MatrixLink.room("!abc:matrix.org", via: ["matrix.org", "example.com"])
        #expect(id.url.absoluteString == "https://s.iskra.wtf/!abc:matrix.org?via=matrix.org&via=example.com")
        #expect(MatrixLink(parsing: id.url.absoluteString) == id)
    }

    @Test("the link into the app names the sigil the way matrix: does, and reads back")
    func deepLinkRoundTrips() {
        let links: [(MatrixLink, String)] = [
            (.user("@boris:matrix.org"), "wtf.iskra://u/boris:matrix.org"),
            (.room("#iskra:matrix.org", via: []), "wtf.iskra://r/iskra:matrix.org"),
            (.room("!abc:matrix.org", via: ["matrix.org", "example.com"]),
             "wtf.iskra://roomid/abc:matrix.org?via=matrix.org&via=example.com"),
        ]
        for (link, text) in links {
            #expect(link.deepLink.absoluteString == text)
            #expect(MatrixLink(parsing: text) == link)
        }
    }

    @Test("wtf.iskra:// with a host is a person or a room, percent-escapes and all")
    func appScheme() {
        #expect(MatrixLink(parsing: "wtf.iskra://u/anya:matrix.org") == .user("@anya:matrix.org"))
        #expect(MatrixLink(parsing: "wtf.iskra://u/anya%3Amatrix.org") == .user("@anya:matrix.org"))
        #expect(MatrixLink(parsing: "wtf.iskra://r/iskra:matrix.org?via=example.com")
                == .room("#iskra:matrix.org", via: ["example.com"]))
        #expect(MatrixLink(parsing: "wtf.iskra://roomid/abc:matrix.org?via=matrix.org&via=example.com")
                == .room("!abc:matrix.org", via: ["matrix.org", "example.com"]))
        #expect(MatrixLink(parsing: "wtf.iskra://roomid/abc:matrix.org?via=ex%2Eample.com")
                == .room("!abc:matrix.org", via: ["ex.ample.com"]))
    }

    @Test("the app's own host-less URLs are not links to anybody")
    func appSchemeStrangers() {
        #expect(MatrixLink(parsing: "wtf.iskra:/open?room=!abc:matrix.org") == nil)
        #expect(MatrixLink(parsing: "wtf.iskra:/oauth-callback?code=secret&state=x") == nil)
        #expect(MatrixLink(parsing: "wtf.iskra:/share") == nil)
        #expect(MatrixLink(parsing: "wtf.iskra://open?room=!abc:matrix.org") == nil)
        #expect(MatrixLink(parsing: "wtf.iskra://x/boris:matrix.org") == nil)
        #expect(MatrixLink(parsing: "wtf.iskra://u/") == nil)
    }

    @Test("s.iskra.wtf is read in the path and in the fragment, as matrix.to is")
    func linkPage() {
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/@anya:matrix.org") == .user("@anya:matrix.org"))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/%23room:server.org") == .room("#room:server.org", via: []))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/!id:server.org?via=x.org&via=y.org")
                == .room("!id:server.org", via: ["x.org", "y.org"]))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/!id:server.org/$event?via=x.org")
                == .room("!id:server.org", via: ["x.org"]))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/#room:server.org") == .room("#room:server.org", via: []))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/#/@anya:matrix.org") == .user("@anya:matrix.org"))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/#/%23room:server.org") == .room("#room:server.org", via: []))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/#/!id:server.org?via=x.org")
                == .room("!id:server.org", via: ["x.org"]))
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/") == nil)
        #expect(MatrixLink(parsing: "https://s.iskra.wtf/about") == nil)
    }

    @Test("every spelling another app might have used is read")
    func otherSpellings() {
        #expect(MatrixLink(parsing: "https://matrix.to/#/@boris:matrix.org") == .user("@boris:matrix.org"))
        #expect(MatrixLink(parsing: "https://matrix.to/#/%23iskra:matrix.org") == .room("#iskra:matrix.org", via: []))
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
