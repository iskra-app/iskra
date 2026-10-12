import AVFoundation
import Observation
import SwiftUI
import IskraCore
import IskraDesign

#if os(iOS)
import Photos
#endif

/// A room's photos and videos, opened — Telegram's gallery.
///
/// What makes it Telegram's rather than a sheet with a picture in it:
///
/// - **The chrome stays and the pictures move.** Pages slide under a fixed header and footer, with
///   black between them (`Theme.Size.galleryPageGap`), instead of each page carrying its own buttons
///   across the screen with it.
/// - **The header says whose and when**, and how far through the room's pictures you are: "3 из 12".
/// - **The footer** holds the caption, a video's own controls (scrubber, ±15 s, speed), the actions,
///   and a strip of every picture in the room to jump through — the current one drawn wider.
/// - **A picture is never a spinner.** The thumbnail the chat already has is shown at once, filling
///   the screen, and the full file replaces it when it lands.
/// - **One tap clears everything away**, a pinch or a double tap zooms, a flick down closes.
///
/// It fetches each attachment as a *file* (`MediaLoader.file(for:)`) and holds it only while its
/// page exists — let go, and the SDK deletes the decrypted bytes again. In an encrypted room those
/// bytes are somebody's private photograph in plaintext on the disk; they leave with the page.
///
/// Telegram's source was read for how its gallery behaves, and nothing was taken from it: it is
/// GPL, and this is written here.
struct MediaPager: View {
    let items: [MediaItem]

    @State private var model: GalleryModel
    @Environment(\.dismiss) private var dismiss

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        let start = items.indices.contains(startIndex) ? startIndex : 0
        _model = State(initialValue: GalleryModel(currentID: items.isEmpty ? nil : items[start].id))
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == model.currentID } ?? 0
    }

    private var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.backdropOpacity)
                .ignoresSafeArea()

            pager
        }
        #if os(macOS)
        .frame(minWidth: Theme.Size.viewer, minHeight: Theme.Size.viewer)
        #endif
        .overlay(alignment: .top) {
            if let current {
                GalleryHeader(item: current, position: currentIndex + 1, total: items.count,
                              onClose: { dismiss() })
                    .opacity(model.chromeOpacity)
                    .allowsHitTesting(model.isChromeVisible)
            }
        }
        .overlay(alignment: .bottom) {
            if let current {
                GalleryFooter(items: items, current: current, model: model)
                    .opacity(model.chromeOpacity)
                    .allowsHitTesting(model.isChromeVisible)
            }
        }
        .animation(.smooth(duration: Theme.Timing.chrome), value: model.isChromeVisible)
        .environment(model)
        .onChange(of: model.wantsDismiss) { _, wants in
            if wants { dismiss() }
        }
        #if os(macOS)
        // The arrow keys page, as they do in Quick Look.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        #endif
    }

    /// Pages side by side with a gap between them, each the width of the screen, settling one at a
    /// time. Scrolling is switched off while a photograph is zoomed, so a pan across it moves the
    /// picture rather than turning the page.
    private var pager: some View {
        ScrollViewReader { proxy in
            pagerScroll
                // Put on the page it was opened on before anything is drawn. The bound position is
                // meant to do this by itself; a lazy stack that has not measured that far yet does
                // not always oblige.
                .onAppear {
                    if let id = model.currentID { proxy.scrollTo(id) }
                }
        }
    }

    private var pagerScroll: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Theme.Size.galleryPageGap) {
                ForEach(items) { item in
                    GalleryPage(item: item, isCurrent: item.id == model.currentID)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: Binding(get: { model.currentID }, set: { id in
            guard let id, id != model.currentID else { return }
            model.turn(to: id)
        }))
        .scrollIndicators(.hidden)
        .scrollDisabled(model.isZoomed || items.count < 2)
        .ignoresSafeArea()
    }

    #if os(macOS)
    private func step(_ delta: Int) -> KeyPress.Result {
        let next = currentIndex + delta
        guard items.indices.contains(next) else { return .ignored }
        withAnimation(.smooth) { model.turn(to: items[next].id) }
        return .handled
    }
    #endif
}

