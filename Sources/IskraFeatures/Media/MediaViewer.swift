import AVKit
import SwiftUI
import IskraCore
import IskraDesign

#if os(iOS)
import Photos
#endif

/// A photo or a video, opened.
///
/// The one place in the app where an attachment is fetched in full. Everywhere else shows a
/// thumbnail — scrolling past a hundred photos must not download a hundred photos — and this is
/// what "the user tapped it" turns into.
///
/// It fetches a **file**, not bytes, and that is what makes the whole screen work: `AVPlayer`
/// needs a URL, `ShareLink` needs a URL, and saving to the photo library needs a URL. One
/// `MediaFile` serves all three, and it is held for exactly as long as this view is on screen —
/// let go of it and the SDK deletes the decrypted bytes from disk, which is the point of
/// holding it. In an encrypted room those bytes are the user's private photograph sitting in
/// plaintext, and the moment the viewer closes they are gone again.
struct MediaViewer: View {
    let attachment: Attachment
    /// Whether to bring `AVKit` and its scrubber, or a picture and a zoom.
    let isVideo: Bool

    @Environment(\.mediaLoader) private var loader
    @Environment(\.dismiss) private var dismiss

    @State private var file: MediaFile?
    @State private var image: Image?
    @State private var player: AVPlayer?
    @State private var failed = false

    /// How far down the user has dragged. A photo you can flick away is the gesture every phone
    /// has taught its owner, and the app that ignores it feels stuck.
    @State private var dragOffset: CGFloat = 0

    /// The zoom, and where it is centred. Held across gestures — pinching, letting go, and
    /// pinching again should carry on from where the last one stopped, not snap back to 1×.
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    /// How far down it has to go to count as "close it". Short of that it springs back, which is
    /// what tells the user the gesture exists.
    private static let dismissDistance: CGFloat = 120

