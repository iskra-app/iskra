import IskraCore
import IskraDesign
import SwiftUI

/// Where traffic is sent through a bridge instead of straight at the homeserver.
///
/// A change here takes effect when the screen is left: the session is closed and restored again,
/// through `TunnelSettings.changed` and the root view. Not on every keystroke — a session rebuilt
/// while a key is half pasted is a session rebuilt for nothing — and not *never*, which is what it
/// used to be: the client is built around its homeserver address and cannot be re-pointed live, so
/// the switch waited for the next launch, and somebody who turned the bridge on because the direct
/// route was blocked saw the app stop loading anything until they restarted it.
///
/// The status row shows what is happening **now**, not what was chosen; until the change is applied
/// the screen says it is waiting, and offers to apply it at once — which on the Mac, where settings
/// can stay open in the sidebar indefinitely, is the only way it would happen.
struct ConnectionView: View {
    let session: UserSession

    @AppStorage(TunnelSettings.enabledKey, store: TunnelSettings.store) private var throughBridge = false

    /// The bridges on the public list, as the app has it — refreshed when the screen opens.
    @State private var bridges: [PublicBridge] = PublicBridges.current()
    /// One's own bridges.
    @State private var own: [PublicBridge] = TunnelSettings.customBridges()
    @State private var choice: Choice? = Self.currentChoice()
    /// One's own bridge being added (`nil` bridge) or edited.
    @State private var editing: BridgeEditor.Target?