/// What the pages and the chrome share: which page is in front, whether the chrome is up, how far
/// the flick that closes the viewer has come, and each page's file and player — so the footer can
/// share the picture in front and drive the video in front, while the page owns them.
@MainActor
@Observable
final class GalleryModel {
    var currentID: String?
    var isChromeVisible = true
    var isZoomed = false
    var dismissProgress: CGFloat = 0
    var wantsDismiss = false
    var files: [String: MediaFile] = [:]
    var players: [String: AVPlayer] = [:]

    init(currentID: String?) {
        self.currentID = currentID
    }

    var backdropOpacity: Double { 1 - Double(dismissProgress) }
    var chromeOpacity: Double { isChromeVisible ? backdropOpacity : 0 }

    var currentFile: MediaFile? { currentID.flatMap { files[$0] } }
    var currentPlayer: AVPlayer? { currentID.flatMap { players[$0] } }

    func turn(to id: String) {
        guard id != currentID else { return }
        currentID = id
        isZoomed = false
    }
}

// MARK: - A page

/// One photo or video. The thumbnail the chat already holds is drawn at once and the full file
/// replaces it; a video is fetched only once it is the page in front — a swipe through the room
/// should not download every video in it on the way past.
private struct GalleryPage: View {
    let item: MediaItem
    let isCurrent: Bool

    @Environment(GalleryModel.self) private var model
    @Environment(\.mediaLoader) private var loader

    @State private var picture: PlatformImage?
    @State private var failed = false

    private static let maximumZoom: CGFloat = 6
    private static let doubleTapZoom: CGFloat = 3

    var body: some View {
        ZStack {
            preview

            if let picture {
                zoomable(picture)
            } else if let player = model.players[item.id] {
                VideoSurface(player: player, fills: false)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { model.isChromeVisible.toggle() }
                    // Alongside the pager's own pan, never instead of it: a gesture that claimed
                    // the touch would stop the page turning on a video.
                    .simultaneousGesture(dismissDrag)
                    .overlay { playButton(player) }
            } else if failed {
                Label(Strings.Message.Media.loadFailed, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.white)
            }
        }
        .offset(y: videoDrag)
        .task(id: isCurrent) { await load() }
        .onChange(of: isCurrent) { _, current in
            // A video left behind stops; the one arrived at plays, as Telegram's do.
            guard let player = model.players[item.id] else { return }
            if current { player.play() } else { player.pause() }
        }
        .onDisappear {
            model.players[item.id]?.pause()
            model.players[item.id] = nil
            // And the plaintext leaves the disk with the page.
            model.files[item.id] = nil
        }
    }

    /// The chat's own thumbnail, fitted to the screen, until the real thing is here — and the
    /// still under a video that has not started. Never a bare spinner.
    @ViewBuilder
    private var preview: some View {
        if picture == nil && model.players[item.id] == nil && !failed {
            MediaThumbnail(attachment: item.attachment, size: 800)
                .aspectRatio(item.attachment.aspectRatio ?? 1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if item.isVideo {
                        ProgressView().tint(.white)
                    }
                }
                .allowsHitTesting(false)
        }
    }

    #if os(iOS)
    private func zoomable(_ picture: UIImage) -> some View {
        ZoomableImage(image: picture,
                      maximumZoom: Self.maximumZoom,
                      doubleTapZoom: Self.doubleTapZoom,
                      onDismissProgress: { model.dismissProgress = $0 },
                      onDismiss: { model.wantsDismiss = true },
                      onSingleTap: { model.isChromeVisible.toggle() },
                      onZoomChanged: { isZoomed in
                          model.isZoomed = isZoomed
                          withAnimation(.smooth(duration: Theme.Timing.chrome)) {
                              model.isChromeVisible = !isZoomed
                          }
                      })
            .ignoresSafeArea()
    }
    #else
    private func zoomable(_ picture: NSImage) -> some View {
        MacZoomableImage(image: picture, maximumZoom: Self.maximumZoom, doubleTapZoom: Self.doubleTapZoom)
    }
    #endif

