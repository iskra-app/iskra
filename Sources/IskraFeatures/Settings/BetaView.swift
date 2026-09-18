import IskraDesign
import SwiftUI

/// The unfinished things, and the switches that turn them on.
///
/// One screen rather than a switch tucked into whichever settings page a feature happens to touch,
/// because what these switches have in common is not their subject — it is their *status*. A
/// person who finds "Native sidebar" under Appearance has no way of knowing it is an experiment;
/// a person who finds it here cannot miss it, and the sentence at the top says the rest.
///
/// It is reached only where there is something on it — see `BetaFeatures.hasAnything`, and
/// `SettingsView`, which is where the row is hidden on iOS.
struct BetaView: View {
    @AppStorage(BetaFeatures.nativeSidebarKey) private var nativeSidebar = BetaFeatures.nativeSidebarByDefault

    var body: some View {
        Form {
            Section {
                Text(Strings.Beta.intro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section {
                Toggle(isOn: $nativeSidebar.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Beta.nativeSidebar, systemImage: "sidebar.left")
                }
                // The root tint is `.primary` unless the user has asked for the accent on the
                // chrome, and a switch drawn in `.primary` is white on white. Every switch in the
                // app goes through this — see `AccentControl`.
                .accentControl()
            } footer: {
                Text(Strings.Beta.nativeSidebarHelp)
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Beta.title))
    }
}
