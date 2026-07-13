import SwiftUI
import IskraCore
import IskraDesign

/// Settings, reached by tapping your own face in the top-right corner.
///
/// A destination pushed onto the room list's navigation stack — deliberately *not* a
/// sheet, and deliberately not a view swapped in behind a transition of our own. Being
/// a real destination is what makes the push, the back button and the swipe-back
/// gesture the system's rather than ours, and the difference is visible at a glance.
/// So there is no `NavigationStack` here: it is already inside one.
///
/// The back button is the one thing the system does not always supply. On iPhone it does,
/// and this screen must not draw a second one. Inside a sidebar it does not, and this
/// screen must — see `showsBackButton`.
///
/// Most of what is here is structure without a feature behind it yet. Those rows are
/// shown, and shown disabled, rather than hidden: the shape of the screen is a promise
/// about where things will go, and a row that is greyed out with a sentence explaining
/// why is honest in a way that an empty screen is not.
///
/// Signing out is the one thing on this screen that does anything, and it is the one
/// thing that cannot be undone, so it is last and it is red.
struct SettingsView: View {
    let session: UserSession
    var onSignOut: () -> Void

    /// Whether this screen has to draw its own way out.
    ///
    /// On iPhone it does not: settings is pushed onto the whole screen, and the system
    /// puts a back chevron in the corner and wires the swipe-back gesture to it. In a
    /// *sidebar* — Mac, and iPad wide enough to keep the split view open — it does: the
    /// column is only a few hundred points wide, the push happens inside it, and no back
    /// button appears, so without this the screen is a room with no door and sign-out is
    /// the only way out of it.
    let showsBackButton: Bool

    @Environment(\.dismiss) private var dismiss

    /// The one screen whose chrome is allowed the colour. A `Label` in a `Form` draws its
    /// icon in the tint, and the app's tint is monochrome everywhere else (see
    /// `IskraRootView`) — so the accent is put back here, on this screen only, where a row
    /// of coloured symbols is the point rather than noise.
    @Environment(\.accent) private var accent

    var body: some View {
        Form {
            Section {
                profile
            }

            Section {
                NavigationLink {
                    AppearanceView()
                } label: {
                    Label(Strings.Settings.appearance, systemImage: "paintbrush")
                }

                NavigationLink {
                    QuickReactionView()
                } label: {
                    Label(Strings.Settings.reactions, systemImage: "heart")
                }

                unbuilt(Strings.Settings.notifications, systemImage: "bell")
                unbuilt(Strings.Settings.privacy, systemImage: "lock")
            } footer: {
                Text(Strings.Settings.moreSoon)
            }

            Section {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    Text(Strings.Account.signOut)
                }
            }
        }
        .formStyle(.grouped)
        .tint(accent.color)
        .navigationTitle(Text(Strings.Settings.title))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if showsBackButton {
                ToolbarItem(placement: .navigation) {
                    Button {
                        dismiss()
                    } label: {
                        // A chevron, and the word — this is the system's own back button
                        // spelled out by hand, so it should look like one.
                        Label(Strings.Settings.back, systemImage: "chevron.backward")
                    }
                    .accessibilityLabel(Text(Strings.Settings.back))
                }
            }
        }
    }

    /// Who you are signed in as. The Matrix ID is shown in full and is selectable,
    /// because it is the thing people ask each other for.
    private var profile: some View {
        HStack(spacing: Theme.Spacing.roomy) {
            Avatar(name: session.displayName,
                   url: session.avatarURL,
                   size: Theme.Size.avatarLarge)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(session.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(session.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Theme.Spacing.close)
        .accessibilityElement(children: .combine)
    }

    /// A setting that exists as a place on the screen and nothing more.
    private func unbuilt(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }
}
