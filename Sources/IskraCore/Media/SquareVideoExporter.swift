import Foundation
import AVFoundation

/// Crops a recorded clip to a perfect square.
///
/// This is not cosmetic. A video note is recognised on the receiving side by being
/// exactly square and under a minute — see `VideoNote` for why it cannot simply be
/// tagged with a custom field. So "roughly square" is not good enough: if the file
/// comes off the camera as 1080×1920 and we merely *display* it in a circle, everyone
/// else sees a portrait video, and our own client would not recognise it on the way
/// back either. The bytes have to be square.
public enum SquareVideoExporter {
    public enum Failure: Error {
        case noVideoTrack
        case exportFailed(Error?)
    }

    /// Centre-crops `url` to a square and writes a new file. Returns its location.
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
}
