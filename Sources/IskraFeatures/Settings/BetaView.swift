import IskraCore
import IskraDesign
import SwiftUI

/// The unfinished things, and the switches that turn them on.
///
/// One screen rather than a switch tucked into whichever settings page a feature happens to touch,
/// because what these switches have in common is not their subject — it is their *status*. A
/// person who finds "Native sidebar" under Appearance has no way of knowing it is an experiment;
/// a person who finds it here cannot miss it, and the sentence at the top says the rest.
///
/// There is no row for it on the settings root. It is reached by tapping the spark on the About
/// screen three times — see `AboutView` — because the people these switches are for are the
/// people who will go looking, and everybody else is better off never seeing them. The sidebar
/// switch is the one thing here that is Mac-only; the rest of the screen is the same everywhere.
struct BetaView: View {
    @AppStorage(BetaFeatures.nativeSidebarKey) private var nativeSidebar = BetaFeatures.nativeSidebarByDefault
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore) private var blobatar = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore) private var forceBlobatar = BetaFeatures.forceBlobatarByDefault
    @AppStorage(BetaFeatures.mockBackendKey) private var mockBackend = false

    var body: some View {
        Form {
            Section {
                Text(Strings.Beta.intro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Who gets a drawn face — the slider the first run asks with. It lived under
            // Appearance; the faces are still an experiment, and the switches below it that
            // decide whether they are drawn at all were already here.
            Section {
                FaceModePicker()
                    .padding(.vertical, Theme.Spacing.close)
            } header: {
                Text(Strings.Appearance.avatars)
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

            Section {
                Toggle(isOn: $blobatar.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Beta.blobatar, systemImage: "face.smiling")
                }
                .accentControl()
            } footer: {
                Text(Strings.Beta.blobatarHelp)
            }

            // Appears with the switch it depends on rather than sitting there greyed out: a
            // disabled row is the app showing somebody a thing they cannot have and not saying
            // why, and the answer — "turn the one above on" — is the row directly above it.
            if blobatar {
                Section {
                    Toggle(isOn: $forceBlobatar.animation(.smooth(duration: Theme.Timing.reaction))) {
                        Label(Strings.Beta.blobatarForce, systemImage: "person.crop.circle.badge.xmark")
                    }
                    .accentControl()
                } footer: {
                    Text(Strings.Beta.blobatarForceHelp)
                }
            }

            // Flipping it takes the whole app with it — `IskraRootView` watches the same key and
            // swaps the session underneath this screen, so the switch is the last thing touched
            // in the account it was touched in. No confirmation: nothing is lost either way.
            Section {
                Toggle(isOn: $mockBackend) {
                    Label(Strings.Beta.mockBackend, systemImage: "theatermasks")
                }
                .accentControl()
            } footer: {
                Text(Strings.Beta.mockBackendHelp)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Beta.title))
    }
}