    // MARK: Video

    /// How far a video has been pulled down to close it. A photograph has this from its scroll view
    /// (`ZoomableImage`); a video has nothing underneath to scroll, so it is a drag of its own.
    @State private var videoDrag: CGFloat = 0

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: Theme.Spacing.roomy)
            .onChanged { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                videoDrag = value.translation.height
                model.dismissProgress = min(1, videoDrag / 300)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    model.wantsDismiss = true
                } else {
                    withAnimation(.smooth) {
                        videoDrag = 0
                        model.dismissProgress = 0
                    }
                }
            }
    }

    /// The big play button in the middle of a paused video, and nothing while it plays — the
    /// footer has the pause.
    @ViewBuilder
    private func playButton(_ player: AVPlayer) -> some View {
        GalleryPlayButton(player: player)
    }

    // MARK: Loading

    private func load() async {
        // Keyed on the file, not on the picture: a page scrolled far enough away gives its file up
        // (see `onDisappear`) while its decoded picture may well survive in its state — and a page
        // with a picture and no file is a page with nothing to share. So the file is fetched again,
        // which is the SDK's cache answering, and the picture is decoded only if it is missing.
        guard let loader, model.files[item.id] == nil else { return }
        // Pictures load as soon as their page exists, so the neighbours are ready to swipe to.
        // Videos wait to be in front.
        guard !item.isVideo || isCurrent else { return }

        do {
            let file = try await loader.file(for: item.attachment)
            model.files[item.id] = file

            if item.isVideo {
                guard model.players[item.id] == nil else { return }
                await AudioSession.prepare(for: .playback)
                let player = AVPlayer(url: file.url)
                model.players[item.id] = player
                if isCurrent { player.play() }
            } else if picture == nil {
                // Decoded off the main actor: forty megapixels turned into a bitmap on the actor
                // drawing the page slide is a visible hitch in the middle of it.
                let url = file.url
                let decoded = await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return PlatformImage?.none }
                    return PlatformImage(data: data)
                }.value
                if let decoded { picture = decoded } else { failed = true }
            }
        } catch {
            Log.media.error("the attachment would not open: \(Log.describe(error), privacy: .public)")
            failed = true
        }
    }
}

/// The play button over a paused video. Watches the player itself, so it goes the moment the video
/// starts, however it was started.
private struct GalleryPlayButton: View {
    let player: AVPlayer
    @State private var isPlaying = true

    var body: some View {
        Group {
            if !isPlaying {
                Button {
                    if player.currentItem.map({ $0.currentTime() >= $0.duration }) == true {
                        player.seek(to: .zero)
                    }
                    player.play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: Theme.Size.galleryThumbnailCurrent, height: Theme.Size.galleryThumbnailCurrent)
                        .background(.black.opacity(Theme.Backdrop.plate), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.Message.Media.play))
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: Theme.Timing.chrome), value: isPlaying)
        .task {
            for await status in player.publisher(for: \.timeControlStatus).values {
                isPlaying = status != .paused
            }
        }
    }
}

#if os(macOS)
/// A photograph on the Mac: pinch and scroll on a trackpad, a double click to zoom. There is no
/// `UIScrollView` here to do it, and a Mac does not close a window by throwing its contents away,
/// so there is no flick either.
private struct MacZoomableImage: View {
    let image: NSImage
    let maximumZoom: CGFloat
    let doubleTapZoom: CGFloat

    @Environment(GalleryModel.self) private var model
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(magnification.simultaneously(with: drag))
            .onTapGesture(count: 2) {
                withAnimation(.smooth(duration: 0.25)) {
                    if zoom > 1 {
                        zoom = 1; committedZoom = 1; pan = .zero; committedPan = .zero
                    } else {
                        zoom = doubleTapZoom; committedZoom = doubleTapZoom
                    }
                }
                model.isZoomed = zoom > 1
            }
            .onTapGesture { model.isChromeVisible.toggle() }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(maximumZoom, max(1, committedZoom * value.magnification))
            }
            .onEnded { _ in
                committedZoom = zoom
                model.isZoomed = zoom > 1
                if zoom <= 1 {
                    withAnimation(.smooth) { pan = .zero; committedPan = .zero }
                }
            }
    }

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
}
#endif

