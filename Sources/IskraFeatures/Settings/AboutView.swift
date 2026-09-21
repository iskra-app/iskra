import SwiftUI
import IskraDesign

/// What this app is, which build of it you are holding, and whose work it is standing on.
///
/// The version was already at the foot of the settings screen and stays there — a number you
/// glance at should not cost a tap. This screen is the rest of the answer: the sentence that
/// says what Iskra is, the build details in a form you can paste into a bug report without
/// copying them out by hand, and the credit that the code this app leans on is owed.
///
/// That last section is not decoration. Every line of Matrix and every line of cryptography
/// here is `matrix-rust-sdk`'s, under Apache-2.0, and a licence that asks to be carried with
/// the binary needs somewhere in the shipped app that a person can actually reach. This is
/// that place, which is also why the section is a list of links rather than a paragraph: a
/// name with no way through to the source is a thank-you, not a notice.
struct AboutView: View {
    /// Set for a moment after the build details are copied, so the row can say it happened.
    /// A copy is silent otherwise, and a button that gives back nothing gets pressed twice.
    @State private var didCopy = false

    @Environment(\.accent) private var accent

    var body: some View {
        Form {
            Section {
                header
            }
            .profileHeaderRow()

            Section {
                LabeledContent {
                    Text(verbatim: "\(AppVersion.marketing) (\(AppVersion.build))")
                } label: {
                    Text(Strings.About.version)
                }
                .textSelection(.enabled)

                LabeledContent {
                    Text(verbatim: AboutView.device)
                } label: {
                    Text(Strings.About.device)
                }
                .textSelection(.enabled)

                LabeledContent {
                    Text(verbatim: AboutView.system)
                } label: {
                    Text(Strings.About.system)
                }
                .textSelection(.enabled)

                Button {
                    Clipboard.copy(AboutView.buildDetails)
                    withAnimation(.smooth(duration: Theme.Timing.reaction)) { didCopy = true }
                    // And back again, so the row is a button once more. A tick that stays put
                    // reads as a state the screen is now in rather than as something that just
                    // happened, and the second copy — after the first paste went astray — then
                    // looks like it did nothing at all.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.smooth(duration: Theme.Timing.reaction)) { didCopy = false }
                    }
                } label: {
                    Label(didCopy ? Strings.About.copied : Strings.About.copy,
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
            } footer: {
                Text(Strings.About.copyHelp)
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
            }

            Section {
                Link(destination: URL(string: "https://github.com/matrix-org/matrix-rust-sdk")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(Strings.About.sdk)
                        Text(Strings.About.sdkLicence)
                    }
                }

                Link(destination: URL(string: "https://matrix.org")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(Strings.About.protocolName)
                        Text(Strings.About.protocolExplained)
                    }
                }
            } header: {
                Text(Strings.About.builtOn)
            } footer: {
                Text(Strings.About.cryptography)
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

    /// The facts a bug report needs, on one line each, in the order they get asked for.
    private static var buildDetails: String {
        """
        Iskra \(AppVersion.marketing) (\(AppVersion.build))
        \(device)
        \(system)
        """
    }
}
