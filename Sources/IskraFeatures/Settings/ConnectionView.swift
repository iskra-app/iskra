import IskraCore
import IskraDesign
import SwiftUI

/// Where traffic is sent through a bridge instead of straight at the homeserver.
///
/// The switch takes effect on the next connection rather than immediately, and the screen says so
/// by showing what is happening *now* rather than what was chosen: the client is built once, at
/// sign-in or at launch, and re-pointing a live one is not something the SDK offers.
struct ConnectionView: View {
    let session: UserSession

    @AppStorage(TunnelSettings.enabledKey) private var throughBridge = false
    @State private var status: TunnelStatus = .off

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $throughBridge.animation(.smooth(duration: Theme.Timing.reaction))) {
                    Label(Strings.Connection.bridge, systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
            } footer: {
                Text(Strings.Connection.bridgeFooter)
            }

            Section {
                LabeledContent(String(localized: Strings.Connection.status)) {
                    Text(describe(status))
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
        }
    }

    private func describe(_ status: TunnelStatus) -> LocalizedStringResource {
        switch status {
        case .off: Strings.Connection.statusDirect
        case .routingLocally: Strings.Connection.statusLocal
        case .failed: Strings.Connection.statusFailed
        }
    }
}
