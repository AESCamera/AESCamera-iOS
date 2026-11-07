import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encrypted grid thumbnails: 320 px wide JPEG (EXIF orientation applied), sealed as AESP
/// v1 at the thumbnail KDF cost, stored at `.thumbs/<same name>`. The same on Android.
public enum Thumbnails {
    public static let width = 320
    /// Older Android builds made 24 dp thumbnails; anything narrower is rebuilt once.
    public static let regenerateBelowWidth = 160

    /// A JPEG `width` px wide from encoded image data, never decoding the full image.
    public static func jpeg(fromImageData data: Data, width: Int = width, quality: Double = 0.9) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let image = scaledImage(from: source, width: width) else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    /// A JPEG `width` px wide from an already decoded frame (video thumbnails).
    public static func jpeg(from image: CGImage, width: Int = width, quality: Double = 0.9) -> Data? {
        let height = max(1, image.height * width / max(1, image.width))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return encodeJPEG(scaled, quality: quality)
    }

    /// Seals `jpeg` and writes it as the thumbnail of `item` (keeps an existing one unless
    /// `overwrite`).
    public static func store(
        _ jpeg: Data, for item: MediaItem, secret: Secret, overwrite: Bool = false,
        cache: KeyCache = .shared, options: Data.WritingOptions = []
    ) throws {
        let url = item.thumbnailURL
        if !overwrite && FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try ImageCrypto.seal(jpeg, secret: secret, iterations: KDFParameters.thumbnail.iterations, cache: cache)
        try sealed.write(to: url, options: options.union(.atomic))
    }

    /// Decodes an image for display, bounded to `maxPixelSize` on the long side, with the
    /// EXIF orientation applied.
    public static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func scaledImage(from source: CGImageSource, width: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapped = (5...8).contains(orientation)
        let orientedWidth = swapped ? pixelHeight : pixelWidth
        let orientedHeight = swapped ? pixelWidth : pixelHeight
        // ImageIO bounds the long side; pick it so the short-or-long *width* comes out right.
        let maxPixel = Int((Double(width) * Double(max(orientedWidth, orientedHeight)) / Double(orientedWidth)).rounded(.up))
        guard let image = decode(sourceData: source, maxPixelSize: maxPixel) else { return nil }
        return image.width == width ? image : rescale(image, width: width)
    }

    private static func decode(sourceData source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func rescale(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, image.height * width / max(1, image.width))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
