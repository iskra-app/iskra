#if os(macOS)
import AppKit

/// Quitting the app and opening it again — after a change of language, which the menus and the
/// system's windows take only at launch.
///
/// The new copy is started first and this one quits after it. The new one waits for this one to go
/// before anything else: otherwise it would find this copy still running and hand itself over to
/// it, as a second copy of the app is meant to.
///
/// Whose place it takes is left in the app's defaults, not passed as an argument: from a sandboxed
/// app LaunchServices starts the new copy without the arguments it was given, and the new copy,
/// told nothing, handed itself over to the old one and both were gone.
public enum Relaunch {
    private static let predecessorKey = "relaunch.predecessor"
    private static let requestedAtKey = "relaunch.requestedAt"

    /// How long the new copy waits for the old one before carrying on without it — and how old a
    /// note may be and still be about this launch.
    private static let patience: TimeInterval = 10

    /// Starts a new copy of the app, and quits this one once it is on its way.
    @MainActor public static func now() {
        let defaults = UserDefaults.standard
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: predecessorKey)
        defaults.set(Date().timeIntervalSince1970, forKey: requestedAtKey)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        let attempt = Attempt()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let failed = error != nil
            Task { @MainActor in
                if failed {
                    attempt.failed = true
                    forget()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        // And without waiting for the answer for ever: the new copy holds off its launch until this
        // one has gone, and if the answer waits for that launch the two would wait on each other.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !attempt.failed { NSApp.terminate(nil) }
        }
    }

    /// Whether the new copy could not be started, in which case this one stays.
    @MainActor private final class Attempt {
        var failed = false
    }

    /// In the new copy, before anything else: waits for the copy it replaces to have quit.
    public static func waitForPredecessor() {
        let defaults = UserDefaults.standard
        let pid = pid_t(defaults.integer(forKey: predecessorKey))
        let requestedAt = defaults.double(forKey: requestedAtKey)
        forget()
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier,
              Date().timeIntervalSince1970 - requestedAt < patience else { return }

        // Through the same list the check for a second copy reads, so the two cannot disagree about
        // whether the old copy is still there.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { $0.processIdentifier == pid && !$0.isTerminated }
            guard isRunning else { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func forget() {
        UserDefaults.standard.removeObject(forKey: predecessorKey)
        UserDefaults.standard.removeObject(forKey: requestedAtKey)
    }
}
#endif
