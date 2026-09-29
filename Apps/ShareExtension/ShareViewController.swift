import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import IskraCore

/// The principal class of the Share extension — what iOS launches when someone shares something to
/// Iskra from another app: words, a link, photos, videos, files.
///
/// It pulls what was shared out of the extension context, shows a room picker built from the chat
/// directory the app keeps in the App Group, and — on a choice — writes the message to the shared
/// outbox and finishes. Iskra sends it the next time it comes up, the same outbox the App Intents
/// use.
///
/// **It does not send anything itself, and that is a decision, not a gap.** Sending means
/// encrypting for the room, and encrypting means writing to the crypto store — Olm sessions, the
/// index of the room's outbound Megolm session. The app may be suspended at this very moment with
/// its own copy of that state in memory, and two processes advancing the same ratchet is the one
/// failure in this project that cannot be undone afterwards: messages nobody can decrypt. The
/// notification extension gets away with sharing the store because it only *reads* from it. So the
/// words and the files wait, and the SDK in the app sends them through the same encrypted path as
/// anything picked in a chat.
///
/// Files are copied into `ChatDirectory.outboxFolder()`, because the URLs a share sheet hands over
/// belong to the sharing app and stop existing when this extension finishes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await present() }
    }

    /// With the app lock on, nothing is copied and no chat is listed until the owner has proved it
    /// is them. The share sheet used to be a way round the lock: anyone holding the unlocked phone
    /// saw every account's chat names and could queue a message, which the app then sent the next
    /// time it came to the front — still behind its shield.
    private func present() async {
        let defaults = UserDefaults(suiteName: AppEnvironment.appGroupIdentifier)
        guard AppLock.isLockedNow(defaults: defaults) else { return await presentPicker() }

        let lock = AppLock(defaults: defaults)
        show(ShareLockedView(
            onUnlock: { [weak self] in
                guard await lock.authenticate(reason: String(localized: CoreStrings.Share.unlockReason)) else { return }
                await self?.presentPicker()
            },
            onCancel: { [weak self] in self?.cancel() }
        ))
    }

    private func presentPicker() async {
        let shared = await extractShared()

        let picker = SharePickerView(
            shared: shared,
            chats: ChatDirectory.directory(),
            onSend: { [weak self] chat in
                if !shared.isEmpty {
                    // Whose chat it is travels with it: the app sends it from that account, and
                    // opens that account to do so if another one is on screen.
                    ChatDirectory.enqueue(.init(roomID: chat.id,
                                                text: shared.text,
                                                attachments: shared.attachments.map(\.attachment),
                                                accountID: chat.accountID))
                }
                self?.finish()
            },
            onCancel: { [weak self] in
                shared.discard()
                self?.cancel()
            }
        )

        show(picker)
    }

    private func show(_ screen: some View) {
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let host = UIHostingController(rootView: screen)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // MARK: - What was shared

    /// Everything shared: the words flattened to one string — text as-is, a web link as its
    /// address, several joined by newlines — and every picture, video and file copied into the
    /// outbox folder.
    private func extractShared() async -> SharedContent {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return SharedContent() }
        var content = SharedContent()

        for item in items {
            for provider in item.attachments ?? [] {
                // Pictures and videos before anything else: a photo from Photos also answers to
                // "data", and a web page shared from Safari answers to "URL" *and* "text".
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let copied = await copyImage(provider) {
                    content.attachments.append(copied)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                          let copied = await copyFile(provider, type: .movie, kind: .video) {
                    content.attachments.append(copied)
                } else if let url = await loadString(provider, as: UTType.url.identifier, asURL: true),
                          !url.hasPrefix("file:") {
                    content.pieces.append(url)
                } else if let text = await loadString(provider, as: UTType.plainText.identifier, asURL: false) {
                    content.pieces.append(text)
                } else if let text = await loadString(provider, as: UTType.text.identifier, asURL: false) {
                    content.pieces.append(text)
                } else if let copied = await copyFile(provider, type: .data, kind: .file) {
                    content.attachments.append(copied)
                }
            }
        }
        return content
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

    /// A picture, as a file. Most apps hand over a file, and it is copied as it is — HEIC stays
    /// HEIC, and the name it had goes with it. A screenshot shared straight from the thumbnail
    /// arrives as a bare `UIImage` instead, and is written out as a JPEG.
    private func copyImage(_ provider: NSItemProvider) async -> SharedAttachment? {
        if let copied = await copyFile(provider, type: .image, kind: .image) { return copied }

        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let image = item as? UIImage {
                    continuation.resume(returning: image.jpegData(compressionQuality: 0.9))
                } else if let data = item as? Data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let data else { return nil }
        return try? SharedAttachment.write(data, named: "\(Self.photoName).jpg", kind: .image)
    }

    /// Any file, copied into the outbox before the provider's own copy disappears — which it does
    /// the moment the completion handler returns, so the copy happens inside it.
    private func copyFile(_ provider: NSItemProvider,
                          type: UTType,
                          kind: ChatDirectory.OutboxAttachment.Kind) async -> SharedAttachment? {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: type) == true
        }) else { return nil }

        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let name = Self.filename(suggested: suggested, source: url, type: UTType(identifier))
                continuation.resume(returning: try? SharedAttachment.copy(url, named: name, kind: kind))
            }
        }
    }

    /// The name the file goes by in the chat. The one the sharing app suggested, with the
    /// extension the file actually has; the file's own name when there is no suggestion; and a
    /// dated one when neither says anything.
    nonisolated private static func filename(suggested: String?, source: URL, type: UTType?) -> String {
        let ext = source.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? "") : source.pathExtension
        let stem = suggested.map { ($0 as NSString).deletingPathExtension }
            ?? source.deletingPathExtension().lastPathComponent
        // The suggestion is the sharing app's to make, and nothing stops it being `../../x`.
        let base = SafeFilename.make(stem, fallback: photoName)
        let safeExt = SafeFilename.make(ext, fallback: "")
        return safeExt.isEmpty ? base : "\(base).\(safeExt)"
    }

    nonisolated private static var photoName: String {
        "Iskra \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))"
            .replacingOccurrences(of: ":", with: "-")
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "moscow.swag.iskra.share", code: 0))
    }
}

