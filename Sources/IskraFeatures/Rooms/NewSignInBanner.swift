import SwiftUI
import IskraCore
import IskraDesign

/// "New sign-in to your account — was this you?" across the top of the chat list, the way Telegram
/// asks it. See `NewSignInsStore` for how a session counts as new.
///
/// Two answers and both are one press. "Yes" writes the session down and the banner goes. "It
/// wasn't me" opens the session's card with its red button (`DeviceDetailSheet`) rather than ending
/// it on the spot: ending may need the account's password or the server's page, and somebody who has
/// just seen a stranger in their account should see what they are about to end before they end it.
struct NewSignInBanner: View {
    let device: AccountDevice
    /// How many more new sessions are behind this one.
    let more: Int
    var onConfirm: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            HStack(alignment: .top, spacing: Theme.Spacing.normal) {
                Image(systemName: device.platform.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
                    .background(device.platform.tint,
                                in: RoundedRectangle(cornerRadius: Theme.Spacing.close, style: .continuous))

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(Strings.Devices.newSignInTitle)
                        .font(.callout.weight(.semibold))
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if more > 0 {
                        Text(Strings.Devices.newSignInMore(more))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Theme.Spacing.normal) {
                Button(action: onConfirm) {
                    Text(Strings.Devices.newSignInYes)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: onDeny) {
                    Text(Strings.Devices.newSignInNo)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .destructiveTint()
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, Theme.Spacing.roomy)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(maxWidth: .infinity)
        .background(.red.opacity(Theme.Backdrop.wash))
        .accessibilityElement(children: .contain)
    }

    /// The device, what it runs, and where it was — everything the row on the Devices screen says,
    /// on as few lines as will hold it.
    private var summary: String {
        [device.title, device.detail, device.lastSeenIP].compactMap { $0 }.joined(separator: " · ")
    }
}

extension View {
    /// The banner above the chat list, and the session's card when "It wasn't me" is pressed. Reads
    /// the list on appearing and on every return to the foreground — a sign-in is something that
    /// happens while the phone is in a pocket.
    func newSignIns(for session: UserSession) -> some View {
        modifier(NewSignIns(session: session))
    }
}

private struct NewSignIns: ViewModifier {
    let session: UserSession

    @State private var store: NewSignInsStore?
    /// The session "It wasn't me" opened, with the store that can end it.
    @State private var denying: Denial?
    @Environment(\.scenePhase) private var scenePhase

    struct Denial: Identifiable {
        let device: AccountDevice
        let devices: DevicesStore
        var id: String { device.id }
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let store, let first = store.sessions.first {
                    NewSignInBanner(device: first,
                                    more: store.sessions.count - 1,
                                    onConfirm: {
                                        withAnimation(.smooth(duration: Theme.Timing.chrome)) { store.confirm(first.id) }
                                    },
                                    onDeny: {
                                        denying = Denial(device: first, devices: store.devicesStore())
                                    })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: Theme.Timing.chrome), value: store?.sessions.map(\.id))
            .sheet(item: $denying) { denial in
                DeviceDetailSheet(device: denial.device, store: denial.devices) {
                    store?.ended(denial.device.id)
                }
            }
            .task {
                // Not for the demo and not for the sign-in server: neither is the device's account,
                // and neither has a session list worth asking about.
                guard store == nil, !session.isDemo, !MockSignIn.isRequested,
                      let source = session.accountDevices() else { return }
                let made = NewSignInsStore(source: source, account: session.sessionID)
                store = made
                await made.check()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, let store else { return }
                Task { await store.check() }
            }
    }
}