    @State private var status: TunnelStatus = .off
    @State private var myKey: String?
    @State private var copied = false
    @State private var checking = false
    @State private var outcome: BridgeCheck.Outcome?
    /// What the connection was built from when the screen opened. A difference on the way out is
    /// what asks for the session to be rebuilt.
    @State private var appeared: TunnelSettings.Snapshot?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $throughBridge.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Connection.bridge, systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
                .accentControl()
            } footer: {
                Text(Strings.Connection.bridgeFooter)
            }

            Section {
                ForEach(listed) { bridge in
                    row(bridge, choice: .publicBridge(bridge.id), detail: detail(of: bridge))
                }
            } header: {
                Text(Strings.Connection.publicSection)
            } footer: {
                Text(bridges.isEmpty ? Strings.Connection.publicEmpty : Strings.Connection.publicFooter)
            }

            Section {
                ForEach(own) { bridge in
                    row(bridge, choice: .custom(bridge.id), detail: TunnelSettings.shortAddress(bridge.npub))
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(bridge)
                            } label: {
                                Label(Strings.Connection.deleteBridge, systemImage: "trash")
                            }
                            Button {
                                editing = .init(bridge: bridge)
                            } label: {
                                Label(Strings.Connection.editBridge, systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button {
                                editing = .init(bridge: bridge)
                            } label: {
                                Label(Strings.Connection.editBridge, systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                remove(bridge)
                            } label: {
                                Label(Strings.Connection.deleteBridge, systemImage: "trash")
                            }
                        }
                }
                Button {
                    editing = .init(bridge: nil)
                } label: {
                    Label(Strings.Connection.addBridge, systemImage: "plus")
                }
            } header: {
                Text(Strings.Connection.ownSection)
            } footer: {
                Text(Strings.Connection.ownFooter)
            }

            if let myKey {
                Section {
                    Text(myKey)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button {
                        copy(myKey)
                    } label: {
                        Label(copied ? Strings.Connection.copied : Strings.Connection.copy,
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text(Strings.Connection.myKey)
                } footer: {
                    Text(Strings.Connection.myKeyFooter)
                }
            }

            Section {
                LabeledContent(String(localized: Strings.Connection.status)) {
                    Text(describe(status))
                        .foregroundStyle(.secondary)
                }

                if isPending {
                    Text(Strings.Connection.pending)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        apply()
                    } label: {
                        Label(Strings.Connection.applyNow, systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Button {
                    check()
                } label: {
                    if checking {
                        Label(Strings.Connection.checking, systemImage: "ellipsis")
                    } else {
                        Label(Strings.Connection.check, systemImage: "bolt.horizontal")
                    }
                }
                .disabled(checking || checkTarget == nil)

                if let outcome {
                    Text(describe(outcome))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Both of these are the point of the screen, not decoration around it. See
            // `Strings.Connection`.
            Section {
                Text(Strings.Connection.unfinishedBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Strings.Connection.unfinished)
            }

            Section {
                Text(Strings.Connection.seesBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Strings.Connection.sees)
            }
        }
        .navigationTitle(Text(Strings.Connection.title))
        .sheet(item: $editing) { target in
            BridgeEditor(target: target) { bridge in saved(bridge, isNew: target.bridge == nil) }
        }
        .task {
            status = await session.tunnelStatus()
            myKey = await session.tunnelPublicKey()
        }
        .task {
            // At most once a day, and only for somebody using the list: the download goes direct.
            guard TunnelSettings.source() == .publicList else { return }
            if await PublicBridges.refresh() {
                withAnimation(.smooth(duration: Theme.Timing.reaction)) { bridges = PublicBridges.current() }
            }
        }
        .onAppear {
            if appeared == nil { appeared = TunnelSettings.snapshot() }
        }
        .onDisappear {
            if isPending { apply() }
        }
    }

    /// Whether what is on screen differs from what the session was built with. Recomputed on every
    /// edit, because the fields are `@AppStorage` and every edit redraws.
    private var isPending: Bool {
        guard let appeared else { return false }
        _ = (throughBridge, choice, own)
        return TunnelSettings.snapshot() != appeared
    }

    private func apply() {
        appeared = TunnelSettings.snapshot()
        NotificationCenter.default.post(name: TunnelSettings.changed, object: nil)
    }

    private func describe(_ status: TunnelStatus) -> LocalizedStringResource {
        switch status {
        case .off: Strings.Connection.statusDirect
        case .connecting(let relays): Strings.Connection.statusConnecting(relays)
        case .bridgedBlind(let relays): Strings.Connection.statusBlind(relays)
        case .refused(let refusal): Strings.Bridge.refusal(refusal)
        case .failed: Strings.Connection.statusFailed
        }
    }

    private func describe(_ outcome: BridgeCheck.Outcome) -> LocalizedStringResource {
        switch outcome {
        case .reachable(let milliseconds): Strings.Connection.checkOK(milliseconds)
        case .refused(let refusal): Strings.Bridge.refusal(refusal)
        case .noRelay: Strings.Connection.checkNoRelay
        case .silent: Strings.Connection.checkSilent
        case .failed(let reason): Strings.Connection.checkFailed(reason)
        }
    }

    /// What "Check the bridge" checks: the bridge chosen on this screen, before it is applied.
    private var checkTarget: (key: Data, relays: [URL])? {
        guard let bridge = TunnelSettings.chosenBridge(), let key = bridge.bridgeKey else { return nil }
        _ = choice
        return (key, bridge.relayURLs)
    }

    private func check() {
        guard let target = checkTarget else { return }
        checking = true
        outcome = nil
        Task {
            let homeserver = await session.homeserverURL
            outcome = await BridgeCheck.run(bridgeKey: target.key, relays: target.relays, homeserver: homeserver)
            checking = false
        }
    }

    // MARK: - Which bridge

    enum Choice: Hashable {
        case publicBridge(String)
        case custom(String)
    }

    private static func currentChoice() -> Choice? {
        guard let bridge = TunnelSettings.chosenBridge() else { return nil }
        switch TunnelSettings.source() {
        case .publicList: return .publicBridge(bridge.id)
        case .custom: return .custom(bridge.id)
        }
    }

    /// The public list as shown: the bridges on it, and the one chosen earlier if it has since left
    /// the list — it stays chosen until the person picks another, and says it is no longer listed.
    private var listed: [PublicBridge] {
        guard TunnelSettings.source() == .publicList, let chosen = TunnelSettings.chosenBridge(),
              !bridges.contains(where: { $0.id == chosen.id }) else { return bridges }
        return bridges + [chosen]
    }

    /// One bridge, chosen with a tap; the one in use carries the mark.
    private func row(_ bridge: PublicBridge, choice: Choice, detail: String?) -> some View {
        Button {
            switch choice {
            case .publicBridge: TunnelSettings.choose(bridge, source: .publicList)
            case .custom: TunnelSettings.choose(bridge, source: .custom)
            }
            outcome = nil
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { self.choice = choice }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(bridge.name)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if self.choice == choice {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(self.choice == choice ? .isSelected : [])
    }

    private func remove(_ bridge: PublicBridge) {
        TunnelSettings.removeCustom(id: bridge.id)
        withAnimation(.smooth(duration: Theme.Timing.reaction)) {
            own = TunnelSettings.customBridges()
            choice = Self.currentChoice()
        }
    }

    /// Back from the editor: the list redrawn, and a bridge just added put in use — adding one is
    /// almost always the step before using it.
    private func saved(_ bridge: PublicBridge, isNew: Bool) {
        if isNew { TunnelSettings.choose(bridge, source: .custom) }
        withAnimation(.smooth(duration: Theme.Timing.reaction)) {
            own = TunnelSettings.customBridges()
            choice = Self.currentChoice()
        }
    }

    /// Who runs it and where it goes, in one line.
    private func detail(of bridge: PublicBridge) -> String? {
        var parts: [String] = []
        if !bridges.contains(where: { $0.id == bridge.id }) {
            parts.append(String(localized: Strings.Connection.notListed))
        }
        if let name = bridge.operator, !name.isEmpty {
            parts.append(String(localized: Strings.Connection.publicOperator(name)))
        }
        if let servers = bridge.homeservers {
            parts.append(String(localized: Strings.Connection.publicServers(servers.joined(separator: ", "))))
        } else {
            parts.append(String(localized: Strings.Connection.publicAnyServer))
        }
        guard let line = parts.first.map({ _ in parts.joined(separator: " · ") }) else { return nil }
        // The parts are written to sit mid-sentence; the line as a whole starts with a capital.
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        withAnimation(.smooth(duration: Theme.Timing.reaction)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.smooth(duration: Theme.Timing.reaction)) { copied = false }
        }
    }
}
