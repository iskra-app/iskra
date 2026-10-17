import IskraCore
import IskraDesign
import SwiftUI

/// Adding one's own bridge, or changing one: a name to tell it apart, its address, the relays to
/// meet it on.
///
/// A sheet, so `dismiss` is its own to use — the trap with it is a screen pushed onto the sidebar's
/// stack, which this is not.
///
/// Nothing is saved that is not a bridge: the address has to be a public key before "Save" is on,
/// and what is wrong with it is said under the field — a pasted `nsec` most of all, which is
/// somebody about to hand a stranger the key to their bridge.
struct BridgeEditor: View {
    struct Target: Identifiable {
        /// The bridge being changed; `nil` to add one.
        var bridge: PublicBridge?
        var id: String { bridge?.id ?? "new" }
    }

    let target: Target
    let onSave: (PublicBridge) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var relays: String

    init(target: Target, onSave: @escaping (PublicBridge) -> Void) {
        self.target = target
        self.onSave = onSave
        _name = State(initialValue: target.bridge?.name ?? "")
        _address = State(initialValue: target.bridge?.npub ?? "")
        // The defaults are not written out: an empty field means them, and stays meaning them.
        let relays = target.bridge?.relays ?? []
        _relays = State(initialValue: relays == TunnelSettings.defaultRelays ? "" : relays.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: Strings.Connection.bridgeNamePrompt), text: $name)
                } header: {
                    Text(Strings.Connection.bridgeName)
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
            }
            .formStyle(.grouped)
            .navigationTitle(Text(target.bridge == nil ? Strings.Connection.addBridge : Strings.Connection.editBridge))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: Strings.Connection.cancelEditing)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: Strings.Connection.saveBridge)) { save() }
                        .disabled(!BridgeAddress.isValid(address))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
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

    private func save() {
        guard let bridge = TunnelSettings.saveCustom(name: name, address: address, relays: relays,
                                                     id: target.bridge?.id) else { return }
        onSave(bridge)
        dismiss()
    }
}
