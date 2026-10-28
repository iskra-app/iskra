import SwiftUI
import IskraCore
import IskraDesign

/// "What is Matrix?" — opened from the small link at the foot of the sign-in screen, for somebody
/// who has never heard the word. The opening paragraph is set larger: it is the whole answer,
/// and the three sections under it are why it matters.
struct AboutMatrixView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.generous) {
                    Text(Strings.AboutMatrix.intro)
                        .font(.title3.weight(.medium))
                    section(Strings.AboutMatrix.emailTitle, Strings.AboutMatrix.emailBody)
                    section(Strings.AboutMatrix.nobodyTitle, Strings.AboutMatrix.nobodyBody)
                    section(Strings.AboutMatrix.privateTitle, Strings.AboutMatrix.privateBody)
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

    private func section(_ title: LocalizedStringResource, _ body: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}