// MARK: - The chrome

/// Close on the left, whose and when in the middle, how far through on the right.
private struct GalleryHeader: View {
    let item: MediaItem
    let position: Int
    let total: Int
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(item.sender)
                .font(.headline)
                .lineLimit(1)
            Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .opacity(0.8)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, Theme.Size.minimumTapTarget + Theme.Spacing.generous)
        .padding(.vertical, Theme.Spacing.normal)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(Strings.Message.Media.close))
            .padding(.leading, Theme.Spacing.close)
        }
        .overlay(alignment: .trailing) {
            if total > 1 {
                Text(Strings.Message.Media.counter(position, total))
                    .font(.subheadline.monospacedDigit())
                    .opacity(0.8)
                    .padding(.trailing, Theme.Spacing.roomy)
            }
        }
        .foregroundStyle(.white)
        .background { GalleryScrim(edge: .top) }
    }
}

/// Caption, a video's controls, the actions, and the strip — from the top down, as Telegram stacks
/// them.
private struct GalleryFooter: View {
    let items: [MediaItem]
    let current: MediaItem
    let model: GalleryModel

    var body: some View {
        VStack(spacing: Theme.Spacing.normal) {
            if let caption = current.attachment.caption, !caption.isEmpty {
                ScrollView {
                    Text(caption)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, Theme.Spacing.roomy)
            }

            if let player = model.currentPlayer {
                GalleryVideoControls(player: player)
                    .id(current.id)
                    .padding(.horizontal, Theme.Spacing.roomy)
            }

            if items.count > 1 {
                GalleryThumbnails(items: items, currentID: current.id) { id in
                    withAnimation(.smooth) { model.turn(to: id) }
                }
            }

            GalleryActions(item: current, file: model.currentFile)
        }
        .padding(.top, Theme.Spacing.generous)
        .padding(.bottom, Theme.Spacing.close)
        .foregroundStyle(.white)
        .background { GalleryScrim(edge: .bottom) }
    }
}

/// The scrubber with the time gone and the time left, and the row under it: back fifteen seconds,
/// play or pause, forward fifteen, and the speed.
private struct GalleryVideoControls: View {
    let player: AVPlayer

    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var rate: Float = 1

    private static let rates: [Float] = [1, 1.5, 2, 0.5]
    private static let skip: Double = 15

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Slider(value: Binding(get: { elapsed }, set: { elapsed = $0 }),
                   in: 0...max(duration, 0.1)) { editing in
                isScrubbing = editing
                if !editing { seek(to: elapsed) }
            }
            .tint(.white)

            HStack {
                Text(Self.format(elapsed))
                Spacer()
                Text("−" + Self.format(max(0, duration - elapsed)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.8)

            HStack(spacing: Theme.Spacing.generous) {
                Button { cycleRate() } label: {
                    Text(verbatim: Self.rateLabel(rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: Theme.Size.minimumTapTarget, minHeight: Theme.Size.minimumTapTarget)
                }
                Spacer()
                control("gobackward.15", label: Strings.Message.Media.skipBack) { seek(to: elapsed - Self.skip) }
                control(isPlaying ? "pause.fill" : "play.fill",
                        label: isPlaying ? Strings.Message.Media.pause : Strings.Message.Media.play) { togglePlay() }
                control("goforward.15", label: Strings.Message.Media.skipForward) { seek(to: elapsed + Self.skip) }
                Spacer()
                Color.clear.frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
            }
            .buttonStyle(.plain)
        }
        .task { await follow() }
    }

    private func control(_ symbol: String, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                .contentShape(.circle)
        }
        .accessibilityLabel(Text(label))
    }

