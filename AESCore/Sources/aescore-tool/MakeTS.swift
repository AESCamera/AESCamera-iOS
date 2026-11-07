import AESCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// Builds an Android-style `.encv` (v4, container 1 = MPEG-TS) from synthetic content:
/// real H.264 from VideoToolbox and real AAC from AVAudioConverter, muxed the way
/// MediaRecorder does it (PAT/PMT once, no PCR, no AUDs). For exercising the iOS TS
/// player without an Android device.
enum MakeTS {
    /// The upright (display) size; stored frames are turned by the header rotation.
    static let width = 720
    static let height = 1280
    static let fps = 30
    nonisolated(unsafe) static var rotation = 0

    /// Stored frame size: a sensor-style landscape frame when the rotation is 90/270.
    static var storedSize: (width: Int, height: Int) {
        rotation == 90 || rotation == 270 ? (height, width) : (width, height)
    }

    static func run(output: URL, password: String, seconds: Int, rotation: Int, audio: Bool) throws {
        Self.rotation = rotation
        var muxer = TSMuxer(hasAudio: audio)
        var stream = muxer.take()

        var units: [(pts: Int64, annexB: Data)] = []
        try encodeVideo(frames: seconds * fps) { units.append(($0, $1)) }
        var audioPackets: [(pts: Int64, frames: [Data])] = []
        var config: TSDemuxer.AudioConfig?
        if audio {
            let encoded = try encodeAudio(seconds: seconds)
            config = encoded.config
            // Two AAC frames per PES, like MediaRecorder.
            var index = 0
            while index < encoded.frames.count {
                let pts = Int64(index) * 1024 * 90_000 / Int64(encoded.config.sampleRate)
                audioPackets.append((pts, Array(encoded.frames[index..<min(index + 2, encoded.frames.count)])))
                index += 2
            }
        }

        // Interleave by timestamp.
        var videoIndex = 0
        var audioIndex = 0
        while videoIndex < units.count || audioIndex < audioPackets.count {
            let takeVideo = audioIndex >= audioPackets.count ||
                (videoIndex < units.count && units[videoIndex].pts <= audioPackets[audioIndex].pts)
            if takeVideo {
                muxer.writeVideo(annexB: units[videoIndex].annexB, pts: units[videoIndex].pts)
                videoIndex += 1
            } else if let config {
                muxer.writeAudio(frames: audioPackets[audioIndex].frames, config: config, pts: audioPackets[audioIndex].pts)
                audioIndex += 1
            }
            stream.append(muxer.take())
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try EncvWriter(url: output, secret: Secret(password), header: EncvHeader(container: .mpeg2TS))
        try writer.write(stream)
        try writer.finish(rotationDegrees: rotation)
        print("wrote \(output.lastPathComponent): \(units.count) video frames, \(audioPackets.count) audio PES, \(stream.count) TS bytes, rotation \(rotation)")
    }

    // MARK: Video

    static func encodeVideo(frames: Int, emit: (Int64, Data) -> Void) throws {
        var sessionOut: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(storedSize.width), height: Int32(storedSize.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut
        )
        guard status == noErr, let session = sessionOut else { throw ToolError("VTCompressionSessionCreate \(status)") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber)

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var results: [(Int64, Data)] = []
        }
        let collector = Collector()
        for index in 0..<frames {
            guard let pixelBuffer = drawFrame(index) else { throw ToolError("pixel buffer") }
            let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let annexB = annexB(from: sampleBuffer) else { return }
                let pts90k = Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 90_000)
                collector.lock.withLock { collector.results.append((pts90k, annexB)) }
            }
            guard status == noErr else { throw ToolError("encode \(status)") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        for (pts, data) in collector.results.sorted(by: { $0.0 < $1.0 }) { emit(pts, data) }
    }

    static func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var out = Data()
        let startCode = Data([0, 0, 0, 1])
        if isKeyframe {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer {
                    out.append(startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let avcc = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= avcc.count {
            let unitLength = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16 | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            offset += 4
            guard offset + unitLength <= avcc.count else { break }
            out.append(startCode)
            out.append(avcc[offset..<(offset + unitLength)])
            offset += unitLength
        }
        return out
    }

    static func drawFrame(_ index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, storedSize.width, storedSize.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: storedSize.width, height: storedSize.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }
        // Draw the upright scene turned counter-clockwise by the rotation, as a sensor
        // would store it; a player applying the header rotation shows it upright.
        switch rotation {
        case 90:
            context.translateBy(x: CGFloat(storedSize.width), y: 0)
            context.rotate(by: .pi / 2)
        case 180:
            context.translateBy(x: CGFloat(storedSize.width), y: CGFloat(storedSize.height))
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: 0, y: CGFloat(storedSize.height))
            context.rotate(by: -.pi / 2)
        default:
            break
        }
        let t = Double(index) / Double(fps)
        // Orange-to-teal background, a sweeping bar, and one block per elapsed second so
        // seeking is easy to check by eye. An "UP" arrow shows the orientation.
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: 0, y: CGFloat(height) * CGFloat(t.truncatingRemainder(dividingBy: 2) / 2), width: CGFloat(width), height: 20))
        for second in 0..<Int(t) {
            context.setFillColor(CGColor(red: 0.95, green: 0.1, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 30 + (second % 10) * 66, y: 60 + (second / 10) * 66, width: 50, height: 50))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.move(to: CGPoint(x: width / 2, y: height - 100))
        context.addLine(to: CGPoint(x: width / 2 - 80, y: height - 260))
        context.addLine(to: CGPoint(x: width / 2 + 80, y: height - 260))
        context.fillPath()
        return buffer
    }

    // MARK: Audio

    static func encodeAudio(seconds: Int) throws -> (config: TSDemuxer.AudioConfig, frames: [Data]) {
        let sampleRate = 44_100.0
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw ToolError("pcm format") }
        var aacDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let aacFormat = AVAudioFormat(streamDescription: &aacDescription),
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else { throw ToolError("aac converter") }
        converter.bitRate = 96_000

        let total = AVAudioFrameCount(sampleRate) * AVAudioFrameCount(seconds)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: total) else { throw ToolError("pcm buffer") }
        pcm.frameLength = total
        let samples = pcm.floatChannelData![0]
        for index in 0..<Int(total) {
            // A 440 Hz tone with a click at every second.
            let t = Double(index) / sampleRate
            let click = t.truncatingRemainder(dividingBy: 1) < 0.01 ? 0.5 : 0
            samples[index] = Float(0.2 * sin(2 * .pi * 440 * t) + click)
        }

        var frames: [Data] = []
        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 32, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if let error { throw error }
            for index in 0..<Int(out.packetCount) {
                let description = out.packetDescriptions![index]
                frames.append(Data(bytes: out.data + Int(description.mStartOffset), count: Int(description.mDataByteSize)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return (TSDemuxer.AudioConfig(objectType: 2, sampleRate: Int(sampleRate), channels: 1), frames)
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
