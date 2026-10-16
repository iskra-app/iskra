import SwiftUI
import IskraCore
import IskraDesign

/// "What is Matrix?" — opened from the small link at the foot of the sign-in screen, for somebody
/// who has never heard the word. Empty for now: the words are still to be written.
struct AboutMatrixView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                }
                .padding(Theme.Spacing.generous)
                .frame(maxWidth: Theme.Size.signInColumn)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(Strings.AboutMatrix.title))
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
}
