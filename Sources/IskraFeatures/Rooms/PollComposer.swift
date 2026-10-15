import SwiftUI
import IskraCore
import IskraDesign

/// The sheet that writes a poll: a question, two answers to start with and more as they are
/// typed, and two switches.
///
/// A new empty answer appears under the last one as soon as that one has words in it, the way
/// Telegram's does — so there is no "Add" button to find for the common case, and the button that
/// remains is for the reader who wants to add one before typing.
struct PollComposer: View {
    let onSend: (PollDraft) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = PollDraft()
    @State private var isSending = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case question
        case answer(Int)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(app: Strings.Poll.questionPlaceholder), text: $draft.question, axis: .vertical)
                        .focused($focus, equals: .question)
                } header: {
                    Text(Strings.Poll.question)
                }

                Section {
                    ForEach(draft.answers.indices, id: \.self) { index in
                        HStack {
                            TextField(String(app: Strings.Poll.answerPlaceholder),
                                      text: answer(at: index))
                                .focused($focus, equals: .answer(index))
                                .submitLabel(.next)
                                .onSubmit { focus = index + 1 < draft.answers.count ? .answer(index + 1) : nil }
                            if draft.answers.count > 2 {
                                Button {
                                    remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(Strings.Poll.removeAnswer))
                            }
                        }
                    }
                    if draft.answers.count < PollDraft.maxAnswers {
                        Button {
                            draft.answers.append("")
                            focus = .answer(draft.answers.count - 1)
                        } label: {
                            Label { Text(Strings.Poll.addAnswer) } icon: { Image(systemName: "plus") }
                        }
                    }
                } header: {
                    Text(Strings.Poll.answers)
                }

                Section {
                    Toggle(String(app: Strings.Poll.allowMultiple), isOn: $draft.isMultipleChoice)
                    Toggle(String(app: Strings.Poll.anonymous), isOn: $draft.isAnonymous)
                } header: {
                    Text(Strings.Poll.settings)
                } footer: {
                    if draft.isAnonymous { Text(Strings.Poll.anonymousFooter) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(app: Strings.Poll.newTitle))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Poll.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Poll.send)) {
                        Task { await send() }
                    }
                    .disabled(!draft.canSend || isSending)
                }
            }
            .onAppear { focus = .question }
        }
    }

    /// A binding to one answer that grows the list: typing into the last one brings a fresh empty
    /// one under it, up to the limit.
    private func answer(at index: Int) -> Binding<String> {
        Binding {
            draft.answers.indices.contains(index) ? draft.answers[index] : ""
        } set: { text in
            guard draft.answers.indices.contains(index) else { return }
            draft.answers[index] = text
            if index == draft.answers.count - 1, !text.isEmpty, draft.answers.count < PollDraft.maxAnswers {
                draft.answers.append("")
            }
        }
    }

    private func remove(at index: Int) {
        guard draft.answers.indices.contains(index), draft.answers.count > 2 else { return }
        draft.answers.remove(at: index)
        focus = nil
    }

    private func send() async {
        guard draft.canSend, !isSending else { return }
        isSending = true
        await onSend(draft)
        dismiss()
    }
}
