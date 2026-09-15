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
///
/// The picture itself is handled by `ZoomableImage` on the phone and the iPad, which is a
/// `UIScrollView` and is there so that a photograph opened here behaves exactly like a photograph
/// opened anywhere else on the platform — the zoom that follows the fingers, the pan with momentum,
/// the rubber band at the edges, the double tap that zooms to where it landed. The Mac keeps the
/// gesture pair below, because a trackpad pinch and a scroll wheel are a different set of
/// expectations and `UIScrollView` is not there to meet them anyway.
struct MediaViewer: View {
    let attachment: Attachment
    /// Whether to bring `AVKit` and its scrubber, or a picture and a zoom.
    let isVideo: Bool

    /// Who sent it, and when. The two facts the timeline was saying *around* the photo — by
    /// the side it sat on, by the name above it, by the clock beside it — and every one of
    /// them is gone the moment the picture fills the screen. Opened from a search, or from a
    /// scroll back through a year of a chat, a photograph with nothing attached to it is a
    /// photograph you have to close in order to find out whose it is.
    let sender: String
    let timestamp: Date

    @Environment(\.mediaLoader) private var loader
    @Environment(\.dismiss) private var dismiss

    @State private var file: MediaFile?
    @State private var picture: PlatformImage?
    @State private var player: AVPlayer?
    @State private var failed = false

    /// How far along the flick that closes the viewer has come, 0 to 1. The backdrop and the chrome
    /// fade with it, so the conversation comes back into view as the photograph leaves rather than
    /// after it has gone.
    @State private var dismissProgress: CGFloat = 0

    /// Whether the name, the date and the buttons are on screen.
    ///
    /// They are, to begin with — a photograph that opens with no way out and nothing saying whose it
    /// is would be a screen you have to guess at. A single tap takes them away, which is the gesture
    /// every photo viewer on this platform answers and the only way to see a picture with nothing
    /// over it; zooming in takes them away too, because somebody who has zoomed in is looking at the
    /// photograph rather than at the buttons.
    @State private var isChromeVisible = true

    #if os(macOS)
    /// The zoom, and where it is centred, on the Mac — where there is no `UIScrollView` to keep
    /// them. Held across gestures: pinching, letting go and pinching again carries on from where the
    /// last one stopped rather than snapping back to 1×.
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    #endif

    /// As far in as the picture is worth going. Past this there is nothing on the screen but
    /// the grain of whatever the sender's camera happened to record, and a photo that can be
    /// magnified without limit is one you can get lost inside and have to double-tap your way
    /// back out of.
    private static let maximumZoom: CGFloat = 6

    /// Where a double tap lands. Not the maximum: a double tap is "closer", not "as close as this
    /// goes", and a photograph flung to 6× by one tap is a photograph nobody can find their way
    /// around.
    private static let doubleTapZoom: CGFloat = 3

    /// The picture fades as it is dragged away.
    private var backdropOpacity: Double {
        1 - Double(dismissProgress)
    }

