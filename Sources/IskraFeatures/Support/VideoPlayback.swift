import AVKit
import SwiftUI
import IskraCore
import IskraDesign

/// Playing one video: the download, the player, and the file underneath both.
///
/// The timeline shows a *thumbnail* — scrolling past a video must never fetch the video —
/// so nothing is downloaded until the user asks. This is what "asks" turns into: fetch the
/// file, hand its URL to `AVPlayer`, and keep the `MediaFile` alive for exactly as long as
/// playback lasts. Let go of it and the SDK deletes the decrypted bytes from disk, which is
/// the point of holding it at all.
@MainActor
@Observable
final class VideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var failed = false

    /// The decrypted file. Nothing reads this — it is held so that the plaintext stays on
    /// disk while the player is reading it, and disappears when it is not.
    private var file: MediaFile?

    /// The end of the clip, which `AVPlayer` announces and does not act on.
    private var endOfClip: (any NSObjectProtocol)?

    /// Whoever is playing, out of every video note in every open conversation. One at a
    /// time: two circles talking over each other is noise, and the second one is never the
    /// one being listened to.
    ///
    /// Weak, and it has to be — a strong reference here would keep the *decrypted file* of
    /// every note the user ever pressed alive for as long as the app runs, since that is
    /// what a `VideoPlayback` is holding. Anything that stops holding its player has stopped
    /// playing by definition, so there is nothing to remember about it.
    ///
    /// Static rather than an environment object, because this is a fact about the device —
    /// it has one pair of speakers — and not about any view hierarchy.
    @MainActor
    private static weak var current: VideoPlayback?

    var isPlaying: Bool { player != nil }

    /// Fetches the video and starts it. Playing something already playing is a no-op, so a
    /// second tap on a circle mid-play does not download it twice.
    ///
    /// `stopsAtEnd` is what a circle wants and a full-screen player does not: a video note
    /// that has run out has nothing more to say and goes back to being a still, while a video
    /// somebody opened stays open on its last frame, with the scrubber they may want to drag.
    func play(_ attachment: Attachment, using loader: MediaLoader?, stopsAtEnd: Bool = false) async {
        guard player == nil, !isLoading, let loader else { return }

        isLoading = true
        failed = false
        defer { isLoading = false }

        // Whatever was playing gives way, and it does so now rather than when the download
        // finishes: pressing a second circle should quieten the first one immediately, not
        // after however long the network takes.
        Self.current?.stop()
        Self.current = self

        do {
            let file = try await loader.file(for: attachment)

            // A second circle may have been pressed while this one was downloading, and it
            // has already taken the speakers. Coming up now would put two of them on screen
            // at once, one of them talking over the other — the thing this is here to prevent.
            guard Self.current === self else { return }

            self.file = file

            Self.prepareToBeHeard()

            let player = AVPlayer(url: file.url)
            if stopsAtEnd {
                endOfClip = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: player.currentItem,
                    queue: .main
                ) { [weak self] _ in
                    // The queue is the main one, so this really is the main actor — the
                    // compiler simply has no way to know that from a notification block.
                    MainActor.assumeIsolated { self?.stop() }
                }
            }

            // The growth is animated *here*, at the change itself, and not with an
            // `.animation(value:)` on the circle. It was, and it did nothing: the size and the
            // content change in the same breath — the thumbnail is replaced by the video — and
            // a view swapped for a different one is inserted at its final size rather than
            // grown into it. Animating the transaction that makes the change is what carries
            // the layout around it along.
            withAnimation(Theme.Timing.videoNote) {
                self.player = player
            }
            player.play()
        } catch {
            // The video would not come down. Say so on the bubble; there is nothing here
            // worth an alert, and nothing the user can do about it but try again.
            Log.media.error("video would not load: \(String(describing: error), privacy: .public)")
            failed = true
        }
    }

    /// Makes the phone willing to make a noise.
    ///
    /// Two separate things would otherwise silence a video message, and both of them look
    /// exactly like a broken player. The app's default category is `soloAmbient`, which the
    /// ring switch mutes — a video somebody pressed play on is not ambient. And recording a
    /// video note leaves the session in `playAndRecord`, whose default output is the
    /// *earpiece*: the sound is there, playing into the side of the phone, and to the user
    /// holding it at arm's length there is no sound at all.
    ///
    /// The result is logged rather than swallowed. A `try?` here was worth nothing: if this
    /// call fails the only symptom is silence, which is the very thing being debugged.
    private static func prepareToBeHeard() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Log.media.error("the audio session refused playback: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    /// Stops, and lets the bytes go.
    func stop() {
        player?.pause()

        // Settling back is the same change in reverse, and gets the same spring. Only the
        // player is inside the animation: the file and the observer are bookkeeping, and
        // animating a transaction that touches them would tell SwiftUI nothing.
        withAnimation(Theme.Timing.videoNote) {
            player = nil
        }
        file = nil

        if let endOfClip {
            NotificationCenter.default.removeObserver(endOfClip)
            self.endOfClip = nil
        }

        // Only if we are still the one holding the floor. Stopping is also what the *previous*
        // note does when a new one starts, and by then `current` is already the new one —
        // clearing it there would leave the note that is actually playing unaccounted for, and
        // the one after that would not know to silence it.
        if Self.current === self {
            Self.current = nil
        }
    }
}