    /// The picture fades as it is dragged away, so the conversation behind it comes back into
    /// view as the photo leaves rather than after it has gone.
    private var backdropOpacity: Double {
        max(0, 1 - Double(abs(dragOffset)) / (Self.dismissDistance * 3))
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            content
                .offset(y: dragOffset)
        }
        .frame(minWidth: Theme.Size.viewer, minHeight: Theme.Size.viewer)
        .overlay(alignment: .top) { chrome }
        .task { await load() }
        .onDisappear {
            player?.pause()
            player = nil
            // And the plaintext leaves the disk with it.
            file = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if failed {
            Label(Strings.Message.Media.loadFailed, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.white)
        } else if let player {
            // A video the user has chosen to watch deserves a scrubber, and this is the one
            // place in the app where `AVKit` is allowed to draw its own chrome. A video note in
            // the timeline is not this: it is a glance, and it plays inside its circle.
            VideoPlayer(player: player)
        } else if let image {
            zoomable(image)
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    /// The photo, with the two gestures a photo is expected to answer.
    ///
    /// The drag is only allowed while the picture is *not* zoomed in, and that is the whole
    /// trick to making both work: once you are magnified, dragging means panning around the
    /// photograph, and a downward pan would otherwise throw the viewer off the screen halfway
    /// through looking at something.
    private func zoomable(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(magnification)
            .gesture(drag)
            // Двойное касание — the shortcut nobody has to be taught: in, and back out again.
            .onTapGesture(count: 2) {
                withAnimation(.smooth(duration: 0.25)) {
                    if zoom > 1 {
                        zoom = 1
                        committedZoom = 1
                        pan = .zero
                        committedPan = .zero
                    } else {
                        zoom = 2
                        committedZoom = 2
                    }
                }
            }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Never below 1×: a photo pinched smaller than the screen it is on floats in
                // the middle of a black rectangle, which is not something anybody wanted.
                zoom = max(1, committedZoom * value.magnification)
            }
            .onEnded { _ in
                committedZoom = zoom
                if zoom <= 1 {
                    withAnimation(.smooth) {
                        pan = .zero
                        committedPan = .zero
                    }
                }
            }
    }

    /// One drag, two meanings, and which one it has depends on the zoom.
    ///
    /// It has to be a single gesture. Two — one for panning, one for dismissing, chosen with a
    /// ternary — does not compile and would not work if it did: SwiftUI attaches the gesture
    /// when the view is built, and swapping which one is attached mid-pinch would take the
    /// gesture out from under the finger already moving.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if zoom > 1 {
                    // Magnified: the drag moves the photograph under the window.
                    pan = CGSize(width: committedPan.width + value.translation.width,
                                 height: committedPan.height + value.translation.height)
                } else {
                    // Downward only. Dragging a photo *up* off the screen is not a gesture
                    // anything else in the system honours, and answering it here would mean the
                    // picture sliding away from a flick that was meant to scroll something.
                    dragOffset = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if zoom > 1 {
                    committedPan = pan
                } else if value.translation.height > Self.dismissDistance {
                    dismiss()
                } else {
                    withAnimation(.smooth) { dragOffset = 0 }
                }
            }
    }

    /// Close, share, save. Over the picture, and out of the way of it.
    private var chrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Message.Media.close))

            Spacer()

            // Both only once the file is actually here. A share sheet offering a file that has
            // not finished downloading would hand the other app an empty URL.
            if let file {
                #if os(iOS)
                Button {
                    Task { await saveToPhotos(file) }
                } label: {
                    Image(systemName: saveIcon)
                        .font(.title3)
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(saveState != .idle)
                .accessibilityLabel(Text(Strings.Message.Media.save))
                #endif

                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.Message.Media.share))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.normal)
        // The buttons fade out with the backdrop as the photo is dragged away, rather than
        // hanging in the air over a picture that is already halfway gone.
        .opacity(backdropOpacity)
    }

    // MARK: - Loading

    private func load() async {
        guard let loader else { return }

        do {
            let file = try await loader.file(for: attachment)
            self.file = file

            if isVideo {
                PlaybackAudio.prepare()
                let player = AVPlayer(url: file.url)
                self.player = player
                // The viewer *is* the video: it starts on opening rather than waiting for a
                // second press on a second play button.
                player.play()
            } else {
                // Read off the file we already have rather than downloading the same bytes a
                // second time through `data(for:)`. The file is the thing `ShareLink` and the
                // photo library need anyway.
                guard let data = try? Data(contentsOf: file.url),
                      let image = Image(mediaData: data) else {
                    failed = true
                    return
                }
                self.image = image
            }
        } catch {
            Log.media.error("the attachment would not open: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }

    // MARK: - Saving

    /// Whether the photo has been put in the library, and whether it went.
    ///
    /// A button that answers a press with nothing at all is the failure this app is written
    /// against, and saving is exactly the act with no visible result: the picture does not
    /// change, the viewer does not close, and the photo either is in the library or is not. So
    /// the button says so itself — a tick, or a cross.
    private enum SaveState { case idle, saved, failed }

    @State private var saveState: SaveState = .idle

    private var saveIcon: String {
        switch saveState {
        case .idle: "arrow.down.circle"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    #if os(iOS)
    /// Puts it in the photo library.
    ///
    /// `addOnly` authorisation, deliberately: this app has no business *reading* somebody's
    /// photo library — the picker it already uses hands over the one picture the user chose,
    /// without any access at all — and asking for the whole library to write one file into it
    /// is the kind of over-reach a permission prompt exists to make visible.
    private func saveToPhotos(_ file: MediaFile) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed
            return
        }

        do {
            let url = file.url
            let isVideo = isVideo
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saveState = .saved
        } catch {
            // Not the picture, and not where it came from: only that the library refused it.
            Log.media.error("the photo library would not take the file: \(String(describing: error), privacy: .public)")
            saveState = .failed
        }
    }
    #endif
}
