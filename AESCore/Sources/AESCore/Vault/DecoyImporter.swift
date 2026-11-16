import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Adds photos from the device to a duress password's decoy vault, so that vault doesn't
/// look suspiciously empty when it opens. Each photo is stored like a camera capture: a
/// JPEG sealed with the duress password, named after when it was taken, with a thumbnail.
/// The same as Android's `DecoyImporter`.
public enum DecoyImporter {
    /// Photos bigger than this are skipped rather than held in memory whole.
    public static let maxBytes = 64 * 1024 * 1024

    public struct Summary: Equatable, Sendable {
        public var added = 0
        public var skipped = 0

        public init() {}
    }

    /// Seals one photo into `vault`. Returns false (skipped) for data that isn't an image.
    @discardableResult
    public static func add(
        _ data: Data, to vault: URL, secret: Secret, cache: KeyCache = .shared,
        options: Data.WritingOptions = []
    ) throws -> Bool {
        guard data.count <= maxBytes, let jpeg = asJPEG(data) else { return false }
        let url = freeURL(in: vault, takenAt: takenAt(data) ?? Date())
        try ImageCrypto.seal(jpeg, secret: secret, cache: cache).write(to: url, options: options.union(.atomic))
        let item = MediaItem(url: url, captureDate: MediaNames.captureDate(fromName: url.lastPathComponent) ?? Date())
        if let thumbnail = Thumbnails.jpeg(fromImageData: jpeg) {
            try? Thumbnails.store(thumbnail, for: item, secret: secret, cache: cache, options: options)
        }
        return true
    }

    /// JPEG as-is (it keeps its EXIF); anything else (HEIC, PNG…) decoded upright and
    /// re-encoded. Nil if it isn't an image.
    static func asJPEG(_ data: Data) -> Data? {
        if data.count > 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8 {
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = Thumbnails.decode(data, maxPixelSize: max(width, height))
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// When the photo was taken (EXIF, in local time), so decoy photos sort like real ones.
    static func takenAt(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: stamp)
    }

    /// A camera-style name for `date`; a millisecond later if that name is taken.
    static func freeURL(in vault: URL, takenAt date: Date) -> URL {
        var candidate = date
        while true {
            let url = vault.appendingPathComponent(MediaNames.newPhotoName(at: candidate))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            candidate = candidate.addingTimeInterval(0.001)
        }
    }
}
