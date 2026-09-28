import IskraCore
import IskraDesign
import SwiftUI

/// Where traffic is sent through a bridge instead of straight at the homeserver.
///
/// The switch and the address take effect on the *next* connection rather than immediately, and
/// the screen says so by showing what is happening **now** rather than what was chosen: the client
/// is built once, at sign-in or at launch, and re-pointing a live one is not something the SDK
/// offers. Which is exactly why the check button is here — it raises a tunnel of its own and asks
/// the bridge a question, so that "did I paste the right key" is answerable without signing out.
struct ConnectionView: View {
    let session: UserSession

    @AppStorage(TunnelSettings.enabledKey) private var throughBridge = false
    @AppStorage(TunnelSettings.addressKey) private var address = ""
    @AppStorage(TunnelSettings.relaysKey) private var relays = ""

    @State private var status: TunnelStatus = .off
    @State private var myKey: String?
    @State private var copied = false
    @State private var checking = false
    @State private var outcome: BridgeCheck.Outcome?

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
                TextField(String(localized: Strings.Connection.addressPrompt),
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
            } header: {
                Text(Strings.Connection.address)
            } footer: {
                Text(Strings.Connection.addressFooter)
            }

            Section {
                TextField(String(localized: Strings.Connection.relaysPrompt), text: $relays, axis: .vertical)
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
                LabeledContent(String(localized: Strings.Connection.status)) {
                    Text(describe(status))
                        .foregroundStyle(.secondary)
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
        .navigationTitle(Text(Strings.Connection.title))
        .task {
            status = await session.tunnelStatus()
            myKey = await session.tunnelPublicKey()
        }
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
        case .routingLocally: Strings.Connection.statusLocal
        case .bridged(let relays): Strings.Connection.statusBridged(relays)
        case .failed: Strings.Connection.statusFailed
        }
    }

    private func describe(_ outcome: BridgeCheck.Outcome) -> LocalizedStringResource {
        switch outcome {
        case .reachable(let milliseconds): Strings.Connection.checkOK(milliseconds)
        case .refused: Strings.Connection.checkRefused
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
