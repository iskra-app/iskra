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
final class VideoPlayback: SpeakerClaimant {
    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var failed = false

    /// The decrypted file. Nothing reads this — it is held so that the plaintext stays on
    /// disk while the player is reading it, and disappears when it is not.
    private var file: MediaFile?

    /// The end of the clip, which `AVPlayer` announces and does not act on.
    private var endOfClip: (any NSObjectProtocol)?

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

        // Whatever was playing gives way — another circle, or a voice message: they share the one
        // pair of speakers. It does so now rather than when the download finishes: pressing a second
        // circle should quieten the first immediately, not after however long the network takes.
        Speaker.claim(self)

        do {
            let file = try await loader.file(for: attachment)

            // A second circle — or a voice message — may have been pressed while this one was
            // downloading, and it has already taken the speakers. Coming up now would put two of
            // them on at once, one talking over the other — the thing this is here to prevent.
            guard Speaker.holds(self) else { return }

            self.file = file

            await AudioSession.prepare(for: .playback)

            // Awaited, so — as above — a second press may have landed while the session was
            // waking, and it has the speakers now.
            guard Speaker.holds(self) else { return }

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
            Log.media.error("video would not load: \(Log.describe(error), privacy: .public)")
            failed = true
        }
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
        // holder does when a new one starts, and by then the floor is already the new one —
        // releasing it there would leave the playback that is actually sounding unaccounted for.
        Speaker.release(self)
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
    /// Fill the frame and crop, as a video note's circle wants — or fit inside it, as the media
    /// viewer does, so nothing the sender filmed is cut away.
    var fills = true

    var gravity: AVLayerVideoGravity { fills ? .resizeAspectFill : .resizeAspect }
}

#if os(macOS)
extension VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(player: player)
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
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
    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(player: player)
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

final class PlayerHostView: UIView {
    // `layerClass` overrides UIView's and so must be `class`, not `static`; and because it is
    // `AVPlayerLayer`, `layer` is always one — the cast cannot fail. SwiftLint's blanket bans on
    // `class` members and `as!` know neither fact, so they are turned off for these two lines.
    // swiftlint:disable:next static_over_final_class
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    // swiftlint:disable:next force_cast
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

// `VideoViewer` used to live here — a black sheet with `AVKit`'s controls in it. A video opened
// full-screen is now a page of the media gallery (`MediaPager`), with controls of its own.
