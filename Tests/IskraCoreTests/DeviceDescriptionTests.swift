import Testing
@testable import IskraCore

/// The User-Agent is the only thing that names a session signed in through a browser — there is no
/// `initialDeviceName` on the OAuth path and no rename call in the FFI — so if it comes out wrong, or
/// comes out ASCII-unsafe, the user's account page says "Unknown device" and nothing in the app says
/// why. It is worth pinning.
struct DeviceDescriptionTests {
    @Test("a device the table knows is named the way its owner would name it")
    func knownDevicesAreNamed() {
        #expect(DeviceModels.name(for: "iPhone17,1") == "iPhone 16 Pro")
        #expect(DeviceModels.name(for: "iPad16,2") == "iPad mini (A17 Pro)")
        #expect(DeviceModels.name(for: "Mac16,1") == "MacBook Pro 14-inch (M4)")
    }

    /// The case that decides whether this table is safe to keep: the day a new phone ships, its owner
    /// is the person most likely to be looking at this list — and the table cannot know about it yet.
    @Test("a device the table has never heard of is not given a name it does not have")
    func unknownDevicesAreNotInvented() {
        #expect(DeviceModels.name(for: "iPhone42,1") == nil)
        #expect(DeviceModels.name(for: "arm64") == nil)
    }

    /// A `User-Agent` is an HTTP header. Apple writes "iPhone Xʀ" with a small-capital R (U+0280) and
    /// "iPhone Xs" with a lowercase s, and their own names were the source of this table — so the one
    /// thing to check is that none of that came across with them.
    @Test("every name in the table is safe to put in an HTTP header")
    func namesAreASCII() {
        for identifier in ["iPhone11,8", "iPhone11,2", "iPhone17,1", "iPad17,4", "Mac16,15"] {
            let name = DeviceModels.name(for: identifier)
            #expect(name != nil, "\(identifier) should be in the table")
            #expect(name?.allSatisfy(\.isASCII) == true, "\(identifier) → \(name ?? "nil") is not ASCII")
        }
    }
}
