@preconcurrency import AVFoundation
import AESCore
import Observation
import SwiftUI
import UIKit

/// Plays Android recordings (`.encv` container 1, MPEG-2 TS) without AVPlayer, which
/// can't play raw TS. Bytes are decrypted on the fly (CTR at any offset), demuxed, turned
/// into `CMSampleBuffer`s, and rendered by a display layer and an audio renderer under one
/// render synchronizer. Nothing decrypted touches the disk.
///
/// MediaRecorder's TS has no PCR, so — as Android's `PtsSeekableTsExtractor` does — the
/// duration comes from the first and last PES timestamps and seeking maps time to bytes
/// linearly, then starts at the next keyframe.
@MainActor @Observable
final class TSPlayer {
    let duration: Double
    let rotationDegrees: Int
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var failure: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private let audioRenderer = AVSampleBufferAudioRenderer()
    @ObservationIgnored private let feeder: TSFeeder
    @ObservationIgnored private var timeObserver: Any?
    /// Set once the feeder has queued the last sample: the time playback ends at.
    @ObservationIgnored private var endTime: Double?

    init(reader: EncvReader) async throws {
        let range = try await Task.detached {
            try TSTimeline.range(length: reader.plaintextLength) { try reader.read(at: $0, count: $1) }
        }.value
        guard let range else { throw CameraError.recordingFailed("no timestamps found") }
        duration = Double(range.last - range.first) / 90_000 + 1.0 / 30
        rotationDegrees = reader.header.rotationDegrees
        displayLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        feeder = TSFeeder(
            reader: reader, firstPTS: range.first, duration: duration,
            video: displayLayer.sampleBufferRenderer, audio: audioRenderer
        )
        feeder.onEnd = { [weak self] end in Task { @MainActor in self?.endTime = end } }
        feeder.onError = { [weak self] message in Task { @MainActor in self?.failure = message } }

        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = min(self.duration, max(0, time.seconds))
                if let end = self.endTime, time.seconds >= end - 0.05 {
                    self.reachedEnd()
                }
            }
        }
        await seek(to: 0)
    }

    func play() {
        if currentTime >= duration - 0.1 {
            Task { await seek(to: 0); start() }
        } else {
            start()
        }
    }

    private func start() {
        isPlaying = true
        synchronizer.setRate(1, time: CMTime(seconds: currentTime, preferredTimescale: 90_000))
    }

    func pause() {
        isPlaying = false
        synchronizer.rate = 0
        currentTime = synchronizer.currentTime().seconds
    }

    /// Seeks to the keyframe at or after `seconds`. Keeps playing if it was playing.
    func seek(to seconds: Double) async {
        let wasPlaying = isPlaying
        synchronizer.rate = 0
        endTime = nil
        let start = await feeder.seek(to: max(0, min(seconds, duration)))
        currentTime = start
        synchronizer.setRate(wasPlaying ? 1 : 0, time: CMTime(seconds: start, preferredTimescale: 90_000))
    }

    func stop() {
        synchronizer.rate = 0
        isPlaying = false
        feeder.stop()
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func reachedEnd() {
        isPlaying = false
        synchronizer.rate = 0
        currentTime = duration
    }
}

/// Pulls decrypted TS from the file on its own queue and keeps both renderers fed.
private final class TSFeeder: @unchecked Sendable {
    private static let chunkSize = 128 * 1024

    private let reader: EncvReader
    private let firstPTS: Int64
    private let duration: Double
    private let video: AVSampleBufferVideoRenderer
    private let audio: AVSampleBufferAudioRenderer
    private let queue = DispatchQueue(label: "dev.dineshkumar.aescamera.ts-feeder")

    // queue only
    private var demuxer = TSDemuxer()
    private var offset: UInt64 = 0
    private var videoQueue: [CMSampleBuffer] = []
    private var audioQueue: [CMSampleBuffer] = []
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var waitingForKeyframe = true
    private var minimumAudioPTS: Int64 = 0
    private var finished = false
    private var stopped = false
    private var videoPaused = false
    private var audioPaused = false

