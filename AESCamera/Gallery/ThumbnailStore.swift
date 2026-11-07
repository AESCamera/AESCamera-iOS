import AESCore
import ImageIO
import UIKit

/// Limits concurrent work (thumbnail decrypts) without blocking threads.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if running >= limit {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiters.isEmpty {
                running -= 1
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await work()
    }
}

/// Decrypted grid thumbnails: at most 3 decrypts at a time, kept in a memory cache (about
/// 24 MB of bitmaps) that's emptied on lock. Results are keyed by the password's
/// fingerprint, so a thumbnail decrypted under one password never shows under another.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private let limiter = AsyncLimiter(limit: 3)

    func cached(_ item: MediaItem, secret: Secret) -> UIImage? {
        cache.object(forKey: key(item, secret))
    }

    func image(for item: MediaItem, secret: Secret) async -> UIImage? {
        let key = key(item, secret)
        if let cached = cache.object(forKey: key) { return cached }
        let data = await limiter.run { () -> Data? in
            if Task.isCancelled { return nil }
            return await Self.loadThumbnail(item, secret: secret)
        }
        guard !Task.isCancelled, !secret.isWiped, let data, let image = UIImage(data: data) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: key, cost: Int(prepared.size.width * prepared.size.height * prepared.scale * prepared.scale * 4))
        return prepared
    }

    func purge() {
        cache.removeAllObjects()
    }

    private func key(_ item: MediaItem, _ secret: Secret) -> NSString {
        "\(secret.fingerprint)/\(item.url.path)" as NSString
    }

    /// Reads the encrypted thumbnail; rebuilds missing ones (and old tiny Android photo
    /// thumbnails) once from the full file.
    nonisolated private static func loadThumbnail(_ item: MediaItem, secret: Secret) async -> Data? {
        if let sealed = try? Data(contentsOf: item.thumbnailURL),
           let jpeg = try? ImageCrypto.open(sealed, secret: secret) {
            if item.isVideo || width(of: jpeg) >= Thumbnails.regenerateBelowWidth {
                return jpeg
            }
        }
        if item.isVideo {
            return try? await VideoFrames.makeThumbnail(for: item, secret: secret, overwrite: true)
        }
        guard let full = try? ImageCrypto.open(Data(contentsOf: item.url), secret: secret),
              let jpeg = Thumbnails.jpeg(fromImageData: full)
        else { return nil }
        try? Thumbnails.store(jpeg, for: item, secret: secret, overwrite: true, options: .completeFileProtection)
        return jpeg
    }

    nonisolated private static func width(of jpeg: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        return properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}
