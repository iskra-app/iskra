import Foundation

/// Hardware identifiers, turned into the names people call their devices by.
///
/// `iPhone17,1` is what the hardware says about itself. "iPhone 16 Pro" is what its owner would say,
/// and this list is the only bridge between the two: there is no API that performs this lookup, on
/// any Apple platform, which is why every app that shows a device name carries a table like this one.
///
/// **The iPhone and iPad half is not from memory — it is Apple's.** Every simulator device type on
/// disk carries a `profile.plist` with a `modelIdentifier` in it, so the pairs below were read out of
/// `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/*.simdevicetype`, where the name of the
/// bundle is the marketing name and the plist inside it is the identifier. A guessed table would be
/// worse than no table: a *wrong* name in somebody's list of signed-in devices is not a cosmetic
/// mistake, it is the app misidentifying a device the user is being asked to recognise or to sign out.
///
/// To refresh it after a new device ships, run that same read:
///
/// ```sh
/// for p in /Library/Developer/CoreSimulator/Profiles/DeviceTypes/*.simdevicetype; do
///   /usr/libexec/PlistBuddy -c "Print :modelIdentifier" "$p/Contents/Resources/profile.plist"
///   basename "$p" .simdevicetype
/// done
/// ```
///
/// The Mac half has no such source — there are no Mac simulators — so it is hand-written, and it is
/// the half to distrust. Both halves are allowed to be incomplete, and `DeviceDescription` is built
/// so that being incomplete is safe: an unknown identifier is sent on as itself.
///
/// The names are deliberately plain ASCII. Apple writes "iPhone Xʀ" with a small-capital R and
/// "iPhone Xs" with a lowercase s; a `User-Agent` is an HTTP header, and a header is not the place to
/// find out what a server does with U+0280.
enum DeviceModels {
    /// The marketing name for a hardware identifier, or `nil` if this table has never heard of it —
    /// which is a normal thing to happen and not an error. It happens on the day a new phone ships,
    /// to the person holding the new phone.
    static func name(for identifier: String) -> String? {
        phones[identifier] ?? pads[identifier] ?? macs[identifier]
    }

    private static let phones = [
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone18,5": "iPhone 17e",
    ]

    private static let pads = [
        "iPad11,1": "iPad mini (5th generation)",
        "iPad11,3": "iPad Air (3rd generation)",
        "iPad11,7": "iPad (8th generation)",
        "iPad12,2": "iPad (9th generation)",
        "iPad13,2": "iPad Air (4th generation)",
        "iPad13,5": "iPad Pro 11-inch (3rd generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad13,18": "iPad (10th generation)",
        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,3": "iPad Pro 11-inch (4th generation)",
        "iPad14,4": "iPad Pro 11-inch (4th generation)",
        "iPad14,5": "iPad Pro 12.9-inch (6th generation)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3": "iPad Air 11-inch (M3)",
        "iPad15,5": "iPad Air 13-inch (M3)",
        "iPad15,7": "iPad (A16)",
        "iPad16,2": "iPad mini (A17 Pro)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        "iPad16,9": "iPad Air 11-inch (M4)",
        "iPad16,11": "iPad Air 13-inch (M4)",
        "iPad17,2": "iPad Pro 11-inch (M5)",
        "iPad17,4": "iPad Pro 13-inch (M5)",
    ]

    /// The half with no authority behind it — there is no Mac simulator to read the truth out of, so
    /// these are written by hand. `Mac16,1` is the one entry checked against real hardware
    /// (`system_profiler SPHardwareDataType`); the rest are as good as the person who typed them.
    ///
    /// Kept to the Apple silicon Macs on purpose. macOS 26 does not run on anything else, so an Intel
    /// entry here could only ever be wrong about a machine that cannot run this app.
    private static let macs = [
        "Mac13,1": "Mac Studio (M1 Max)",
        "Mac13,2": "Mac Studio (M1 Ultra)",
        "Mac14,2": "MacBook Air (M2)",
        "Mac14,3": "Mac mini (M2)",
        "Mac14,5": "MacBook Pro 14-inch (M2 Max)",
        "Mac14,6": "MacBook Pro 16-inch (M2 Max)",
        "Mac14,7": "MacBook Pro 13-inch (M2)",
        "Mac14,8": "Mac Pro (M2 Ultra)",
        "Mac14,9": "MacBook Pro 14-inch (M2 Pro)",
        "Mac14,10": "MacBook Pro 16-inch (M2 Pro)",
        "Mac14,12": "Mac mini (M2 Pro)",
        "Mac14,13": "Mac Studio (M2 Max)",
        "Mac14,14": "Mac Studio (M2 Ultra)",
        "Mac14,15": "MacBook Air 15-inch (M2)",
        "Mac15,3": "MacBook Pro 14-inch (M3)",
        "Mac15,6": "MacBook Pro 14-inch (M3 Pro)",
        "Mac15,7": "MacBook Pro 16-inch (M3 Pro)",
        "Mac15,8": "MacBook Pro 14-inch (M3 Max)",
        "Mac15,9": "MacBook Pro 16-inch (M3 Max)",
        "Mac15,10": "MacBook Pro 14-inch (M3 Max)",
        "Mac15,11": "MacBook Pro 16-inch (M3 Max)",
        "Mac15,12": "MacBook Air 13-inch (M3)",
        "Mac15,13": "MacBook Air 15-inch (M3)",
        "Mac15,14": "Mac Studio (M3 Ultra)",
        "Mac16,1": "MacBook Pro 14-inch (M4)",
        "Mac16,2": "iMac 24-inch (M4)",
        "Mac16,3": "iMac 24-inch (M4)",
        "Mac16,5": "MacBook Pro 16-inch (M4 Max)",
        "Mac16,6": "MacBook Pro 14-inch (M4 Pro)",
        "Mac16,7": "MacBook Pro 16-inch (M4 Pro)",
        "Mac16,8": "MacBook Pro 14-inch (M4 Max)",
        "Mac16,10": "Mac mini (M4)",
        "Mac16,11": "Mac mini (M4 Pro)",
        "Mac16,12": "MacBook Air 13-inch (M4)",
        "Mac16,13": "MacBook Air 15-inch (M4)",
        "Mac16,15": "Mac Studio (M4 Max)",
        "MacBookAir10,1": "MacBook Air (M1)",
        "MacBookPro17,1": "MacBook Pro 13-inch (M1)",
        "MacBookPro18,1": "MacBook Pro 16-inch (M1 Pro)",
        "MacBookPro18,2": "MacBook Pro 16-inch (M1 Max)",
        "MacBookPro18,3": "MacBook Pro 14-inch (M1 Pro)",
        "MacBookPro18,4": "MacBook Pro 14-inch (M1 Max)",
        "Macmini9,1": "Mac mini (M1)",
        "iMac21,1": "iMac 24-inch (M1)",
        "iMac21,2": "iMac 24-inch (M1)",
    ]
}
