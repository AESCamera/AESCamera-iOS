import AESCore
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Writes captures into the vault. An actor, so photo saves run one at a time in capture
/// order and memory stays bounded by the number of pending saves.
actor MediaSaver {
    static let shared = MediaSaver()

    struct SavedPhoto: Sendable {
        let item: MediaItem
        /// The plaintext thumbnail JPEG, for the camera's last-capture preview.
        let thumbnail: Data?
    }

    /// Seals `jpeg` (AESP v1) into a new `IMG-….enc`, then its 320 px thumbnail.
    func savePhoto(_ jpeg: Data, vault: URL, secret: Secret, salt: [UInt8]?) throws -> SavedPhoto {
        let sealed = try ImageCrypto.seal(jpeg, secret: secret, salt: salt)
        let url = VaultFiles.uniqueURL(in: vault, for: MediaNames.newPhotoName())
        try sealed.write(to: url, options: FileProtection.writeOptions)
        let item = MediaItem(url: url, captureDate: Date())
        let thumbnail = Thumbnails.jpeg(fromImageData: jpeg)
        if let thumbnail {
            try? Thumbnails.store(thumbnail, for: item, secret: secret, options: .completeFileProtection)
        }
        return SavedPhoto(item: item, thumbnail: thumbnail)
    }

    /// Thumbnail of a recording from its first frame, rotated by the recording's angle.
    nonisolated static func storeVideoThumbnail(
        _ pixelBuffer: CVPixelBuffer, rotationAngle: CGFloat, for item: MediaItem, secret: Secret
    ) -> Data? {
        let orientation: CGImagePropertyOrientation = switch Int(rotationAngle) {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent),
              let jpeg = Thumbnails.jpeg(from: cgImage)
        else { return nil }
        try? Thumbnails.store(jpeg, for: item, secret: secret, options: .completeFileProtection)
        return jpeg
    }
}
