import SwiftUI
import IskraCore
import IskraDesign

/// The JSON behind a message, for a developer — see `BetaFeatures.showsEventSourceKey`.
struct EventSource: Identifiable {
    let id = UUID()
    let json: String
}

/// The event as the server sent it, selectable and copyable, in a sheet of its own.
struct EventSourceSheet: View {
    let json: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: json)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.roomy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(String(app: Strings.Beta.viewSource))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Folders.done)) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Clipboard.copy(json)
                    } label: {
                        Label(String(app: Strings.Message.Menu.copy), systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
