@preconcurrency import AVFoundation
import AESCore
import UniformTypeIdentifiers
import UIKit

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
        guard reader.header.container == .fragmentedMP4 else {
            throw CameraError.recordingFailed("thumbnails of MPEG-TS videos aren't supported yet")
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
