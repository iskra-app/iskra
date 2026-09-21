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
/// It is reached only where there is something on it — see `BetaFeatures.hasAnything`, which
/// `SettingsView` asks before drawing the row. The sidebar switch is the one thing here that is
/// Mac-only; the rest of the screen is the same everywhere.
struct BetaView: View {
    @AppStorage(BetaFeatures.nativeSidebarKey) private var nativeSidebar = BetaFeatures.nativeSidebarByDefault
    @AppStorage(BetaFeatures.blobatarKey, store: BetaFeatures.faceStore) private var blobatar = BetaFeatures.blobatarByDefault
    @AppStorage(BetaFeatures.forceBlobatarKey, store: BetaFeatures.faceStore) private var forceBlobatar = BetaFeatures.forceBlobatarByDefault

    /// In the app's own defaults, not the App Group's: the notification extension has no use for
    /// it. Only the app places calls.
    @AppStorage(BetaFeatures.elementCallURLKey) private var elementCallURL = ""

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

            // A field rather than a switch, because the thing being chosen is not on-or-off: it
            // is an address, and there is no sensible one to offer. See `ElementCallDiscovery` on
            // why the app ships no default — and why the sentence under this field says what it
            // says instead of being a cheerful explanation of a feature.
            Section {
                TextField(text: $elementCallURL, prompt: Text(Strings.Beta.elementCallPrompt)) {
                    Label(Strings.Beta.elementCallTitle, systemImage: "phone.badge.waveform")
                }
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
            } footer: {
                Text(Strings.Beta.elementCallNote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Beta.title))
    }
}
