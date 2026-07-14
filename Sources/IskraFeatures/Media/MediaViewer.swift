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

    /// Whether two fingers are on the picture right now.
    ///
    /// The drag and the pinch see the same touches — they have to, or neither works (see
    /// `zoomable`) — and a pinch moves its centroid about as freely as a swipe does. Without
    /// this the two fingers spreading on an unzoomed photo would also be read as a flick
    /// downwards, and the viewer would close in the middle of the zoom that was meant to open
    /// it up. So while a pinch is under way, the drag moves nothing; once the picture *is*
    /// magnified, the same drag becomes a pan and the question stops arising.
    ///
    /// It is only ever read inside `onChanged`, and that is the whole point of it. Read at the
    /// *end* of the drag it would be a lie: both gestures end when the fingers lift, the pinch's
    /// `onEnded` runs first and clears this, and the drag then looks at a flag that says no
    /// pinch happened — which is exactly the case it was added to catch. So nothing at the end
    /// asks it anything. See `drag`.
    @State private var isPinching = false

    /// How far down it has to go to count as "close it". Short of that it springs back, which is
    /// what tells the user the gesture exists.
    private static let dismissDistance: CGFloat = 120

    /// As far in as the picture is worth going. Past this there is nothing on the screen but
    /// the grain of whatever the sender's camera happened to record, and a photo that can be
    /// magnified without limit is one you can get lost inside and have to double-tap your way
    /// back out of.
    private static let maximumZoom: CGFloat = 6

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
    ///
    /// **One gesture, not two**, and that is what makes the pinch work at all. Written as two
    /// `.gesture` modifiers — which is what this was — they are two recognisers competing for
    /// the same touches, and the drag wins every time: a pinch begins with one finger landing
    /// like any other touch, the drag claims the sequence there and then, and the second finger
    /// arrives to find the magnification never started. The photo could be dragged and could
    /// not be zoomed, and nothing about the code said so. Composed with `simultaneously`, both
    /// see every touch, and the pinch is recognised the moment there is something to recognise.
    private func zoomable(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(magnification.simultaneously(with: drag))
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
                isPinching = true
                // Never below 1×: a photo pinched smaller than the screen it is on floats in
                // the middle of a black rectangle, which is not something anybody wanted. And
                // never past `maximumZoom`, where there is nothing left to look at but the
                // pixels the server sent.
                zoom = min(Self.maximumZoom, max(1, committedZoom * value.magnification))
            }
            .onEnded { _ in
                isPinching = false
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
                } else if !isPinching {
                    // Downward only. Dragging a photo *up* off the screen is not a gesture
                    // anything else in the system honours, and answering it here would mean the
                    // picture sliding away from a flick that was meant to scroll something.
                    dragOffset = max(0, value.translation.height)
                }
            }
            // What decides this is `dragOffset` and not `value.translation`, and the difference
            // is the whole fix. `translation` is what the fingers did; `dragOffset` is what this
            // gesture was *allowed* to do with it — `onChanged` above refuses to move the
            // picture while a pinch is under way, so a pinch whose centroid wandered 200pt down
            // the screen leaves `dragOffset` at nothing and closes nothing. The end of the drag
            // therefore asks no questions about pinching; it only reads how far the photo
            // actually travelled, which is the thing the user can see.
            //
            // And `dragOffset` returns to zero on every path but the one that dismisses. It used
            // to be left where it lay when a drag turned into a pinch, and the photograph stayed
            // sitting 80pt down the screen with the conversation showing through behind it for
            // as long as the viewer was open.
            .onEnded { _ in
                if zoom > 1 {
                    committedPan = pan
                } else if dragOffset > Self.dismissDistance {
                    dismiss()
                    return
                }

                withAnimation(.smooth) { dragOffset = 0 }
            }
    }

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
        .opacity(backdropOpacity)
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
        .opacity(backdropOpacity)
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
                guard let data = try? Data(contentsOf: file.url),
                      let image = Image(mediaData: data) else {
                    failed = true
                    return
                }
                self.image = image
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
