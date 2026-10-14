import Foundation
import Testing
import CoreGraphics
@testable import IskraCore

/// The settings that change what a conversation shows and where a share goes: the two service-line
/// switches, the share sheet's account, and the blur a picture waits under when it is not fetched.
@Suite("Chat settings")
struct ChatSettingsTests {
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "iskra.tests.chatSettings.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Service lines

    @Test("each switch hides its own kind of line and nothing else")
    func serviceSwitchesAreSeparate() {
        let names = ServiceEventSettings(hidesNameChanges: true)
        #expect(names.hides(.renamedThemselves(from: "Kot", to: "Аня")))
        #expect(!names.hides(.joined(["@a:x"])))

        let members = ServiceEventSettings(hidesMembershipChanges: true)
        for kind: RoomEventKind in [.joined(["@a:x"]), .left(["@a:x"]), .invited(["@a:x"]),
                                    .removed(["@a:x"]), .banned(["@a:x"])] {
            #expect(members.hides(kind))
        }
        #expect(!members.hides(.renamedThemselves(from: "Kot", to: "Аня")))
    }

    @Test("what happens to the room itself is never hidden")
    func roomChangesStay() {
        let everything = ServiceEventSettings(hidesNameChanges: true, hidesMembershipChanges: true)
        for kind: RoomEventKind in [.roomRenamed("Кухня"), .roomTopicChanged, .roomPictureChanged,
                                    .roomCreated, .encryptionEnabled] {
            #expect(!everything.hides(kind))
        }
    }

    @Test("both switches start off")
    func serviceDefaults() throws {
        #expect(ServiceEventSettings.current(try freshDefaults("serviceDefaults")) == ServiceEventSettings())
    }

    // MARK: - The share sheet's account

    private func twoAccounts(_ defaults: UserDefaults) {
        ChatDirectory.writeDirectory([ChatDirectoryEntry(id: "!home", name: "Дом", accountID: "A"),
                                      ChatDirectoryEntry(id: "!work", name: "Работа", accountID: "B")],
                                     to: defaults)
    }

    @Test("by default the share sheet offers the active account's chats")
    func shareDefaultsToActive() throws {
        let defaults = try freshDefaults("shareActive")
        twoAccounts(defaults)
        ChatDirectory.recordActiveAccount("B", in: defaults)
        #expect(ChatDirectory.shareDirectory(from: defaults).map(\.id) == ["!work"])
    }

    @Test("a chosen account wins over the active one, and all means all")
    func shareChosenAccount() throws {
        let defaults = try freshDefaults("shareChosen")
        twoAccounts(defaults)
        ChatDirectory.recordActiveAccount("B", in: defaults)

        ChatDirectory.setShareAccount(.account("A"), in: defaults)
        #expect(ChatDirectory.shareDirectory(from: defaults).map(\.id) == ["!home"])

        ChatDirectory.setShareAccount(.all, in: defaults)
        #expect(ChatDirectory.shareDirectory(from: defaults).count == 2)
    }

    @Test("a chosen account that has gone falls back to the active one, never to an empty sheet")
    func shareFallsBack() throws {
        let defaults = try freshDefaults("shareGone")
        twoAccounts(defaults)
        ChatDirectory.setShareAccount(.account("signed-out"), in: defaults)
        // Nobody recorded as active either: everything, rather than nothing.
        #expect(ChatDirectory.shareDirectory(from: defaults).count == 2)

        ChatDirectory.recordActiveAccount("A", in: defaults)
        #expect(ChatDirectory.shareDirectory(from: defaults).map(\.id) == ["!home"])
    }

    // MARK: - The blur

    @Test("a hash decodes back to roughly its colour")
    func blurhashRoundTrips() throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let hash = Blurhash.encode(try #require(context.makeImage()))

        let decoded = try #require(Blurhash.decode(hash, width: 8, height: 8))
        let bytes = try #require(decoded.dataProvider?.data as Data?)
        // The middle pixel, RGBX.
        let offset = 4 * (4 * 8 + 4)
        #expect(abs(Int(bytes[offset]) - 26) < 12)
        #expect(abs(Int(bytes[offset + 1]) - 128) < 12)
        #expect(abs(Int(bytes[offset + 2]) - 230) < 12)
    }

    @Test("a hash that is not one decodes to nothing")
    func blurhashRejectsGarbage() {
        #expect(Blurhash.decode("") == nil)
        #expect(Blurhash.decode("not a blurhash at all") == nil)
        #expect(Blurhash.decode("L6PZfSjE.AyE_3t7t7R**0o#Dg") == nil)
    }
}
