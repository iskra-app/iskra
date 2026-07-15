import UIKit
import SwiftUI
import UniformTypeIdentifiers
import IskraCore

/// The principal class of the Share extension — what iOS launches when someone shares text or a link
/// to Iskra from another app.
///
/// It pulls the shared text (or URL) out of the extension context, shows a room picker built from
/// the chat directory the app keeps in the App Group, and — on a choice — writes the message to the
/// shared outbox and finishes. Iskra sends it the next time it comes up, the same outbox the App
/// Intents use. The extension never reaches the network itself: it links `IskraCore` for the App
/// Group and nothing else, and a share sheet is not the place to stand up a Matrix client.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await present() }
    }

    private func present() async {
        let sharedText = await extractSharedText()

        let picker = SharePickerView(
            sharedText: sharedText,
            chats: ChatDirectory.directory(),
            onSend: { [weak self] roomID in
                if !sharedText.isEmpty {
                    ChatDirectory.enqueue(.init(roomID: roomID, text: sharedText))
                }
                self?.finish()
            },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: picker)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Everything shared, flattened to one string — the text as-is, a URL as its address. Multiple
    /// items (rare from a share sheet) join with newlines.
    private func extractSharedText() async -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return "" }
        var pieces: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if let text = await loadString(provider, as: UTType.plainText.identifier, asURL: false) {
                    pieces.append(text)
                } else if let url = await loadString(provider, as: UTType.url.identifier, asURL: true) {
                    pieces.append(url)
                } else if let text = await loadString(provider, as: UTType.text.identifier, asURL: false) {
                    pieces.append(text)
                }
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Loads one attachment as a string, converting inside the completion handler so only a
    /// `Sendable` `String` — never the non-`Sendable` `NSSecureCoding` item — crosses back out.
    private func loadString(_ provider: NSItemProvider, as typeIdentifier: String, asURL: Bool) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if asURL, let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "moscow.swag.iskra.share", code: 0))
    }
}

/// The room picker the extension shows: a preview of what is being shared, and the list of chats to
/// send it to, read from the App-Group directory. Empty when nobody is signed in — the honest state
/// for an extension that has no session of its own to check.
private struct SharePickerView: View {
    let sharedText: String
    let chats: [ChatDirectoryEntry]
    let onSend: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if !sharedText.isEmpty {
                    Section {
                        Text(sharedText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    } footer: {
                        Text(CoreStrings.Share.willSendOnOpen)
                    }
                }

                Section {
                    ForEach(chats) { chat in
                        Button {
                            onSend(chat.id)
                        } label: {
                            Text(chat.name)
                        }
                    }
                }
            }
            .overlay {
                if chats.isEmpty {
                    ContentUnavailableView {
                        Label { Text(CoreStrings.Share.title) } icon: { Image(systemName: "paperplane") }
                    } description: {
                        Text(CoreStrings.Share.empty)
                    }
                }
            }
            .navigationTitle(Text(CoreStrings.Share.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: CoreStrings.Share.cancel), action: onCancel)
                }
            }
        }
    }
}