/// The moving picture, and nothing else: no scrubber, no buttons, no chrome.
///
/// `AVKit`'s own `VideoPlayer` cannot be used here — it brings its transport controls with
/// it, and a play button and a progress bar drawn across a 200pt circle is not a video
/// message. So the layer is hosted directly. The full-screen viewer, which *wants* those
/// controls, uses `VideoPlayer` instead.
struct VideoSurface {
    let player: AVPlayer
}

#if os(macOS)
extension VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerHostView { PlayerHostView(player: player) }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.actions = PlayerHostView.noAnimations
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }
}
#else
extension VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerHostView { PlayerHostView(player: player) }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.actions = PlayerHostView.noAnimations
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }
}
#endif

extension PlayerHostView {
    /// Why the circle grew in jerks.
    ///
    /// Core Animation animates a layer's own bounds and position by default, on its own
    /// quarter-second curve. So while SwiftUI was easing the *view* from 200pt to full width,
    /// the video layer inside it was separately easing itself towards wherever the view had
    /// got to a moment ago — two animations chasing each other, each restarting every time
    /// SwiftUI committed the next step of the spring. What that looks like is stuttering.
    ///
    /// Turning the layer's implicit animations off leaves exactly one animation in charge.
    /// The layer then simply *is* whatever size the view is on that frame, which is what it
    /// should have been doing all along.
    static let noAnimations: [String: any CAAction] = [
        "bounds": NSNull(),
        "position": NSNull()
    ]
}

/// An ordinary video, opened. Full screen, black, with the system's own controls — a video
/// the user has chosen to watch deserves a scrubber, and this is the one place in the app
/// where `AVKit` is allowed to draw its own.
struct VideoViewer: View {
    let attachment: Attachment

    @Environment(\.mediaLoader) private var loader
    @Environment(\.dismiss) private var dismiss

    @State private var playback = VideoPlayback()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playback.player {
                VideoPlayer(player: player)
            } else if playback.failed {
                Label(Strings.Message.Media.loadFailed, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(minWidth: Theme.Size.viewer, minHeight: Theme.Size.viewer)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .padding(Theme.Spacing.close)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(Theme.Spacing.normal)
            .accessibilityLabel(Text(Strings.Message.Media.close))
        }
        .task {
            // The viewer is the video, so it starts the moment it opens rather than
            // waiting for a second press on a second play button.
            await playback.play(attachment, using: loader)
        }
        .onDisappear {
            playback.stop()
        }
    }
}