    /// Keeps the scrubber and the button in step with the player, ten times a second — and leaves
    /// the scrubber alone while a finger is on it.
    private func follow() async {
        rate = player.defaultRate == 0 ? 1 : player.defaultRate
        while !Task.isCancelled {
            if let item = player.currentItem {
                let total = item.duration.seconds
                if total.isFinite { duration = total }
                if !isScrubbing {
                    let now = item.currentTime().seconds
                    if now.isFinite { elapsed = now }
                }
            }
            isPlaying = player.timeControlStatus != .paused
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, elapsed >= duration - 0.1 { player.seek(to: .zero) }
            player.playImmediately(atRate: rate)
        }
    }

    private func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration)
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(1))))×"
    }

    static func format(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: .minuteSecond))
    }
}

/// Every picture in the room in a row of small tiles, the current one wider — Telegram's strip
/// along the foot of its gallery. A tap goes there.
private struct GalleryThumbnails: View {
    let items: [MediaItem]
    let currentID: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Theme.Spacing.withinRun) {
                    ForEach(items) { item in
                        let isCurrent = item.id == currentID
                        Button { onSelect(item.id) } label: {
                            MediaThumbnail(attachment: item.attachment, size: 120)
                                .frame(width: isCurrent ? Theme.Size.galleryThumbnailCurrent : Theme.Size.galleryThumbnail.width,
                                       height: Theme.Size.galleryThumbnail.height)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Spacing.tight, style: .continuous))
                                .opacity(isCurrent ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(Text(item.isVideo ? Strings.Message.Media.video : Strings.Message.Media.photo))
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Theme.Spacing.roomy)
            }
            .scrollIndicators(.hidden)
            .frame(height: Theme.Size.galleryThumbnail.height)
            .animation(.smooth(duration: Theme.Timing.chrome), value: currentID)
            .onChange(of: currentID, initial: true) { _, id in
                withAnimation(.smooth) { scroll.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Share and save — the things you do with the picture in front. Only once its file is here: a
/// share sheet handed a file still on its way gives the other app an empty URL.
private struct GalleryActions: View {
    let item: MediaItem
    let file: MediaFile?

    private enum SaveState { case idle, saved, failed }
    @State private var saveState: SaveState = .idle

    var body: some View {
        HStack {
            if let file {
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .accessibilityLabel(Text(Strings.Message.Media.share))

                Spacer()

                #if os(iOS)
                Button {
                    Task { await save(file) }
                } label: {
                    Image(systemName: saveIcon)
                        .font(.title3)
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .contentShape(.circle)
                }
                .disabled(saveState != .idle)
                .accessibilityLabel(Text(Strings.Message.Media.save))
                #endif
            }
        }
        .buttonStyle(.plain)
        .frame(height: Theme.Size.minimumTapTarget)
        .padding(.horizontal, Theme.Spacing.normal)
        // A new picture in front can be saved again.
        .onChange(of: item.id) { saveState = .idle }
    }

    private var saveIcon: String {
        switch saveState {
        case .idle: "arrow.down.circle"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    #if os(iOS)
    /// Into the photo library, with `addOnly` permission: this app has no business reading
    /// somebody's library in order to put one file in it.
    private func save(_ file: MediaFile) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed
            return
        }
        do {
            let url = file.url
            let isVideo = item.isVideo
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saveState = .saved
        } catch {
            Log.media.error("the photo library would not take the file: \(Log.describe(error), privacy: .public)")
            saveState = .failed
        }
    }
    #endif
}

/// The dark wash under the header and the footer: white on an arbitrary photograph is white on a
/// photograph of snow, and glass over somebody's face is reading the face through it.
private struct GalleryScrim: View {
    let edge: VerticalEdge

    var body: some View {
        LinearGradient(colors: [.black.opacity(0.6), .clear],
                       startPoint: edge == .top ? .top : .bottom,
                       endPoint: edge == .top ? .bottom : .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The picture, in whatever this platform calls one — the scroll view that zooms it needs a
/// `UIImage` to measure.
#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif
