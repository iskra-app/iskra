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

    /// What the address was when this screen opened, so that leaving it without touching the field
    /// asks the server nothing.
    @State private var elementCallURLOnEntry = ""

    /// Told when the call address has actually been changed, so the session can look again.
    ///
    /// It exists because the availability of calls is worked out **once**, in `UserSession.start()`
    /// — two network questions whose only consequence is whether a button appears, and no reason
    /// to re-ask them while somebody reads a conversation. That is right for the server's answer
    /// and wrong for this field: without this, a person types an address here, goes back, finds no
    /// call button, and the only cure is restarting the app. The field would look broken, and the
    /// bug would be invisible — the address *was* saved.
    var onCallAddressChanged: (() -> Void)?

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
        .onAppear { elementCallURLOnEntry = elementCallURL }
        // On the way out rather than on every keystroke: half a typed address is a different
        // address, and asking the server about each one would be a network request per letter.
        // This screen pushes nothing, so `onDisappear` here means what it says — see the warning
        // about it in `RoomInfoView`, where it does not.
        .onDisappear {
            guard elementCallURL != elementCallURLOnEntry else { return }
            onCallAddressChanged?()
        }
    }
}