    /// The chrome is gone when it has been hidden, and going while the picture is being thrown.
    private var chromeOpacity: Double {
        isChromeVisible ? backdropOpacity : 0
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            content
        }
        // Mac only, and that `#if` is a bug fix rather than tidiness. A sheet on the Mac is a
        // window and shrinks to fit what is in it — a spinner, at first — so it needs a floor.
        // A sheet on the phone is the phone: this floor was 480pt of *minimum* width on a
        // screen 390pt across, so the viewer laid itself out 90pt too wide and centred that
        // overflow. What fell off the two edges was the chrome — the close button on one side,
        // Share on the other — leaving Save marooned in the corner as the only button anybody
        // could see. The picture is bounded by the screen either way; only the demand was
        // impossible.
        #if os(macOS)
        .frame(minWidth: Theme.Size.viewer, minHeight: Theme.Size.viewer)
        #endif
        .overlay(alignment: .top) { title }
        .overlay(alignment: .bottom) { chrome }
        .animation(.smooth(duration: Theme.Timing.chrome), value: isChromeVisible)
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
            //
            // It is held clear of the bottom of the screen, because that is where AVKit draws
            // that scrubber and it is now also where our own buttons are. Two rows of controls
            // in the same strip would mean a play button under a Share button, and the one on
            // top would swallow every press meant for the one beneath it.
            VideoPlayer(player: player)
                .padding(.bottom, chromeHeight)
        } else if let picture {
            zoomable(picture)
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    #if os(iOS)
    /// The photograph, in the scroll view that gives it every behaviour a photograph has on this
    /// platform — see `ZoomableImage`.
    private func zoomable(_ picture: UIImage) -> some View {
        ZoomableImage(image: picture,
                      maximumZoom: Self.maximumZoom,
                      doubleTapZoom: Self.doubleTapZoom,
                      onDismissProgress: { dismissProgress = $0 },
                      onDismiss: { dismiss() },
                      onSingleTap: { isChromeVisible.toggle() },
                      onZoomChanged: { isZoomed in
                          withAnimation(.smooth(duration: Theme.Timing.chrome)) {
                              isChromeVisible = !isZoomed
                          }
                      })
            .ignoresSafeArea()
    }
    #else
    /// The photo on the Mac, with the two gestures a trackpad makes.
    ///
    /// **One gesture, not two**, and that is what makes the pinch work at all. Written as two
    /// `.gesture` modifiers — which is what this was — they are two recognisers competing for
    /// the same events, and the drag wins every time. Composed with `simultaneously`, both see
    /// everything, and the pinch is recognised the moment there is something to recognise.
    private func zoomable(_ picture: NSImage) -> some View {
        Image(nsImage: picture)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(magnification.simultaneously(with: drag))
            .onTapGesture(count: 2) {
                withAnimation(.smooth(duration: 0.25)) {
                    if zoom > 1 {
                        zoom = 1
                        committedZoom = 1
                        pan = .zero
                        committedPan = .zero
                    } else {
                        zoom = Self.doubleTapZoom
                        committedZoom = Self.doubleTapZoom
                    }
                }
            }
            // A single click hides the chrome, as it does on the phone — and waits for the double
            // click to fail first, so zooming in does not also take the buttons away twice.
            .onTapGesture { isChromeVisible.toggle() }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Never below 1×: a photo pinched smaller than the screen it is on floats in
                // the middle of a black rectangle, which is not something anybody wanted. And
                // never past `maximumZoom`, where there is nothing left to look at but the
                // pixels the server sent.
                zoom = min(Self.maximumZoom, max(1, committedZoom * value.magnification))
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

    /// Dragging a magnified photograph moves it under the window. Unmagnified there is nothing to
    /// move — the Mac closes a window with its close button, not by throwing its contents at the
    /// floor, so there is no flick-to-dismiss here.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: committedPan.width + value.translation.width,
                             height: committedPan.height + value.translation.height)
            }
            .onEnded { _ in
                guard zoom > 1 else { return }
                committedPan = pan
            }
    }
    #endif

    /// The way out, and whose photograph this is: a cross in the corner, a name and a date in
    /// the middle.
    ///
    /// Close stays where it has always been and where every full-screen picture on the platform
    /// keeps it — top left, the first thing a thumb finds and the first thing VoiceOver lands
    /// on. It is not one of the things you *do* with a photograph, which is what the row along
    /// the bottom is for; it is how you stop looking at one.
    ///
    /// It is an overlay on the title rather than a third thing in a row with it, and that is
    /// what keeps the name centred on the *screen* instead of on whatever is left of the screen
    /// beside the button.
    private var title: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(sender)
                .font(.headline)

            // The day and the hour, and not the seconds: this is a caption on a photograph,
            // not the forensic timestamp the message's own long-press menu carries. The order
            // of the parts and the word between them are the locale's.
            Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .opacity(0.8)
        }
        // One thing to land on, and one sentence read out. VoiceOver has no use for a name and
        // a date as two separate stops.
        .accessibilityElement(children: .combine)
        .padding(.horizontal, Theme.Size.minimumTapTarget)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            button("xmark", label: Strings.Message.Media.close) { dismiss() }
        }
        .foregroundStyle(.white)
        .background { scrim(from: .top) }
        .opacity(chromeOpacity)
        // Hidden chrome is not merely invisible: a close button faded to nothing that still
        // answered a press would be a trap in the corner of somebody's photograph.
        .allowsHitTesting(isChromeVisible)
    }

    /// Save and share: the things you can do with the photograph, along the bottom, under the
    /// thumb that has to reach them.
    ///
    /// Together in the middle rather than pushed to the two corners. Spread across the width
    /// they were two unrelated things that happened to be in the same strip; gathered, they read
    /// as what they are. It also means the row cannot be torn apart by a screen narrower than
    /// the layout expected, which is exactly how Close and Share once walked off the edges of an
    /// iPhone and left Save standing there alone.
    ///
    /// It is nothing at all until the file arrives, and so is its wash of black: a bar that
    /// darkens the bottom of a picture in order to hold no buttons is a shadow with nothing
    /// casting it.
    private var chrome: some View {
        HStack(spacing: Theme.Spacing.generous) {
            // Both only once the file is actually here. A share sheet offering a file that has
            // not finished downloading would hand the other app an empty URL.
            if let file {
                #if os(iOS)
                button(saveIcon, label: Strings.Message.Media.save) {
                    Task { await saveToPhotos(file) }
                }
                .disabled(saveState != .idle)
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
        .frame(maxWidth: .infinity)
        .frame(height: file == nil ? 0 : chromeHeight)
        .background { if file != nil { scrim(from: .bottom) } }
        // The buttons fade out with the backdrop as the photo is dragged away, rather than
        // hanging in the air over a picture that is already halfway gone.
        .opacity(chromeOpacity)
        .allowsHitTesting(isChromeVisible)
    }

    private func button(_ systemImage: String,
                        label: LocalizedStringResource,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// How tall the bottom row is, and therefore how far the video has to be held up off it.
    private var chromeHeight: CGFloat {
        Theme.Size.minimumTapTarget + Theme.Spacing.generous
    }

    /// The dark wash under the title and under the buttons.
    ///
    /// White glyphs on an arbitrary photograph are white glyphs on a photograph of snow. There
    /// is no bubble here to sit them on and no glass to be had — the HIG keeps Liquid Glass for
    /// the navigation layer, and a floating glass bar over somebody's face would be reading the
    /// face through it. A gradient into black is what every photo viewer has settled on, and it
    /// darkens the picture only where the picture has words over it.
    private func scrim(from edge: UnitPoint) -> some View {
        LinearGradient(colors: [.black.opacity(0.6), .clear],
                       startPoint: edge,
                       endPoint: edge == .top ? .bottom : .top)
            // Up under the notch, or down past the home indicator: a wash that stops at the
            // safe area is a grey band with a hard edge across the top of the picture.
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - Loading

    private func load() async {
        guard let loader else { return }

        do {
            let file = try await loader.file(for: attachment)
            self.file = file

            if isVideo {
                await AudioSession.prepare(for: .playback)
                let player = AVPlayer(url: file.url)
                self.player = player
                // The viewer *is* the video: it starts on opening rather than waiting for a
                // second press on a second play button.
                player.play()
            } else {
                // Read off the file we already have rather than downloading the same bytes a
                // second time through `data(for:)`. The file is the thing `ShareLink` and the
                // photo library need anyway.
                //
                // Decoded off the main actor: a photograph off a modern camera is forty megapixels,
                // and turning those into a bitmap on the actor that is drawing the animation of the
                // viewer opening is a visible hitch in the middle of it.
                let url = file.url
                let decoded = await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return PlatformImage?.none }
                    return PlatformImage(data: data)
                }.value

                guard let decoded else {
                    failed = true
                    return
                }
                picture = decoded
            }
        } catch {
            Log.media.error("the attachment would not open: \(Log.describe(error), privacy: .public)")
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
            Log.media.error("the photo library would not take the file: \(Log.describe(error), privacy: .public)")
            saveState = .failed
        }
    }
    #endif
}

/// The picture, in whatever this platform calls one.
///
/// A `SwiftUI.Image` is not enough here any more: the scroll view that does the zooming needs a
/// `UIImage` to measure — the *aspect ratio* is what decides how the photograph is fitted to the
/// screen, and a `SwiftUI.Image` will not say.
#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif
