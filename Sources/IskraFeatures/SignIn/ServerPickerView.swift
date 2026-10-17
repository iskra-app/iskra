import SwiftUI
import IskraCore
import IskraDesign

/// A public server somebody with no address of their own can be sent to.
///
/// **Short on purpose, and every entry checked against this app, not against a directory.** The
/// list was drawn from servers.joinmatrix.org — servers that are open, staffed and kept up to date —
/// and then cut to the ones on which "Create account" in Iskra actually works: their sign-in is
/// OAuth that advertises `prompt=create` (`registrationURL` has no other way to make an account),
/// and they speak sliding sync. Most public servers still register through a form of their own in
/// Element, and offering one of those here would send somebody to a server that answers "you
/// cannot make an account from this app" — the one thing a list like this exists to prevent.
///
/// Probe a server before adding it: `GET /_matrix/client/v1/auth_metadata` must list `create` in
/// `prompt_values_supported`.
struct PublicServer: Identifiable {
    /// What goes into the address field.
    let address: String
    let about: LocalizedStringResource
    /// Where it is.
    let whereabouts: LocalizedStringResource
    /// What somebody should know before choosing it — said in a colour of its own, not folded
    /// into the description where it reads as one more detail.
    var warning: LocalizedStringResource?

    var id: String { address }

    static var all: [PublicServer] { [
        PublicServer(address: "matrix.org",
                     about: Strings.Servers.matrixOrg,
                     whereabouts: Strings.Servers.matrixOrgWhere,
                     // Blocked in Russia, and reachable through the bridge — which the sign-in
                     // screen offers to switch on the moment the lookup fails. Said only on a
                     // phone that has something Russian about it — to everybody else it is noise.
                     warning: isRussianLocale ? Strings.Servers.matrixOrgBlocked : nil),
        PublicServer(address: "tchncs.de",
                     about: Strings.Servers.tchncs,
                     whereabouts: Strings.Servers.tchncsWhere),
        PublicServer(address: "quassel.io",
                     about: Strings.Servers.quassel,
                     whereabouts: Strings.Servers.quasselWhere),
        PublicServer(address: "nope.chat",
                     about: Strings.Servers.nopeChat,
                     whereabouts: Strings.Servers.nopeChatWhere),
    ] }

    /// Russian among the phone's languages, or Russia as its region.
    static var isRussianLocale: Bool {
        Locale.current.region == .russia
            || Locale.preferredLanguages.contains { Locale(identifier: $0).language.languageCode == .russian }
    }

    /// Where somebody who would rather run their own is sent to read about it.
    static let ownServerGuide = URL(string: "https://matrix.org/ecosystem/servers/")!
}

/// "Not sure which server to choose?" — a handful of public servers, and, last, the one you run
/// yourself. Picking one fills in the address and comes back; "Next" is still the user's to press.
struct ServerPickerView: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// When the list last moved. The cards are tall and the whole of each is a button, and with
    /// touches delivered at once (`ScrollTouches`) the tap that stops a flick — or a thumb that
    /// lands on a card as the list settles — picked a server nobody meant to pick. A tap within
    /// `settle` of the list moving is taken as part of the scroll.
    @State private var lastMoved: Date = .distantPast
    @State private var isMoving = false
    private static let settle: TimeInterval = 0.35

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                    Text(Strings.Servers.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.Spacing.close)

                    ForEach(PublicServer.all) { server in
                        card(title: Text(verbatim: server.address),
                             whereabouts: Text(server.whereabouts),
                             about: Text(server.about),
                             warning: server.warning.map { Text($0) },
                             symbol: "chevron.forward") {
                            onPick(server.address)
                            dismiss()
                        }
                    }

                    card(title: Text(Strings.Servers.ownTitle),
                         whereabouts: nil,
                         about: Text(Strings.Servers.ownAbout),
                         warning: nil,
                         symbol: "arrow.up.forward") {
                        openURL(PublicServer.ownServerGuide)
                    }
                }
                .padding(Theme.Spacing.generous)
                .frame(maxWidth: Theme.Size.signInColumn)
                .frame(maxWidth: .infinity)
            }
            .onScrollPhaseChange { old, phase in
                // `.tracking` is a finger that has come down and not moved — which is also what
                // every deliberate tap looks like, so it is not movement.
                isMoving = phase.isScrolling
                if old.isScrolling || phase.isScrolling { lastMoved = .now }
            }
            .navigationTitle(Text(Strings.Servers.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .leaving) { dismiss() } label: {
                        Label(String(app: Strings.Recovery.close), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: Theme.Size.signInColumn, minHeight: Theme.Size.signInColumn * 1.25)
        #endif
    }

    private func card(title: Text,
                      whereabouts: Text?,
                      about: Text,
                      warning: Text?,
                      symbol: String,
                      action: @escaping () -> Void) -> some View {
        Button {
            guard !isMoving, Date.now.timeIntervalSince(lastMoved) > Self.settle else { return }
            action()
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.normal) {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    title
                        .font(.headline)
                    if let whereabouts {
                        whereabouts
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    about
                        .font(.subheadline)
                        .padding(.top, Theme.Spacing.tight)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning {
                        Label { warning } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.top, Theme.Spacing.tight)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.roomy)
            .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(.rect(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
