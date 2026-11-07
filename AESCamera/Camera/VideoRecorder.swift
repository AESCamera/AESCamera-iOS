@preconcurrency import AVFoundation
import AESCore
import Foundation
import UniformTypeIdentifiers

enum CameraError: LocalizedError {
    case unavailable
    case nothingRecorded
    case photoFailed
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The camera isn't available."
        case .nothingRecorded: "Nothing was recorded."
        case .photoFailed: "The photo couldn't be taken."
        case .recordingFailed(let reason): "The recording failed: \(reason)"
        }
    }
}

/// Encrypt-while-recording: `AVAssetWriter` in segment output mode has no output file.
/// It hands each fragmented-MP4 segment (init segment, then one per second) to its
/// delegate as `Data` in memory, and every segment goes straight through `EncvWriter`
/// (AES-CTR + HMAC) into the `.encv`. No plaintext touches the disk.
///
/// The concatenated segments form a valid fragmented MP4, so a recording killed half
/// way still plays up to its last complete fragment (unverified, no trailer).
///
/// Failure policy: any writer or encryption error aborts the recording and deletes the
/// partial (ciphertext only) file. There is no file-based fallback.
///
/// `appendVideo`/`appendAudio`/`finish` must be called from one serial queue (the
/// capture data queue). Segment callbacks may arrive on AVFoundation's own threads.
final class VideoRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let url: URL

    private let encv: EncvWriter
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var segmentError: Error?
    private var started = false
    private var finished = false

    /// Called once with the first video frame (for the thumbnail), on the data queue.
    var onFirstFrame: ((CVPixelBuffer) -> Void)?

    init(
        url: URL,
        secret: Secret,
        salt: [UInt8]?,
        videoSettings: [String: Any],
        audioSettings: [String: Any]?,
        transform: CGAffineTransform
    ) throws {
        self.url = url
        encv = try EncvWriter(
            url: url, secret: secret, header: EncvHeader(container: .fragmentedMP4),
            salt: salt, attributes: FileProtection.recordingAttributes
        )

        writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.segmentFriendly(videoSettings))
        videoInput.expectsMediaDataInRealTime = true
        // Rotation lives in the track matrix for fMP4 (header rotation stays 0).
        videoInput.transform = transform

        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }
        super.init()

        writer.delegate = self
        guard writer.canAdd(videoInput) else {
            encv.abort()
            throw CameraError.recordingFailed("video settings rejected")
        }
        writer.add(videoInput)
        if let audioInput, writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
    }

    /// One-second keyframe interval (segments must start on a sync sample; also makes
    /// seeking cheap) and no B-frames (simplest for every player, Android included).
    private static func segmentFriendly(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 1
        compression[AVVideoAllowFrameReorderingKey] = false
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finished, segmentErrorValue == nil else { return }
        if !started {
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.initialSegmentStartTime = start
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: start)
            started = true
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                onFirstFrame?(pixelBuffer)
            }
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard started, !finished, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Stops recording. On success the `.encv` has its final header and trailer.
    func finish(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard !finished else { return }
        finished = true
        guard started, writer.status == .writing else {
            if started { writer.cancelWriting() }
            encv.abort()
            completion(.failure(writer.error ?? CameraError.nothingRecorded))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            // The last segment was delivered before this completion runs.
            do {
                if let segmentErrorValue { throw segmentErrorValue }
                guard writer.status == .completed else {
                    throw writer.error ?? CameraError.recordingFailed("writer status \(writer.status.rawValue)")
                }
                try lock.withLock {
                    guard encv.plaintextBytesWritten > 0 else { throw CameraError.nothingRecorded }
                    try encv.finish(rotationDegrees: 0)
                }
                FileProtection.markComplete(url)
                completion(.success(url))
            } catch {
                lock.withLock { encv.abort() }
                completion(.failure(error))
            }
        }
    }

    /// Discards the recording (ciphertext only) without finishing it.
    func cancel() {
        guard !finished else { return }
        finished = true
        if started { writer.cancelWriting() }
        lock.withLock { encv.abort() }
    }

    private var segmentErrorValue: Error? {
        lock.withLock { segmentError }
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.withLock {
            guard segmentError == nil else { return }
            do {
                try encv.write(segmentData)
            } catch {
                segmentError = error
            }
        }
    }
}
