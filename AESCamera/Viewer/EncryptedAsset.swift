@preconcurrency import AVFoundation
import AESCore
import UniformTypeIdentifiers
import UIKit
import VideoToolbox
import CoreImage

/// Plays an iOS-made `.encv` (container 2, fragmented MP4) with AVPlayer, decrypting on
/// the fly. AVPlayer asks for byte ranges of a custom-scheme URL; each range is decrypted
/// from the file with the CTR cipher positioned in O(1). Nothing decrypted is written.
final class EncryptedAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "aesv"
    private static let chunkSize = 256 * 1024

    let reader: EncvReader
    private let queue = DispatchQueue(label: "dev.dineshkumar.aescamera.asset-loader", attributes: .concurrent)

    init(reader: EncvReader) {
        self.reader = reader
    }

    /// An asset backed by this loader. Keep the loader alive as long as the asset: the
    /// resource loader holds its delegate weakly.
    func makeAsset() -> AVURLAsset {
        let url = URL(string: "\(Self.scheme)://video/\(UUID().uuidString).mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = Int64(reader.plaintextLength)
            info.isByteRangeAccessSupported = true
            info.isEntireLengthAvailableOnDemand = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let request = SendableBox(loadingRequest)
        queue.async { [reader] in
            let loadingRequest = request.value
            var offset = UInt64(max(0, dataRequest.currentOffset))
            let end: UInt64 = dataRequest.requestsAllDataToEndOfResource
                ? reader.plaintextLength
                : min(reader.plaintextLength, UInt64(dataRequest.requestedOffset) + UInt64(dataRequest.requestedLength))
            do {
                while offset < end {
                    if loadingRequest.isCancelled { return }
                    let count = Int(min(UInt64(Self.chunkSize), end - offset))
                    let chunk = try autoreleasepool { try reader.read(at: offset, count: count) }
                    if chunk.isEmpty { break }
                    dataRequest.respond(with: chunk)
                    offset += UInt64(chunk.count)
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }
}

enum VideoFrames {
    /// The first frame of an encrypted iOS video, upright, for thumbnails.
    static func firstFrame(of url: URL, secret: Secret) async throws -> CGImage {
        let reader = try EncvReader(url: url, secret: secret)
        if reader.header.container == .mpeg2TS {
            return try TSFrames.firstFrame(reader)
        }
        let loader = EncryptedAssetLoader(reader: reader)
        let asset = loader.makeAsset()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Thumbnails.width * 2, height: Thumbnails.width * 2)
        let (image, _) = try await generator.image(at: .zero)
        withExtendedLifetime(loader) {}
        return image
    }

    /// Builds and stores the thumbnail of an encrypted video. Returns the JPEG.
    @discardableResult
    static func makeThumbnail(for item: MediaItem, secret: Secret, overwrite: Bool = false) async throws -> Data {
        let image = try await firstFrame(of: item.url, secret: secret)
        guard let jpeg = Thumbnails.jpeg(from: image) else { throw CameraError.photoFailed }
        try Thumbnails.store(jpeg, for: item, secret: secret, overwrite: overwrite, options: .completeFileProtection)
        return jpeg
    }
}

/// First frame of an Android (MPEG-TS) recording: the first IDR access unit decoded with
/// VideoToolbox and turned upright by the header rotation. Starting from a keyframe
/// avoids the flat-green frames Android's own frame grabber gets from these files.
enum TSFrames {
    static func firstFrame(_ reader: EncvReader) throws -> CGImage {
        var demuxer = TSDemuxer()
        var offset: UInt64 = 0
        var keyframe: TSDemuxer.Frame?
        var parameterSets: (sps: Data, pps: Data)?
        while keyframe == nil, offset < min(reader.plaintextLength, 8 * 1024 * 1024) {
            let chunk = try reader.read(at: offset, count: 256 * 1024)
            guard !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            for frame in demuxer.push(chunk) where frame.kind == .h264 {
                if let sets = NALUnits.parameterSets(in: frame.data) { parameterSets = sets }
                if frame.isKeyframe, parameterSets != nil {
                    keyframe = frame
                    break
                }
            }
        }
        guard let keyframe, let parameterSets else { throw CameraError.photoFailed }

        var format: CMVideoFormatDescription?
        parameterSets.sps.withUnsafeBytes { sps in
            parameterSets.pps.withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [parameterSets.sps.count, parameterSets.pps.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        guard let format else { throw CameraError.photoFailed }

        var avcc = NALUnits.avcc(fromAnnexB: keyframe.data)
        var block: CMBlockBuffer?
        let blockStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block
            )
        }
        guard blockStatus == noErr, let block else { throw CameraError.photoFailed }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var size = avcc.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { throw CameraError.photoFailed }

        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr,
              let session else { throw CameraError.photoFailed }
        defer { VTDecompressionSessionInvalidate(session) }

        final class Output: @unchecked Sendable { var buffer: CVImageBuffer? }
        let output = Output()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { output.buffer = buffer }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, let pixels = output.buffer else { throw CameraError.photoFailed }

        let orientation: CGImagePropertyOrientation = switch reader.header.rotationDegrees {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
        let image = CIImage(cvImageBuffer: pixels).oriented(orientation)
        guard let cgImage = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent) else {
            throw CameraError.photoFailed
        }
        return cgImage
    }
}
