import SwiftUI
import IskraDesign

/// The little form that stands between a long-press and a report. Matrix carries a free-text reason
/// on a report, and this is where the user writes it — but the reason is optional, because a report
/// with no words is still a report, and demanding a sentence is a reason not to file one.
///
/// The copy is careful about who receives it: the server's moderators, not us. This app cannot
/// action a report and should not imply it can.
struct ReportSheet: View {
    var onReport: (String) -> Void

    @State private var reason = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(app: Strings.Message.Report.reasonPrompt),
                              text: $reason,
                              axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text(Strings.Message.Report.explanation)
                }
            }
            .navigationTitle(Text(Strings.Message.Report.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Message.Report.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Message.Report.submit)) {
                        onReport(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}