/// What is about to be sent: the words, and the files already copied for it.
struct SharedContent: Sendable {
    var pieces: [String] = []
    var attachments: [SharedAttachment] = []

    var text: String { pieces.joined(separator: "\n") }
    var isEmpty: Bool { pieces.isEmpty && attachments.isEmpty }

    /// Cancelled: the copies are the user's files in the clear in a shared folder, and nobody is
    /// going to send them now.
    func discard() {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
        }
    }
}

/// One picture, video or file, copied into the outbox.
struct SharedAttachment: Sendable, Identifiable {
    let attachment: ChatDirectory.OutboxAttachment
    /// Where the copy is, in this process — for the preview, and for throwing it away.
    let url: URL

    var id: String { attachment.filename }
    var name: String { url.lastPathComponent }

    /// A folder of its own for every file, so two called `IMG_0001.jpg` cannot overwrite each other
    /// — see `OutboxAttachment.filename`.
    private static func slot(named name: String) throws -> (URL, String) {
        let folder = UUID().uuidString
        let directory = try ChatDirectory.outboxFolder().appending(component: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appending(component: name), "\(folder)/\(name)")
    }

    static func copy(_ source: URL, named name: String, kind: ChatDirectory.OutboxAttachment.Kind) throws -> SharedAttachment {
        let (url, path) = try slot(named: name)
        try FileManager.default.copyItem(at: source, to: url)
        return SharedAttachment(attachment: .init(kind: kind, filename: path), url: url)
    }

    static func write(_ data: Data, named name: String, kind: ChatDirectory.OutboxAttachment.Kind) throws -> SharedAttachment {
        let (url, path) = try slot(named: name)
        try data.write(to: url, options: .atomic)
        return SharedAttachment(attachment: .init(kind: kind, filename: path), url: url)
    }
}

/// What the share sheet shows while Iskra is locked: nothing of the user's, and the one way on.
private struct ShareLockedView: View {
    let onUnlock: @MainActor () async -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label { Text(CoreStrings.Share.locked) } icon: { Image(systemName: "lock.fill") }
            } description: {
                Text(CoreStrings.Share.lockedBody)
            } actions: {
                Button(String(localized: CoreStrings.Share.unlock)) {
                    Task { await onUnlock() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: CoreStrings.Share.cancel), action: onCancel)
                }
            }
        }
        // Asked straight away, as the app's own shield does; the button is the retry.
        .task { await onUnlock() }
    }
}

/// The room picker the extension shows: a preview of what is being shared, and the list of chats to
/// send it to, read from the App-Group directory. Empty when nobody is signed in — the honest state
/// for an extension that has no session of its own to check.
private struct SharePickerView: View {
    let shared: SharedContent
    let chats: [ChatDirectoryEntry]
    let onSend: (ChatDirectoryEntry) -> Void
    let onCancel: () -> Void

    @State private var query = ""

    private var shownChats: [ChatDirectoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chats }
        return chats.filter { $0.name.localizedStandardContains(trimmed) }
    }

    /// The accounts in the directory, in the order their chats appear. `nil` is a directory written
    /// before there could be two accounts.
    private var accounts: [String?] {
        var seen: [String?] = []
        for chat in chats where !seen.contains(chat.accountID) {
            seen.append(chat.accountID)
        }
        return seen
    }

    var body: some View {
        NavigationStack {
            List {
                if !shared.isEmpty {
                    Section {
                        if !shared.attachments.isEmpty {
                            attachmentStrip
                        }
                        if !shared.text.isEmpty {
                            Text(shared.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    } footer: {
                        Text(CoreStrings.Share.willSendOnOpen)
                    }
                }

                // A section per account when there is more than one on the device, headed with its
                // name — the same room can be in both, and which of them sends it matters.
                ForEach(accounts, id: \.self) { account in
                    Section {
                        ForEach(shownChats.filter { $0.accountID == account }) { chat in
                            Button {
                                onSend(chat)
                            } label: {
                                Text(chat.name)
                            }
                        }
                    } header: {
                        if accounts.count > 1,
                           let name = chats.first(where: { $0.accountID == account })?.accountName {
                            Text(verbatim: name)
                        }
                    }
                }
            }
            .searchable(text: $query)
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

    /// The pictures as pictures, and everything else as its name — enough to see that the right
    /// thing is about to be sent, and small enough to leave the chats on screen.
    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(shared.attachments) { item in
                    AttachmentTile(item: item)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

private struct AttachmentTile: View {
    let item: SharedAttachment

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: item.attachment.kind == .video ? "video" : "doc")
                        .font(.title2)
                    Text(item.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(4)
            }
        }
        .frame(width: 72, height: 72)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            guard item.attachment.kind == .image else { return }
            thumbnail = Self.thumbnail(of: item.url)
        }
    }

    /// Downsampled on the way in. A share extension has a small memory allowance, and a
    /// 48-megapixel photo decoded whole to draw a 72-point tile is how one gets killed.
    private static func thumbnail(of url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 216,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
