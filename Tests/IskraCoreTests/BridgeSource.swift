import Foundation

/// Where the bridge's own repository is, for the tests that read it or run it.
///
/// The bridge left this repository for `iskra-app/iskra-bridge`, and the two are meant to be
/// checked out side by side — `../iskra-bridge`. `ISKRA_BRIDGE_DIR` points anywhere else.
/// `nil` when neither is there: `swift test` must still run on a machine that has only the app.
enum BridgeSource {
    static let directory: URL? = {
        if let path = ProcessInfo.processInfo.environment["ISKRA_BRIDGE_DIR"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        let sibling = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "iskra-bridge", directoryHint: .isDirectory)
        let manifest = sibling.appending(path: "Cargo.toml").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: manifest) ? sibling : nil
    }()

    /// Why a test that needs it did not run.
    static let missing = "needs the bridge's repository: ../iskra-bridge, or ISKRA_BRIDGE_DIR"
}
