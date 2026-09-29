import SwiftUI
import IskraDesign

/// What this app is, which build of it you are holding, and whose work it is standing on.
///
/// The screen is the whole answer to "which Iskra is this": the settings screen no longer
/// carries the version in its footer, so the number lives here and nowhere else. Every row is
/// selectable, which is what a bug report needs — the three facts it is useless without, in a
/// form that can be copied one at a time.
///
/// The licences sit one push further in (`LicensesView`) rather than on this screen: they are
/// a list somebody opens on purpose, not something to scroll past on the way to a version.
struct AboutView: View {
    @Environment(\.accent) private var accent

    var body: some View {
        Form {
            Section {
                header
            }
            .profileHeaderRow()

            Section {
                LabeledContent {
                    Text(verbatim: AppVersion.marketing)
                } label: {
                    Text(Strings.About.version)
                }
                .textSelection(.enabled)

                LabeledContent {
                    Text(verbatim: AppVersion.buildWithCommit)
                } label: {
                    Text(Strings.About.build)
                }
                .textSelection(.enabled)

                LabeledContent {
                    Text(verbatim: "\(AboutView.device) (\(AboutView.system))")
                } label: {
                    Text(Strings.About.device)
                }
                .textSelection(.enabled)
            }

            Section {
                Link(destination: URL(string: "https://iskra.swag.moscow")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(Strings.About.website)
                        Text(verbatim: "iskra.swag.moscow")
                    }
                }

                // A closure destination is fine here: `LicensesView` holds nothing but constants,
                // so building it eagerly costs nothing. And it must not read `dismiss` — this
                // screen is itself pushed onto the settings stack. See CLAUDE.md.
                NavigationLink {
                    LicensesView()
                } label: {
                    Text(Strings.About.licences)
                }
            }
        }
        .formStyle(.grouped)
        .tint(accent.color)
        .navigationTitle(Text(Strings.About.title))
    }

    /// The icon, the name and the one sentence that says what the thing is.
    ///
    /// Centred and without a card round it, the way the profile header is and for the same
    /// reason: it is the subject of the screen rather than the first row of a list.
    private var header: some View {
        VStack(spacing: Theme.Spacing.close) {
            AppIconView(size: Theme.Size.avatarProfile)

            Text(Strings.Settings.appName)
                .font(.title2.weight(.semibold))

            Text(Strings.About.tagline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.roomy)
        .accessibilityElement(children: .combine)
    }

    /// Which OS this is running on, named rather than numbered alone: "26.0" says nothing on
    /// its own in a bug report that might have come from either platform.
    private static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(macOS)
        return "macOS \(number)"
        #else
        return "\(UIDevice.current.systemName) \(number)"
        #endif
    }

    /// Which machine this is, as the machine itself calls it — `iPhone17,1`, `Mac15,3`.
    ///
    /// Not the marketing name. Turning an identifier into "iPhone 17 Pro" means a table of every
    /// model Apple has ever shipped, which is out of date the week a new one appears and would
    /// then confidently print the *wrong* name; the identifier is always right, and it is what a
    /// crash report says anyway. `sysctl` is the only way to it — `UIDevice.model` says no more
    /// than "iPhone", which is not a fact worth a row.
    ///
    /// In a simulator `hw.machine` describes the *Mac* underneath, so the simulator's own
    /// environment variable is asked first. Without it, every report sent from a simulator would
    /// arrive claiming to come from an arm64 Mac.
    private static var device: String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return model
        }
        #endif

        #if os(macOS)
        let key = "hw.model"
        let fallback = "Mac"
        #else
        let key = "hw.machine"
        let fallback = UIDevice.current.model
        #endif

        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return fallback }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return fallback }
        let name = String(cString: value)
        return name.isEmpty ? fallback : name
    }
}

/// Whose code ships inside the app, under which licence, and a way through to the text of it.
///
/// This is not decoration. Every line of Matrix and every line of Matrix cryptography here is
/// `matrix-rust-sdk`'s, under Apache-2.0, and the avatars are a port of blobatar, under MIT —
/// licences that travel with the binary and need somewhere in the shipped app a person can
/// actually reach. Each row is a link rather than a name, because a name with no way through
/// to the licence is a thank-you, not a notice.
struct LicensesView: View {
    @Environment(\.accent) private var accent

    /// One piece of somebody else's work, and where its licence is published.
    private struct Credit: Identifiable {
        let name: String
        let licence: String
        let url: URL
        var id: String { name }
    }

    /// Names and licence names are not translated — "Apache 2.0" and "MIT" are what the
    /// licences are called in every language, and the project names are proper nouns.
    private static let credits: [Credit] = [
        Credit(name: "matrix-rust-sdk",
               licence: "Apache 2.0",
               url: URL(string: "https://github.com/matrix-org/matrix-rust-sdk/blob/main/LICENSE")!),
        Credit(name: "matrix-rust-components-swift",
               licence: "Apache 2.0",
               url: URL(string: "https://github.com/matrix-org/matrix-rust-components-swift/blob/main/LICENSE")!),
        Credit(name: "swift-secp256k1",
               licence: "MIT",
               url: URL(string: "https://github.com/21-DOT-DEV/swift-secp256k1")!),
        Credit(name: "blobatar",
               licence: "MIT © 2026 Alain",
               url: URL(string: "https://blobatar.dev")!),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(LicensesView.credits) { credit in
                    Link(destination: credit.url) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: credit.name)
                            Text(verbatim: credit.licence)
                        }
                    }
                }
            } footer: {
                Text(Strings.About.cryptography)
            }
        }
        .formStyle(.grouped)
        .tint(accent.color)
        .navigationTitle(Text(Strings.About.licences))
    }
}
