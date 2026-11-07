import Foundation

/// Checks files arriving from other apps (Open in, share sheet, the restore picker)
/// before anything else happens to them. Name, size and content are all attacker
/// controlled: the name is rebuilt from a safe character set, the size is bounded, and
/// the first bytes must look like one of our formats before a password is even asked for.
public enum ImportValidator {
    /// Photos are decrypted whole in memory, so they're capped hard.
    public static let maxImageBytes: Int64 = 64 * 1024 * 1024
    /// Videos stream; this only stops a file from filling the disk.
    public static let maxVideoBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maxNameLength = 120

    public enum Rejection: Error, Equatable, Sendable {
        case notEncrypted
        case unreadable
        case tooLarge
    }

    public struct Accepted: Equatable, Sendable {
        public let url: URL
        /// Already sanitised.
        public let name: String
        /// Nil when the size couldn't be read.
        public let size: Int64?
        public let isVideo: Bool

        public var limit: Int64 { isVideo ? maxVideoBytes : maxImageBytes }
    }

    /// Inspects a local or security-scoped `url`. `displayName` overrides the URL's own
    /// last path component when the provider gives a nicer one.
    public static func inspect(_ url: URL, displayName: String? = nil) -> Result<Accepted, Rejection> {
        let rawName = displayName ?? url.lastPathComponent
        let lower = rawName.lowercased()
        let isVideo = lower.hasSuffix(".encv")
        guard isVideo || lower.hasSuffix(".enc") else { return .failure(.notEncrypted) }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            head = try handle.read(upToCount: EncvHeader.prefixSize) ?? Data()
        } catch {
            return .failure(.unreadable)
        }

        guard looksEncrypted(head: head, size: size, isVideo: isVideo) else { return .failure(.notEncrypted) }
        if let size, size > (isVideo ? maxVideoBytes : maxImageBytes) { return .failure(.tooLarge) }
        return .success(Accepted(url: url, name: sanitizeName(rawName, isVideo: isVideo), size: size, isVideo: isVideo))
    }

    /// True if `head` (the first bytes) and `size` fit an `.encv`, an AESP photo, or a
    /// legacy CBC photo (salt + iv + whole blocks, no magic to check).
    public static func looksEncrypted(head: Data, size: Int64?, isVideo: Bool) -> Bool {
        if isVideo {
            return head.count >= EncvHeader.size && (try? EncvHeader.parse(head)) != nil
        }
        if ImageCrypto.isAuthenticated(head) { return true }
        guard head.count >= EncvHeader.prefixSize else { return false }
        guard let size else { return true }
        return size >= 48 && (size - 32) % 16 == 0
    }

    /// Rebuilds a provider-supplied name: last path segment only, safe characters only,
    /// no leading dot (hidden files, the `.vault` verifier), bounded length, the right
    /// extension, or a freshly generated name when nothing usable is left.
    ///
    /// Works on Unicode scalars, as Java's regex does on code points, so names come out
    /// the same as on Android. One deliberate difference: leading dots are also trimmed
    /// after truncation, so a long name can't turn into a hidden file.
    public static func sanitizeName(_ raw: String?, isVideo: Bool, now: Date = Date()) -> String {
        let ext = isVideo ? ".encv" : ".enc"
        var segment = raw ?? ""
        if let slash = segment.lastIndex(of: "/") { segment = String(segment[segment.index(after: slash)...]) }
        if let backslash = segment.lastIndex(of: "\\") { segment = String(segment[segment.index(after: backslash)...]) }
        segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)

        var scalars = String.UnicodeScalarView()
        for scalar in segment.unicodeScalars {
            let safe = (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") ||
                (scalar >= "0" && scalar <= "9") || scalar == "." || scalar == "_" || scalar == "-"
            scalars.append(safe ? scalar : "_")
        }
        var cleaned = String(String(scalars).drop { $0 == "." })
        if cleaned.count > maxNameLength {
            cleaned = String(String(cleaned.suffix(maxNameLength)).drop { $0 == "." })
        }
        guard cleaned.count > ext.count, cleaned.lowercased().hasSuffix(ext) else {
            return isVideo ? MediaNames.newVideoName(at: now) : MediaNames.newPhotoName(at: now)
        }
        return cleaned
    }

    /// Copies `source` to `destination` (created fresh), refusing once more than `limit`
    /// bytes were read, so a source that lies about its size can't fill the disk. Returns
    /// false (and removes the partial copy) when the limit was hit.
    public static func copy(from source: URL, to destination: URL, limit: Int64) throws -> Bool {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        var total: Int64 = 0
        do {
            while true {
                let chunk = try autoreleasepool { try input.read(upToCount: 256 * 1024) ?? Data() }
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                if total > limit {
                    try output.close()
                    try? FileManager.default.removeItem(at: destination)
                    return false
                }
                try output.write(contentsOf: chunk)
            }
            try output.close()
            return true
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
