import Foundation

/// What the app calls itself, and which build of it this is.
///
/// Both numbers come out of the bundle rather than being written down anywhere in Swift, and
/// neither is a constant here, because a constant is a second place to forget to change.
///
/// Neither is set by anybody. A build phase (`Stamped`, in `Apps/project.yml`) stamps the version
/// with the date of the commit — `2026.10.19`, as the web client's — and the build number with the
/// count of commits, so both go up on their own and two builds of one day are still told apart. A
/// build made outside a git checkout keeps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
///
/// Under `swift test` there is no app bundle at all — the keys are simply absent — so the
/// numbers fall back to zeros instead of trapping. A settings screen is not worth a crash.
enum AppVersion {
    /// The one people quote: 2026.10.19.
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The one that tells two builds of the same version apart, and the only number that
    /// matters in a bug report.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The short hash of the commit the build was made from, stamped by the same build phase
    /// as the number. `nil` outside a git checkout and under `swift test`, where the row shows
    /// the number alone rather than a made-up hash.
    static var commit: String? {
        Bundle.main.object(forInfoDictionaryKey: "IskraCommit") as? String
    }

    /// The build as the About screen shows it: `142 (6ab17bd)`, or `142` with no hash to give.
    static var buildWithCommit: String {
        commit.map { "\(build) (\($0))" } ?? build
    }
}
