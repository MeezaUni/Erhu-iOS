import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct MotionVideoInfo {
    let codec: FourCharCode
    let width: Int
    let height: Int
    let duration: Double
    let frameTimes: [Double]
    let colors: [String: String]
}

struct MotionCompressionPreview: Identifiable {
    let id = UUID()
    let albumId: Int64
    let title: String
    let original: URL
    let candidate: URL
    let originalBytes: Int64
    let candidateBytes: Int64
    let modified: Date
    var saving: Int64 { originalBytes - candidateBytes }
}

enum MotionCompressionError: LocalizedError {
    case unsupported, invalid, noSaving, changed
    var errorDescription: String? {
        switch self {
        case .unsupported: "This cover isn’t supported for compression. Use a square SDR H.264 cover, up to two minutes long. Your original is unchanged."
        case .invalid: "The compressed video did not pass playback, frame, colour or timing checks. Your original is unchanged."
        case .noSaving: "Compression did not make this cover smaller. Your original is unchanged."
        case .changed: "This cover changed while compression was running. Try again."
        }
    }
}

/// Explicit, lossy HEVC compression. A candidate is decoded and checked before preview;
/// publication still requires the listener's separate Keep compressed action.
enum MotionCoverCompressor {
    static func inspect(_ url: URL) async throws -> MotionVideoInfo {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.isEmpty else { throw MotionCompressionError.unsupported }
        let track = video[0]
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first, duration.isFinite, duration > 0, duration <= 120,
              transform == .identity else { throw MotionCompressionError.unsupported }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary
        var colors: [String: String] = [:]
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            if let value = extensions[key] { colors[key as String] = String(describing: value) }
        }
        colors["FullRangeVideo"] = ((extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? NSNumber)?.boolValue ?? false) ? "true" : "false"
        guard colors[kCMFormatDescriptionExtension_TransferFunction as String] == (kCVImageBufferTransferFunction_ITU_R_709_2 as String),
              dimensions.width == dimensions.height, dimensions.width > 0, dimensions.width <= 1920 else { throw MotionCompressionError.unsupported }
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        guard abs(presentation.width - Double(dimensions.width)) < 0.01,
              abs(presentation.height - Double(dimensions.height)) < 0.01 else { throw MotionCompressionError.unsupported }
        // This is real frame decoding, not merely checking that an MP4 header exists.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MotionCompressionError.invalid }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MotionCompressionError.invalid }
        var times: [Double] = []
        do {
            while true {
                try Task.checkCancellation()
                guard let time = autoreleasepool(invoking: { () -> Double? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    guard CMSampleBufferGetImageBuffer(sample) != nil else { return .nan }
                    return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                }) else { break }
                guard time.isFinite, times.count < 7500 else { throw MotionCompressionError.invalid }
                times.append(time)
            }
        } catch { reader.cancelReading(); throw error }
        guard reader.status == .completed, !times.isEmpty else { throw reader.error ?? MotionCompressionError.invalid }
        times.sort()
        let first = times[0]
        times = times.map { $0 - first }
        return MotionVideoInfo(codec: CMFormatDescriptionGetMediaSubType(description), width: Int(dimensions.width), height: Int(dimensions.height), duration: duration, frameTimes: times, colors: colors)
    }

    static func validate(_ original: MotionVideoInfo, _ candidate: MotionVideoInfo) throws {
        guard candidate.codec == kCMVideoCodecType_HEVC, original.width == candidate.width, original.height == candidate.height,
              original.colors == candidate.colors, abs(original.duration - candidate.duration) < 0.04,
              original.frameTimes.count == candidate.frameTimes.count,
              zip(original.frameTimes, candidate.frameTimes).allSatisfy({ abs($0 - $1) <= 0.002 }) else { throw MotionCompressionError.invalid }
    }

    static func prepare(_ original: URL, candidate: URL) async throws {
        let before = try await inspect(original)
        guard before.codec == kCMVideoCodecType_H264 else { throw MotionCompressionError.unsupported }
        let asset = AVURLAsset(url: original)
        guard AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPresetHEVCHighestQuality),
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else { throw MotionCompressionError.unsupported }
        exporter.outputURL = candidate; exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: exporter.error ?? MotionCompressionError.invalid)
                    }
                }
            }
        }, onCancel: { exporter.cancelExport() })
        try Task.checkCancellation()
        let after = try await inspect(candidate)
        try validate(before, after)
        let a = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let b = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard b > 0, b < a else { throw MotionCompressionError.noSaving }
    }
}
