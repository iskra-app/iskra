import Foundation
import Synchronization
import MatrixRustSDK

/// Turns the Rust SDK's logging on, once.
///
/// Until now nothing called `initPlatform`, so the SDK said nothing at all — which is
/// most of why a sign-in that stalls on a device is so hard to see. There is no
/// debugger on a phone running a signed build; the log is the only witness.
///
/// The level stops at `.info` on purpose. `.debug` and `.trace` make the SDK log
/// request and response bodies, and in this app those bodies are people's messages.
/// Nothing here may log message content, so the level that would is not offered.
public enum SDKLogging {
    private static let started = Mutex(false)

    public static func start(level: LogLevel = .info) {
        let shouldStart = started.withLock { started -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        // Throws only if the platform was already initialised, which the flag above
        // already prevents; there is nothing useful to do about it either way.
        try? initPlatform(config: TracingConfiguration(logLevel: level,
                                                       traceLogPacks: [],
                                                       extraTargets: [],
                                                       writeToStdoutOrSystem: true,
                                                       writeToFiles: nil,
                                                       sentryConfig: nil),
                          useLightweightTokioRuntime: false)
    }
}
