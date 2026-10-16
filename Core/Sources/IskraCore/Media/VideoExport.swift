import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Where copies of a video are made, and the one copy that is made without re-encoding: the same
/// pictures and sound with every piece of metadata left behind.
///
/// A copy keeps the original's name — the person it goes to sees the name it had, exactly as they
/// would have without this — with the extension of whatever container it ended up in, in a folder
/// of its own so two videos called the same thing cannot meet. The caller owns it and hands it to
/// `discard` once it has been sent: in an encrypted room it is plaintext video sitting in a
/// temporary directory. `VideoTranscoder` makes its copies here too.
enum VideoExport {
    enum Failure: Error {
        case unreadable
        case exportFailed
        case metadataRemained
    }

    /// The tracks *moved*, not re-encoded — a passthrough export — so a minute of 4K is a few
    /// seconds of copying, and the picture is exactly the picture. What is left behind: every piece
    /// of movie-level metadata (the location, the camera, the capture date, the author), every
    /// track's own, and every track that is neither picture nor sound — the timed metadata an
    /// iPhone records beside the video is data about the scene. The result is read back and
    /// refused if anything is left.
    static func stripped(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw Failure.unreadable }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
            // The rotation a phone records a portrait clip with. It is how the video is shown, not
            // a fact about who shot it, and without it every portrait video arrives on its side.
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        guard !composition.tracks(withMediaType: .video).isEmpty else { throw Failure.unreadable }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw Failure.exportFailed }
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true

        let fileType = outputType(for: url, supported: session.supportedFileTypes)
        let output = try copyURL(for: url, as: fileType)
        do {
            try await session.export(to: output, as: fileType)
            guard try await MetadataStripper.isClean(video: output) else { throw Failure.metadataRemained }
        } catch {
            discard(output)
            throw error
        }
        return output
    }

    /// A place for a copy of `url` as `fileType`: the original's name, in a fresh folder.
    static func copyURL(for url: URL, as fileType: AVFileType) throws -> URL {
        let folder = URL.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = UTType(fileType.rawValue)?.preferredFilenameExtension ?? url.pathExtension
        return folder.appending(component: "\(stem).\(suffix)")
    }

    /// Removes a copy made here, and the folder it was made in.
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The container the video came in, when the export can write it — a QuickTime file stays one,
    /// so a clip that plays today plays tomorrow — and MP4 otherwise.
    private static func outputType(for url: URL, supported: [AVFileType]) -> AVFileType {
        let own = UTType(filenameExtension: url.pathExtension).map { AVFileType($0.identifier) }
        if let own, supported.contains(own) { return own }
        if supported.contains(.mp4) { return .mp4 }
        return supported.first ?? .mov
    }
}
