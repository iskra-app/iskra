import Foundation
import MatrixRustSDK

/// Namespace for things that describe the SDK build we are talking to.
public enum Iskra {
    /// The version of the underlying Rust SDK, read across the FFI boundary.
    ///
    /// This exists mostly as a smoke test: if this returns, the XCFramework is
    /// present, linked, and callable on whichever platform we are running on.
    public static var sdkVersion: String {
        sdkGitSha()
    }
}
