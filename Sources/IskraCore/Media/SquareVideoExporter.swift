import Foundation
import AVFoundation

/// Crops a recorded clip to a perfect square, and blacks out the corners.
///
/// This is not cosmetic. A video note is recognised on the receiving side by being
/// exactly square and under a minute — see `VideoNote` for why it cannot simply be
/// tagged with a custom field. So "roughly square" is not good enough: if the file
/// comes off the camera as 1080×1920 and we merely *display* it in a circle, everyone
/// else sees a portrait video, and our own client would not recognise it on the way
/// back either. The bytes have to be square.
///
/// ## Why the corners are painted out rather than merely hidden
///
/// The circle the app draws is a mask on a *player*: the pixels outside it are still in
/// the file, and every other Matrix client shows them. What is in those corners is the
/// room the person is sitting in — the part of the frame they never looked at, because
/// the viewfinder they were framing themselves in was round. So the corners go into the
/// file black, and what was never meant to be sent is not sent.
///
/// They are black and not transparent because H.264 in an MP4 carries no alpha channel,
/// and the one format that would (HEVC with alpha) plays almost nowhere outside Apple.
/// A colour is the only option a corner has.
public enum SquareVideoExporter {
    public enum Failure: Error {
        case noVideoTrack
        case exportFailed(Error?)
    }

    /// The blacked-out corners are cut by a circle slightly *wider* than the frame, so the
    /// black never reaches the edge of the circle the app itself masks the player with.
    ///
    /// If the two circles were the same size they would fight: the video is scaled to
    /// whatever diameter the bubble gives it, the edges of both are antialiased, and the
    /// black would show as a dark fringe biting into our own mask. Oversizing it puts the
    /// black strictly out in the corners, where nothing of ours ever draws — the four
    /// corner points sit at 0.707 of the side from the centre, so a circle of radius 0.52
    /// still leaves them well covered.
    private static let maskOvershoot: CGFloat = 1.04

    /// Centre-crops `url` to a square, paints its corners black, and writes a new file.
    /// Returns its location.
    ///
    /// The caller owns the result and should delete it once it has been sent: in an
    /// encrypted room this is plaintext video sitting in a temporary directory.
    public static func square(_ url: URL, side: Int = VideoNote.captureDimension) async throws -> URL {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)

        // The camera records in its own orientation and describes the rest with a
        // transform. Applying it first means we crop what the user actually saw, not
        // what the sensor happened to store.
        let oriented = naturalSize.applying(preferredTransform)
        let width = abs(oriented.width)
        let height = abs(oriented.height)
        let edge = min(width, height)

        let output = CGSize(width: CGFloat(side), height: CGFloat(side))
        let scale = CGFloat(side) / edge

        // Centre the square on the middle of the frame, then scale it to the output.
        let centring = CGAffineTransform(translationX: -(width - edge) / 2 * scale,
                                         y: -(height - edge) / 2 * scale)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(preferredTransform
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                            .concatenating(centring),
                           at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = output
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        composition.animationTool = corners(over: output)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed(nil)
        }
        session.videoComposition = composition

        let destination = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mp4")

        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            throw Failure.exportFailed(error)
        }

        return destination
    }

    /// The black that fills everything outside the circle: one square path with a circular
    /// hole cut in it by the even-odd rule, laid over the video and rendered into every frame.
    ///
    /// The layers are handed to `AVVideoCompositionCoreAnimationTool`, which draws them for
    /// each frame during the export. Note that the video layer is *not* added to the parent
    /// here — `postProcessingAsVideoLayer:in:` does that itself, and adding it twice puts the
    /// picture on top of the mask.
    private static func corners(over size: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let bounds = CGRect(origin: .zero, size: size)

        let video = CALayer()
        video.frame = bounds

        let parent = CALayer()
        parent.frame = bounds
        parent.addSublayer(video)

        let diameter = min(size.width, size.height) * maskOvershoot
        let hole = CGRect(x: (size.width - diameter) / 2,
                          y: (size.height - diameter) / 2,
                          width: diameter,
                          height: diameter)

        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: hole)

        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        parent.addSublayer(mask)

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}
