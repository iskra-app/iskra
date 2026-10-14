import SwiftUI
import IskraCore
import IskraDesign

/// One session, opened from the Devices screen or from the new-sign-in banner: everything the server
/// knows about it, and the red button that ends it — Telegram's card for a session.
///
/// A sheet, so its own `dismiss` is fine (see `CLAUDE.md`: the rule is about screens pushed onto the
/// sidebar's stack). It closes itself the moment the session is gone from the store's list, which is
/// what "ended" means: not the button pressed, the server agreeing.
struct DeviceDetailSheet: View {
    let device: AccountDevice
    let store: DevicesStore
    /// Told when the session has ended — the banner uses it to stop asking about it.
    var onEnded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var isConfirming = false

    private var isEnding: Bool { store.ending.contains(device.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                Section {
                    if let detail = device.detail {
                        LabeledContent { Text(verbatim: detail) } label: { Text(Strings.Devices.application) }
                    }
                    LabeledContent {
                        if device.isCurrent {
                            Text(Strings.Devices.online).foregroundStyle(accent.color)
                        } else if let seen = device.lastSeenAt {
                            Text(seen, format: .dateTime.day().month().year().hour().minute())
                        } else {
                            Text(Strings.Devices.unknown)
                        }
                    } label: {
                        Text(Strings.Devices.lastSeen)
                    }
                    if let ip = device.lastSeenIP {
                        LabeledContent { Text(verbatim: ip).textSelection(.enabled) } label: { Text(Strings.Devices.ipAddress) }
                    }
                    LabeledContent {
                        Text(verbatim: device.id)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text(Strings.Devices.deviceID)
                    }
                }

                if !device.isCurrent {
                    Section {
                        Button(role: .destructive) {
                            isConfirming = true
                        } label: {
                            HStack(spacing: Theme.Spacing.close) {
                                Text(Strings.Devices.endSession)
                                if isEnding {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isEnding)
                    } footer: {
                        if store.isManagedByServer {
                            Text(Strings.Devices.managedFooter)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(Strings.Devices.done) }
                }
            }
            .confirmationDialog(Text(Strings.Devices.endConfirm), isPresented: $isConfirming,
                                titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { await store.end([device.id]) }
                } label: {
                    Text(Strings.Devices.end)
                }
                Button(role: .cancel) {} label: { Text(Strings.Devices.cancel) }
            } message: {
                Text(verbatim: device.title)
            }
            .endingSessions(store)
            // Gone from the list after an end that was asked from here: the server agreed.
            .onChange(of: store.devices.map(\.id)) { _, ids in
                guard store.hasLoaded, !ids.contains(device.id) else { return }
                onEnded()
                dismiss()
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    /// The tile, large, and the name under it — the same tile as the row, so the sheet is plainly
    /// the row opened up.
    private var header: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Image(systemName: device.platform.symbol)
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: Theme.Size.avatarLarge, height: Theme.Size.avatarLarge)
                .background(device.platform.tint,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))

            Text(verbatim: device.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// What ending a session can turn into on the way: the server asking for the password, the
    /// server's own page to open, a failure to say. One modifier, because the Devices screen, the
    /// session sheet and the new-sign-in banner all end sessions and all owe the same answers — and
    /// an alert hung on the screen *under* a sheet never appears.
    func endingSessions(_ store: DevicesStore) -> some View {
        modifier(EndingSessions(store: store))
    }
}

private struct EndingSessions: ViewModifier {
    @Bindable var store: DevicesStore
    @State private var password = ""

    func body(content: Content) -> some View {
        content
            .failureAlert($store.failure)
            // The server wants the password first — Matrix's User-Interactive Auth.
            .alert(Text(Strings.Devices.passwordTitle),
                   isPresented: Binding(get: { store.awaitingPassword != nil },
                                        set: { if !$0 { store.awaitingPassword = nil } })) {
                SecureField(String(app: Strings.Devices.passwordField), text: $password)
                    .textContentType(.password)
                Button(role: .cancel) {
                    password = ""
                } label: {
                    Text(Strings.Devices.cancel)
                }
                Button {
                    let ids = store.awaitingPassword ?? []
                    let typed = password
                    password = ""
                    Task { await store.end(ids, password: typed) }
                } label: {
                    Text(Strings.Devices.end)
                }
            } message: {
                Text(Strings.Devices.passwordMessage)
            }
            // The server's own page, for an account whose sessions are ended there. Read the list
            // again when it closes: whatever was done on the page is the server's news.
            .onChange(of: store.pageToOpen) { _, page in
                guard let page else { return }
                Task {
                    await WebAuthentication.approve(url: page)
                    store.pageToOpen = nil
                    await store.load()
                }
            }
    }
}