    /// Called once everything is queued, with the time the last sample ends.
    var onEnd: (@Sendable (Double) -> Void)?
    private var lastSampleEnd: Double = 0
    var onError: (@Sendable (String) -> Void)?

    init(reader: EncvReader, firstPTS: Int64, duration: Double, video: AVSampleBufferVideoRenderer, audio: AVSampleBufferAudioRenderer) {
        self.reader = reader
        self.firstPTS = firstPTS
        self.duration = duration
        self.video = video
        self.audio = audio
    }

    /// Repositions at the keyframe at or after `seconds`; returns that keyframe's time.
    func seek(to seconds: Double) async -> Double {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                video.stopRequestingMediaData()
                audio.stopRequestingMediaData()
                video.flush()
                audio.flush()
                videoQueue.removeAll()
                audioQueue.removeAll()
                finished = false
                lastSampleEnd = 0

                if demuxer.hasStreams == false {
                    // Learn the stream layout from the PAT/PMT at the very start.
                    offset = 0
                    _ = (try? reader.read(at: 0, count: Self.chunkSize)).map { demuxer.push($0) }
                }
                let length = reader.plaintextLength
                let fraction = duration > 0 ? seconds / duration : 0
                offset = seconds <= 0 ? 0 : min(length, UInt64(Double(length) * fraction))
                demuxer.resync()
                waitingForKeyframe = true
                minimumAudioPTS = .min

                // Fill until the first keyframe so its time is known before playback starts.
                var start = seconds
                while videoQueue.isEmpty && !finished {
                    readMore()
                }
                if let first = videoQueue.first {
                    start = CMSampleBufferGetPresentationTimeStamp(first).seconds
                }
                minimumAudioPTS = firstPTS + Int64(start * 90_000)
                audioQueue.removeAll { CMSampleBufferGetPresentationTimeStamp($0).seconds < start }
                if !stopped { startFeeding() }
                continuation.resume(returning: start)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            video.stopRequestingMediaData()
            audio.stopRequestingMediaData()
            video.flush()
            audio.flush()
            videoQueue.removeAll()
            audioQueue.removeAll()
        }
    }

    private var hasAudio: Bool {
        demuxer.streams.values.contains(.aacADTS)
    }

    private func startFeeding() {
        videoPaused = false
        audioPaused = false
        video.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
        if hasAudio {
            audio.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
        }
    }

    // Backpressure: reading for one renderer also queues the other's samples. If the
    // other queue gets long (its renderer is ahead), pause this one until that drains.
    private static let maxQueued = 300

    private func feedVideo() {
        while video.isReadyForMoreMediaData {
            while videoQueue.isEmpty && !finished {
                if audioQueue.count > Self.maxQueued * 2 {
                    videoPaused = true
                    video.stopRequestingMediaData()
                    return
                }
                readMore()
            }
            guard !videoQueue.isEmpty else {
                video.stopRequestingMediaData()
                checkEnd()
                return
            }
            video.enqueue(videoQueue.removeFirst())
            if audioPaused && videoQueue.count < Self.maxQueued / 2 {
                audioPaused = false
                audio.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
            }
        }
    }

    private func feedAudio() {
        while audio.isReadyForMoreMediaData {
            while audioQueue.isEmpty && !finished {
                if videoQueue.count > Self.maxQueued {
                    audioPaused = true
                    audio.stopRequestingMediaData()
                    return
                }
                readMore()
            }
            guard !audioQueue.isEmpty else {
                audio.stopRequestingMediaData()
                checkEnd()
                return
            }
            audio.enqueue(audioQueue.removeFirst())
            if videoPaused && audioQueue.count < Self.maxQueued {
                videoPaused = false
                video.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
            }
        }
    }

    private func checkEnd() {
        guard finished, videoQueue.isEmpty, audioQueue.isEmpty else { return }
        onEnd?(lastSampleEnd)
    }

    /// Decrypts and demuxes the next chunk. Sets `finished` at the end of the stream.
    private func readMore() {
        guard !finished else { return }
        do {
            let chunk = try autoreleasepool { try reader.read(at: offset, count: Self.chunkSize) }
            offset += UInt64(chunk.count)
            var frames = demuxer.push(chunk)
            if chunk.isEmpty || offset >= reader.plaintextLength {
                frames += demuxer.finish()
                finished = true
            }
            for frame in frames { add(frame) }
        } catch {
            finished = true
            onError?("This video can't be read.")
        }
    }

    private func add(_ frame: TSDemuxer.Frame) {
        switch frame.kind {
        case .h264:
            if let sets = NALUnits.parameterSets(in: frame.data) {
                makeVideoFormat(sps: sets.sps, pps: sets.pps)
            }
            if waitingForKeyframe {
                guard frame.isKeyframe, videoFormat != nil else { return }
                waitingForKeyframe = false
            }
            if let buffer = videoSample(frame) {
                videoQueue.append(buffer)
                lastSampleEnd = max(lastSampleEnd, time(frame.pts).seconds + 1.0 / 30)
            }
        case .aacADTS:
            // Until the first keyframe after a seek, audio has nothing to sync with.
            guard !waitingForKeyframe, frame.pts >= minimumAudioPTS, let config = frame.audioConfig else { return }
            if audioFormat == nil { makeAudioFormat(config) }
            if let buffer = audioSample(frame) {
                audioQueue.append(buffer)
                lastSampleEnd = max(lastSampleEnd, time(frame.pts).seconds + 1024.0 / Double(config.sampleRate))
            }
        }
    }

    private func time(_ pts: Int64) -> CMTime {
        CMTime(value: pts - firstPTS, timescale: 90_000)
    }

    private func makeVideoFormat(sps: Data, pps: Data) {
        guard videoFormat == nil else { return }
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat
                )
            }
        }
    }

    private func makeAudioFormat(_ config: TSDemuxer.AudioConfig) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channels), mBitsPerChannel: 0, mReserved: 0
        )
        let cookie = config.audioSpecificConfig
        _ = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: bytes.baseAddress,
                extensions: nil, formatDescriptionOut: &audioFormat
            )
        }
    }

    private func block(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return status == noErr ? block : nil
    }

    private func videoSample(_ frame: TSDemuxer.Frame) -> CMSampleBuffer? {
        let avcc = NALUnits.avcc(fromAnnexB: frame.data)
        guard let videoFormat, !avcc.isEmpty, let block = block(avcc) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(frame.pts), decodeTimeStamp: time(frame.dts))
        var size = avcc.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: videoFormat, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        )
        if let sample, !frame.isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_NotSync] = true
        }
        return sample
    }

    private func audioSample(_ frame: TSDemuxer.Frame) -> CMSampleBuffer? {
        guard let audioFormat, let block = block(frame.data) else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.data.count))
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: 1,
            presentationTimeStamp: time(frame.pts), packetDescriptions: &packet, sampleBufferOut: &sample
        )
        return sample
    }
}

/// The display layer, rotated by the header's rotation (TS has no rotation metadata).
struct TSVideoSurface: UIViewRepresentable {
    let player: TSPlayer

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.install(player.displayLayer, rotation: player.rotationDegrees)
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {}

    final class SurfaceView: UIView {
        private var videoLayer: CALayer?
        private var rotation = 0

        func install(_ layer: CALayer, rotation: Int) {
            videoLayer = layer
            self.rotation = rotation
            self.layer.addSublayer(layer)
            backgroundColor = .black
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let videoLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let sideways = rotation == 90 || rotation == 270
            videoLayer.bounds = CGRect(origin: .zero, size: sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
            videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            videoLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
            CATransaction.commit()
        }
    }
}
