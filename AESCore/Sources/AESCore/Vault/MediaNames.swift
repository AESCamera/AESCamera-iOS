import Foundation

/// File names inside a vault: `IMG-yyyy-MM-dd-HH-mm-ss-SSS.enc` and `VID-….encv`, in the
/// device's local time (as on Android). Thumbnails live in `.thumbs/` under the same name.
public enum MediaNames {
    public static let photoExtension = "enc"
    public static let videoExtension = "encv"
    public static let thumbnailsDirectory = ".thumbs"

    // Shared and mutated (time zone) only under `lock`.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        return formatter
    }()

    private static let lock = NSLock()

    private static func string(from date: Date) -> String {
        lock.withLock {
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
    }

    public static func newPhotoName(at date: Date = Date()) -> String {
        "IMG-\(string(from: date)).\(photoExtension)"
    }

    public static func newVideoName(at date: Date = Date()) -> String {
        "VID-\(string(from: date)).\(videoExtension)"
    }

    public static func isVideo(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".\(videoExtension)")
    }

    /// A photo or video (not a dot-file such as the verifier, not a thumbnail dir).
    public static func isMedia(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        return lower.hasSuffix(".\(photoExtension)") || lower.hasSuffix(".\(videoExtension)")
    }

    /// True for names this app generated (the rest are imports with foreign names).
    public static func isGenerated(_ name: String) -> Bool {
        name.hasPrefix("IMG-") || name.hasPrefix("VID-")
    }

    /// The capture time encoded in `name`, or nil for foreign names.
    public static func captureDate(fromName name: String) -> Date? {
        guard isGenerated(name), name.count > 4 else { return nil }
        let stamp = name.dropFirst(4).prefix { $0 != "." }
        // Imports may add a "-1" suffix; the stamp itself is fixed-width.
        let fixed = String(stamp.prefix(23))
        return lock.withLock {
            formatter.timeZone = .current
            return formatter.date(from: fixed)
        }
    }
}

/// One photo or video in a vault.
public struct MediaItem: Hashable, Sendable, Identifiable {
    public let url: URL
    public let captureDate: Date

    public var id: String { url.lastPathComponent }
    public var name: String { url.lastPathComponent }
    public var isVideo: Bool { MediaNames.isVideo(name) }

    public init(url: URL, captureDate: Date) {
        self.url = url
        self.captureDate = captureDate
    }

    /// The encrypted thumbnail's location in the vault.
    public var thumbnailURL: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(MediaNames.thumbnailsDirectory, isDirectory: true)
            .appendingPathComponent(name)
    }
}

public enum VaultFiles {
    /// Photos and videos in `vault`, newest first. A missing vault is an empty one.
    public static func media(in vault: URL?) -> [MediaItem] {
        guard let vault else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: []
        )) ?? []
        return urls
            .filter { MediaNames.isMedia($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url in
                let date = MediaNames.captureDate(fromName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return MediaItem(url: url, captureDate: date)
            }
            .sorted { lhs, rhs in
                lhs.captureDate != rhs.captureDate ? lhs.captureDate > rhs.captureDate : lhs.name > rhs.name
            }
    }

    /// The files worth backing up: the verifier first, then the media (no thumbnails).
    public static func backupFiles(in vault: URL) -> [URL] {
        let verifier = vault.appendingPathComponent(VaultLocator.verifierName)
        let media = media(in: vault).map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (FileManager.default.fileExists(atPath: verifier.path) ? [verifier] : []) + media
    }

    /// Deletes a photo or video and its thumbnail.
    public static func delete(_ item: MediaItem) throws {
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        try FileManager.default.removeItem(at: item.url)
    }

    /// `name`, or `name-1`, `name-2`, … if `directory` already has a file of that name.
    public static func uniqueURL(in directory: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
