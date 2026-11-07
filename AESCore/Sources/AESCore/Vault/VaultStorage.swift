import Foundation

/// Where the vault tree lives, and moving it.
///
/// - `private`: `Application Support/vault/`, invisible to other apps and the Files app.
/// - `shared`: `Documents/AES Camera/`, visible in the Files app and Finder. Exposes
///   names (capture times), counts and sizes, like Android's shared storage.
public enum VaultLocation: String, Sendable, CaseIterable {
    case `private`
    case shared
}

public struct VaultMoveCancelled: Error {
    public init() {}
}

public enum VaultStorage {
    public static let privateDirectoryName = "vault"
    public static let sharedDirectoryName = "AES Camera"

    public static func baseURL(for location: VaultLocation, fileManager: FileManager = .default) -> URL {
        switch location {
        case .private:
            return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(privateDirectoryName, isDirectory: true)
        case .shared:
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(sharedDirectoryName, isDirectory: true)
        }
    }

    /// Creates `base` if needed and keeps it out of iCloud/Finder backups (the export
    /// feature is the user's backup, as on Android).
    public static func prepare(_ base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Every regular file under `base`, relative paths included.
    static func files(under base: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Copies the whole tree under `source` into `destination`, checks each copy's length,
    /// then deletes `source`. Files are ciphertext, so nothing is re-encrypted. On failure
    /// or cancel, what was copied is removed again and the source stays intact. Blocking.
    public static func migrate(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool = { false },
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else { return }
        let fileManager = FileManager.default
        let files = files(under: source).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        try prepare(destination)

        var copied: [URL] = []
        do {
            for (index, file) in files.enumerated() {
                if isCancelled() { throw VaultMoveCancelled() }
                let relative = String(file.path.dropFirst(source.path.count + 1))
                let target = destination.appendingPathComponent(relative)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: file, to: target)
                copied.append(target)
                let sourceSize = try fileManager.attributesOfItem(atPath: file.path)[.size] as? Int64
                let targetSize = try fileManager.attributesOfItem(atPath: target.path)[.size] as? Int64
                guard sourceSize == targetSize else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Short copy of \(relative)"])
                }
                progress(index + 1, files.count)
            }
        } catch {
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
        try? fileManager.removeItem(at: source)
    }
}
