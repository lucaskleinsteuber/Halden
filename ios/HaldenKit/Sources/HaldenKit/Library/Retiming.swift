import AVFoundation
import Foundation

/// Videos played or written at another speed than they were recorded, without touching the
/// original: a slow-motion video with its slow part, and a time-lapse whose early stretches
/// (taken more often) are sped up to the pace of the last one.
public enum Retiming {
    /// A slow-motion video as it plays: the part from `slowFromMs` to `slowToMs` slowed down to
    /// `rate`, the rest at normal speed. The sound slows down with it.
    public static func slowMotion(_ asset: AVAsset, slow: SlowMotion) async throws -> AVMutableComposition {
        let duration = try await asset.load(.duration)
        let durationMs = Int64((duration.seconds * 1000).rounded())
        let fitted = slow.fitted(to: durationMs)
        let composition = try await copy(asset, duration: duration)
        let timescale = CMTimeScale(600)
        let from = CMTime(value: fitted.slowFromMs * Int64(timescale) / 1000, timescale: timescale)
        let to = CMTime(value: fitted.slowToMs * Int64(timescale) / 1000, timescale: timescale)
        let range = CMTimeRange(start: from, end: min(to, duration))
        composition.scaleTimeRange(
            range, toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / fitted.rate))
        return composition
    }

    /// The slow part a slow-motion video starts with, from its frame rate (1/8 at 240 fps).
    public static func standardSlowMotion(of asset: AVAsset, durationMs: Int64?) async -> SlowMotion {
        var rate = 240.0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let fps = try? await track.load(.nominalFrameRate), fps > 0
        {
            rate = Double(fps)
        }
        var duration = durationMs ?? 0
        if duration <= 0, let length = try? await asset.load(.duration) {
            duration = Int64((length.seconds * 1000).rounded())
        }
        return SlowMotion.standard(durationMs: max(duration, 200), frameRate: rate)
    }

    /// A time-lapse at one speed: every stretch (frames of the written video) played `factor`
    /// times faster, so it matches the last, sparsest one.
    public static func timeLapse(
        _ asset: AVAsset, stretches: [(firstFrame: Int, frames: Int, factor: Double)], frameRate: Double
    ) async throws -> AVMutableComposition {
        let duration = try await asset.load(.duration)
        let composition = try await copy(asset, duration: duration)
        // From the end backwards, so the times of the stretches before don't move.
        for stretch in stretches.reversed() where stretch.factor > 1 && stretch.frames > 0 {
            let start = CMTime(value: CMTimeValue(stretch.firstFrame), timescale: CMTimeScale(frameRate))
            let length = CMTime(value: CMTimeValue(stretch.frames), timescale: CMTimeScale(frameRate))
            let range = CMTimeRange(start: start, duration: length)
            guard range.end <= duration else { continue }
            composition.scaleTimeRange(
                range, toDuration: CMTimeMultiplyByFloat64(length, multiplier: 1 / stretch.factor))
        }
        return composition
    }

    /// Writes a composition (as played) into a file: HEVC, with the metadata (place, time) of
    /// `metadataOf`, the original.
    public static func export(_ composition: AVAsset, to destination: URL, metadataOf original: AVAsset? = nil)
        async throws
    {
        let metadata = (try? await original?.load(.metadata)) ?? []
        guard
            let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
                ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw CocoaError(.fileWriteUnknown) }
        session.metadata = metadata
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .mov)
    }

    /// All the asset's video and sound in a composition that can be retimed, oriented like the
    /// original.
    private static func copy(_ asset: AVAsset, duration: CMTime) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let whole = CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard
                let added = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try added.insertTimeRange(whole, of: track, at: .zero)
            added.preferredTransform = try await track.load(.preferredTransform)
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard
                let added = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try added.insertTimeRange(whole, of: track, at: .zero)
        }
        return composition
    }
}
