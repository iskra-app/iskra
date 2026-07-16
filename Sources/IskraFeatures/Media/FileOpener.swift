import SwiftUI
import IskraCore
import IskraDesign

#if os(macOS)
import AppKit
#else
import QuickLook
#endif

/// Opening a file somebody sent — a PDF, a spreadsheet, a zip.
///
/// The app does not try to render it. There is a whole framework on each platform whose job is
/// to know what a `.numbers` file looks like, and reimplementing a corner of it here would mean
/// a viewer that handles four formats and shrugs at the fifth. So the file is handed over:
/// QuickLook on iOS, whatever the user has chosen to open it with on the Mac.
///
/// The `MediaFile` is the load-bearing part. The decrypted bytes exist only while it does, and
/// both platforms need the file to *stay there* for longer than this function runs — QuickLook
/// reads it while its sheet is up, and `NSWorkspace` hands the path to another application
/// entirely. So it is held in state for as long as the preview is open, and on the Mac it is
/// deliberately copied out of the SDK's reach first: see `handOff`.
@MainActor
@Observable
final class FileOpener {
    private(set) var isLoading = false
    private(set) var failed = false

    /// The file being previewed, and nil when none is. On iOS this is what the QuickLook sheet
    /// is bound to; setting it to nil closes the sheet and deletes the plaintext.
    private(set) var previewing: MediaFile?

    func open(_ attachment: Attachment, using loader: MediaLoader?) async {
        guard !isLoading, let loader else { return }

        isLoading = true
        failed = false
        defer { isLoading = false }

        do {
            let file = try await loader.file(for: attachment)

            #if os(macOS)
            try handOff(file, named: attachment.filename)
            #else
            previewing = file
            #endif
        } catch {
            Log.media.error("the file would not open: \(Log.describe(error), privacy: .public)")
            failed = true
        }
    }

    func closePreview() {
        // And the plaintext leaves the disk with it.
        previewing = nil
    }

    #if os(macOS)
    /// Copies the file somewhere the app is not about to delete, and asks the system to open it.
    ///
    /// The copy is not tidiness. `NSWorkspace.open` returns as soon as the *other* application
    /// has been launched, not when it has finished reading — and the moment this function
    /// returns, the `MediaFile` deallocates and the SDK deletes the bytes out from under it.
    /// Preview would open on a file that no longer exists.
    ///
    /// So there is plaintext on the disk, and something has to own it. Nothing did: the copy went
    /// straight into the temporary directory under the sender's own filename and stayed there —
    /// past the preview closing, past sign-out, until the system felt like sweeping the directory,
    /// which may be months. Open ten documents somebody sent you and ten decrypted copies of them
    /// are sitting in `/var/folders` under names that describe their contents.
    ///
    /// They live in a directory of our own now, and `sweep()` empties it. It cannot be done when
    /// the preview closes — we are never told, the file belongs to another application by then —
    /// so it is done on the way *in*: opening anything clears what the last one left. The window
    /// in which a decrypted file exists on disk is now "until the next thing is opened, or until
    /// the app is next launched", instead of "indefinitely".
    private func handOff(_ file: MediaFile, named filename: String) throws {
        Self.sweep()

        // The sender's filename is kept — it is what the other application uses to decide what it
        // is opening, and a UUID would hand Preview a file it does not recognise — but it is kept
        // *inside* a directory we own and empty, rather than loose in the system's.
        let directory = Self.handOffDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appending(component: filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file.url, to: destination)

        NSWorkspace.shared.open(destination)
    }

    /// Everything handed to another application last time. Cleared on the way into this one, and
    /// again at launch and at sign-out — see `IskraRootView`. Sign-out matters most: a decrypted
    /// document must not outlive the account it came from.
    static func sweep() {
        try? FileManager.default.removeItem(at: handOffDirectory)
    }

    private static var handOffDirectory: URL {
        URL.temporaryDirectory.appending(component: "iskra-open")
    }
    #endif
}

#if !os(macOS)
/// QuickLook, wrapped. It is a view controller, and it has been since before SwiftUI existed.
struct FilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url as NSURL
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url as NSURL)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: NSURL

        init(url: NSURL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            url
        }
    }
}
#endif

/// The bubble for a file or a piece of music: an icon, a name, and a press that opens it.
///
/// It was a `Label` with no gesture on it — a row that looked like a button, said the filename,
/// and did nothing at all when pressed. That is the exact failure this app is written against,
/// and it stood in two of the seven kinds of message the timeline can draw.
struct FileBubble: View {
    let attachment: Attachment
    let systemImage: String

    /// The fill behind the icon and the name — or, on `.plain`, none: the icon is what says
    /// this is a file rather than a sentence, and it says it without a slab behind it.
    let style: BubbleStyle

    @Environment(\.mediaLoader) private var loader

    @State private var opener = FileOpener()

    var body: some View {
        Button {
            Task { await opener.open(attachment, using: loader) }
        } label: {
            HStack(spacing: Theme.Spacing.close) {
                Group {
                    if opener.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: opener.failed ? "exclamationmark.triangle" : systemImage)
                    }
                }
                .frame(width: Theme.Size.voiceButton)

                Text(attachment.filename)
                    .lineLimit(1)
            }
            .font(.body)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .messageBubble(style)
        .accessibilityLabel(Text(attachment.filename))
        .accessibilityHint(Text(Strings.Message.Media.openFile))
        #if !os(macOS)
        // On iOS the file is previewed inside the app; on the Mac it is handed to whatever
        // opens that kind of file, so there is no sheet to present.
        .sheet(isPresented: .init(get: { opener.previewing != nil },
                                  set: { if !$0 { opener.closePreview() } })) {
            if let file = opener.previewing {
                FilePreview(url: file.url)
                    .ignoresSafeArea()
            }
        }
        #endif
    }
}
