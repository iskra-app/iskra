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
    /// Holds the Iskra developers' bridge until somebody types another; emptied, there is no bridge.
    @AppStorage(TunnelSettings.addressKey, store: TunnelSettings.store)
    private var address = TunnelSettings.defaultAddress
    @AppStorage(TunnelSettings.relaysKey, store: TunnelSettings.store) private var relays = ""

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
                TextField(String(app: Strings.Connection.addressPrompt),
                          text: $address.animation(.smooth(duration: Theme.Timing.reaction)),
                          axis: .vertical)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .font(.body.monospaced())
                    .lineLimit(1...3)

                if let complaint {
                    Label(complaint, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !isDefaultAddress {
                    Button {
                        withAnimation(.smooth(duration: Theme.Timing.reaction)) {
                            address = TunnelSettings.defaultAddress
                        }
                    } label: {
                        Label(Strings.Connection.defaultBridge, systemImage: "arrow.uturn.backward")
                    }
                }
            } header: {
                Text(Strings.Connection.address)
            } footer: {
                Text(Strings.Connection.addressFooter)
            }

            Section {
                TextField(String(app: Strings.Connection.relaysPrompt), text: $relays, axis: .vertical)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .font(.body.monospaced())
                    .lineLimit(1...4)
            } header: {
                Text(Strings.Connection.relays)
            } footer: {
                Text(Strings.Connection.relaysFooter)
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
                LabeledContent(String(app: Strings.Connection.status)) {
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
                .disabled(checking || !BridgeAddress.isValid(address))

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
        .formStyle(.groupedRows)
        .navigationTitle(Text(Strings.Connection.title))
        .task {
            status = await session.tunnelStatus()
            myKey = await session.tunnelPublicKey()
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
        _ = (throughBridge, address, relays)
        return TunnelSettings.snapshot() != appeared
    }

    private func apply() {
        appeared = TunnelSettings.snapshot()
        NotificationCenter.default.post(name: TunnelSettings.changed, object: nil)
    }

    private var isDefaultAddress: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines) == TunnelSettings.defaultAddress
    }

    /// What is wrong with what has been typed, if anything. Nothing while the field is empty: an
    /// empty field is where everybody starts, not a mistake.
    private var complaint: LocalizedStringResource? {
        switch BridgeAddress.publicKey(from: address) {
        case .success, .failure(.empty): nil
        case .failure(.looksLikeASecretKey): Strings.Connection.addressSecret
        case .failure(.notAKey): Strings.Connection.addressBad
        }
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

    private func check() {
        guard case .success(let key) = BridgeAddress.publicKey(from: address) else { return }
        checking = true
        outcome = nil
        Task {
            let homeserver = await session.homeserverURL
            outcome = await BridgeCheck.run(bridgeKey: key,
                                            relays: TunnelSettings.parseRelays(relays).isEmpty
                                                ? TunnelSettings.defaultRelays.compactMap(URL.init(string:))
                                                : TunnelSettings.parseRelays(relays),
                                            homeserver: homeserver)
            checking = false
        }
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
