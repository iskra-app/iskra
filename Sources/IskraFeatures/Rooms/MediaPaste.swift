import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

extension View {
    /// ⌘V with a photo or video on the clipboard attaches it. `receive` is handed what was pasted,
    /// and how many of the things on the clipboard could not be read.
    ///
    /// Not SwiftUI's paste handler alone, and the Mac is why. By the time anyone presses ⌘V the
    /// cursor is in the composer, and the text field is the first responder: AppKit sends `paste:`
    /// to the first object in the chain that *understands* it, and the field editor understands it
    /// perfectly — it just has nothing it can do with a picture, so it greys out Paste and the key
    /// beeps. Nothing further up the chain, where SwiftUI's handler lives, ever hears of it. So on
    /// the Mac the keystroke is caught before the menu gets it, and only when it would otherwise
    /// have done nothing useful — see `MediaPasteboard.pasteMeansAttach`. A clipboard with words on
    /// it is left to the field, which is where words go.
    ///
    /// On iPhone and iPad a text field that cannot take what is on the clipboard declines `paste:`
    /// and UIKit *does* walk on up the chain, so `pasteDestination` is the whole of it there — from
    /// iOS 27, which is when it arrived on iOS. Before that, "Paste photo or video" under the "+" is
    /// the way in, and it is there on every version.
    func mediaPaste(isEnabled: Bool,
                    receive: @escaping @MainActor (_ items: [PendingAttachment], _ unreadable: Int) -> Void) -> some View {
        modifier(MediaPaste(isEnabled: isEnabled, receive: receive))
    }
}

private struct MediaPaste: ViewModifier {
    let isEnabled: Bool
    let receive: @MainActor ([PendingAttachment], Int) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background {
            PasteKeyCatcher(isEnabled: isEnabled) {
                Task {
                    let (items, unreadable) = await MediaPasteboard.items()
                    receive(items, unreadable)
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #else
        if #available(iOS 27, *) {
            // The payload arrives with the paste, and is used as it is: reading the clipboard a
            // second time to get at it would be a second read, and a second "Allow Paste?" for it.
            content.pasteDestination(for: PastedMedia.self) { pasted in
                guard isEnabled else { return }
                Task {
                    var items: [PendingAttachment] = []
                    for media in pasted {
                        if let item = await PendingAttachment.make(data: media.data, type: media.type) {
                            items.append(item)
                        }
                    }
                    receive(items, pasted.count - items.count)
                }
            }
        } else {
            content
        }
        #endif
    }
}

/// A photo or video as a paste hands it over — the bytes, and roughly what they are.
///
/// Roughly, for a photo: `PendingAttachment` reads the real format out of the bytes and does not
/// need telling. Not for a video, whose format only its container knows — so the two containers a
/// phone actually produces are asked for by name first, and the name goes on the file.
private struct PastedMedia: Transferable {
    let data: Data
    let type: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .mpeg4Movie) { PastedMedia(data: $0, type: .mpeg4Movie) }
        DataRepresentation(importedContentType: .quickTimeMovie) { PastedMedia(data: $0, type: .quickTimeMovie) }
        DataRepresentation(importedContentType: .movie) { PastedMedia(data: $0, type: .movie) }
        DataRepresentation(importedContentType: .image) { PastedMedia(data: $0, type: .image) }
    }
}

#if os(macOS)
/// An empty view whose only job is to know which window the room is in.
///
/// That is what keeps ⌘V from attaching to the wrong conversation. A local event monitor sees every
/// key pressed anywhere in the app — in a second window showing another room, in the search sheet
/// over this one, which is a window of its own — and the only honest test of "was this pressed
/// here" is the event's window being this view's.
private struct PasteKeyCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let perform: @MainActor () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.isEnabled = isEnabled
        view.perform = perform
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.isEnabled = isEnabled
        view.perform = perform
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var isEnabled = false
        var perform: @MainActor () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.claims(event) else { return event }
                self.perform()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func claims(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  Self.isV(event) else { return false }
            return MediaPasteboard.pasteMeansAttach
        }

        /// ⌘V on whatever layout is switched on. On the Russian one the key says "м", and AppKit
        /// still treats it as ⌘V for the menu — so the physical key counts too, but only when the
        /// layout puts no Latin letter on it: on Dvorak that key is K, and ⌘K is something else.
        private static func isV(_ event: NSEvent) -> Bool {
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if typed == "v" { return true }
            let isLatin = typed.unicodeScalars.allSatisfy { $0.isASCII }
            return event.keyCode == 9 && !isLatin
        }
    }
}
#endif
