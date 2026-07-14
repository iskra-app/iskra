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
/// What the server makes of it is the server's business, and it cannot be verified from here: the
/// name only appears once the session has been created, on a page the server draws.
enum DeviceDescription {
    /// What the homeserver is told this device is.
    ///
    /// Two shapes, and which one comes out depends on whether `DeviceModels` recognises the hardware:
    ///
    ///   - **Known** — `Iskra/1.0 (iPhone 16 Pro; iOS 26.0)`. The conventional shape for a native app,
    ///     which is what the parsers on the far side are written against.
    ///   - **Unknown** — `iPhone19,3`, and nothing else. No app version, no OS version, no parentheses.
    ///
    /// The bare identifier is not a degraded version of the first, it is a different answer to a
    /// different situation. A name we do not have is a name we must not invent, and dressing an
    /// unrecognised identifier up in the full format invites the server to parse it into something
    /// confidently wrong. On its own it can only be shown as what it is, and the owner of a phone too
    /// new for this table would rather read `iPhone19,3` than "Unknown device".
    static var userAgent: String {
        let model = hardware

        guard let name = DeviceModels.name(for: model) else { return model }

        return "Iskra/\(appVersion) (\(name); \(system))"
    }

    /// The hardware, exactly as the hardware states it: `iPhone17,1`, `Mac16,1`, `iPad14,3`.
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
