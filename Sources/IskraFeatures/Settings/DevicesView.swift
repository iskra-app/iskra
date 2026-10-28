import SwiftUI
import IskraCore
import IskraDesign

/// Settings → Devices, the way Telegram has it: this device at the top, a red button that signs
/// every other one out, and below it every other session on the account — what it is, what it runs,
/// where it was last seen and when — each one a swipe away from being ended, and a tap away from a
/// card with everything the server knows about it (`DeviceDetailSheet`).
///
/// The list is the server's (`AccountDevices`), fetched through the same road the SDK uses, the
/// bridge included. Ending a session asks the server; where the server wants the account's password
/// first, the screen asks for it; where sessions are the server's own to end — an account signed in
/// through the browser — the button opens the server's page for that session instead, and the list
/// is read again when the page is closed.
///
/// Pushed onto the sidebar's stack, so it must not read `@Environment(\.dismiss)` — see the rule in
/// `CLAUDE.md`. It has no reason to: it never closes itself.
struct DevicesView: View {
    @State var store: DevicesStore

    @Environment(\.accent) private var accent

    /// The session opened up in a sheet — a tap on its row. See `DeviceDetailSheet`.
    @State private var inspecting: AccountDevice?
    @State private var isConfirmingOthers = false

    var body: some View {
        Form {
            if let current = store.current {
                Section {
                    Button {
                        inspecting = current
                    } label: {
                        DeviceRow(device: current, isEnding: false)
                    }
                    .buttonStyle(.plain)

                    if !store.others.isEmpty {
                        Button(role: .destructive) {
                            isConfirmingOthers = true
                        } label: {
                            Label(Strings.Devices.endOthers, systemImage: "hand.raised")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text(Strings.Devices.thisDevice)
                } footer: {
                    if !store.others.isEmpty {
                        Text(Strings.Devices.endOthersFooter)
                    }
                }
            }

            if store.hasLoaded {
                Section {
                    if store.others.isEmpty {
                        Text(Strings.Devices.noOthers)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.others) { device in
                        Button {
                            inspecting = device
                        } label: {
                            DeviceRow(device: device, isEnding: store.ending.contains(device.id))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await store.end([device.id]) }
                            } label: {
                                Text(Strings.Devices.end)
                            }
                        }
                        // The row goes the way Telegram's does: folded up and out, the ones below
                        // closing over the gap.
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .scale(scale: 0.6, anchor: .top).combined(with: .opacity)))
                    }
                } header: {
                    Text(Strings.Devices.others)
                }
            } else if store.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    Button {
                        Task { await store.load() }
                    } label: {
                        Text(Strings.Devices.retry)
                    }
                }
            }
        }
        .formStyle(.groupedRows)
        .tint(accent.color)
        .animation(.smooth(duration: Theme.Timing.chrome), value: store.devices.map(\.id))
        .navigationTitle(Text(Strings.Devices.title))
        .task { await store.load() }
        .refreshable { await store.load() }
        // All of them.
        .confirmationDialog(Text(Strings.Devices.endOthersConfirm),
                            isPresented: $isConfirmingOthers,
                            titleVisibility: .visible) {
            Button(role: .destructive) {
                Task { await store.endOthers() }
            } label: {
                Text(Strings.Devices.endOthers)
            }
            Button(role: .cancel) {} label: { Text(Strings.Devices.cancel) }
        }
        .endingSessions(store)
        .pageSheet(item: $inspecting) { device in
            DeviceDetailSheet(device: device, store: store)
        }
    }
}

/// One session: what it is, what it runs, and where and when it was last seen — Telegram's three
/// lines beside a coloured tile.
struct DeviceRow: View {
    let device: AccountDevice
    let isEnding: Bool

    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            Image(systemName: device.platform.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: Theme.Size.avatar, height: Theme.Size.avatar)
                .background(device.platform.tint,
                            in: RoundedRectangle(cornerRadius: Theme.Spacing.close, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: device.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if let detail = device.detail {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .lineLimit(1)
                }

                seen
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isEnding { ProgressView() }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// "в сети" for this device; for the others, where they were last and how long ago.
    @ViewBuilder
    private var seen: some View {
        if device.isCurrent {
            Text(Strings.Devices.online).foregroundStyle(accent.color)
        } else {
            let ip = device.lastSeenIP.map { Text(verbatim: $0) }
            let when = device.lastSeenAt.map { Text($0, format: .relative(presentation: .named)) }
            switch (ip, when) {
            // Both halves are already Text — an address and a localised date; only the dot
            // between them is written here, and it is punctuation, not a sentence.
            // swiftlint:disable:next literal_string_in_view
            case let (ip?, when?): Text("\(ip) · \(when)")
            case let (ip?, nil): ip
            case let (nil, when?): when
            case (nil, nil): Text(verbatim: device.id)
            }
        }
    }
}

extension DevicePlatform {
    var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case .android: "candybarphone"
        case .web: "globe"
        case .desktop: "desktopcomputer"
        case .unknown: "questionmark"
        }
    }

    /// Telegram tints each kind of device its own colour, so a list of them can be scanned by
    /// colour before it is read. The system's own colours, so they sit right in both appearances.
    var tint: Color {
        switch self {
        case .iPhone, .iPad: .blue
        case .mac: .indigo
        case .android: .green
        case .web: .orange
        case .desktop: .purple
        case .unknown: .gray
        }
    }
}
