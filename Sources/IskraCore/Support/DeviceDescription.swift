import Foundation

/// What this device calls itself to the homeserver.
///
/// It exists because of a line the user saw on their own account page: **"Unknown device"**. That is
/// the server's honest answer to a client that never said what it was. A homeserver running the
/// authentication service names a session by parsing the `User-Agent` of the request that created
/// it — and we were not setting one, so the SDK sent its own, which describes a Rust library and not
/// a phone.
///
/// This is the *only* way to name a session obtained through OAuth. The password login has
/// `initialDeviceName` and has always used it; `urlForOauth` has no such parameter, and there is no
/// rename-this-device call anywhere in the FFI — the same wall the device *list* runs into. The
/// User-Agent is not a nicety here, it is the whole of the mechanism.
///
/// The shape is the conventional one for a native app — `Name/version (model; OS version)` — because
/// that is what the parsers on the other end are written against. What the server makes of it is the
/// server's business, and this cannot be verified from here: the name only appears once the session
/// has been created, on a page the server draws.
enum DeviceDescription {
    /// e.g. `Iskra/1.0 (iPhone17,1; iOS 26.0)`, or `Iskra/1.0 (Mac15,7; macOS 26.1)`.
    static var userAgent: String {
        "Iskra/\(appVersion) (\(hardware); \(system))"
    }

    /// The hardware, exactly as the hardware states it: `iPhone17,1`, `Mac15,7`, `iPad14,3`.
    ///
    /// The model *identifier*, not the marketing name — and that is a deliberate trade rather than a
    /// shortcut. Turning `iPhone17,1` into "iPhone 16" needs a lookup table, and a lookup table is a
    /// list of every phone Apple has released that is wrong the day they release another one: the new
    /// device, the one whose owner most wants to recognise it in a list, is precisely the one that
    /// falls through to "unknown". The identifier is ugly and it is never wrong.
    ///
    /// It also keeps the platform word in the string — `iPhone17,1` still begins with "iPhone" — which
    /// is what the parsers on the server side look for to tell a phone from a laptop.
    private static var hardware: String {
        // The simulator's `hw.machine` is the *host's* architecture — "arm64" — which would describe
        // the Mac this is being debugged on and not the iPhone on screen. It puts the truth here.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }

        // `hw.model` on a Mac is "Mac15,7"; `hw.machine` is "arm64", which says nothing.
        // On iOS it is the other way round.
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif

        return sysctl(key) ?? "unknown"
    }

    /// `iOS 26.0`, `macOS 26.1`. `ProcessInfo` rather than `UIDevice`, and not only to avoid dragging
    /// UIKit into `IskraCore` — where it is forbidden — but because there is no `UIDevice` on the Mac
    /// and this file must answer on both.
    private static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)"

        #if os(macOS)
        return "macOS \(number)"
        #elseif os(iOS)
        return "iOS \(number)"
        #else
        return "\(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    /// The version the user would quote in a bug report — `CFBundleShortVersionString`, not the build
    /// number. Absent when the code is running under `swift test`, which has no app bundle.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }

        // Trailing NUL: sysctl counts it, `String(cString:)` does not want it, and `String(validating:)`
        // is the one that refuses to guess about the bytes in between.
        return String(validatingCString: value)
    }
}
