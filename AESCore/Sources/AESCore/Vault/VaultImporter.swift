import Foundation

/// Copies an already-encrypted file (a shared `.enc`/`.encv`, or one from a backup) into a
/// vault. Files are self-contained ciphertext, so nothing is re-encrypted. A file that
/// doesn't open with the vault's password is removed again and reported: this vault could
/// never show it.
public enum VaultImporter {
    public enum Outcome: Equatable, Sendable {
        case imported(MediaItem)
        /// The vault already holds a byte-identical file under this name.
        case alreadyInVault(MediaItem)
        case wrongPassword
    }

    /// Makes and stores the thumbnail for a freshly imported item. Photos get their
    /// decrypted bytes; videos get nil and must read the file themselves.
    public typealias ThumbnailMaker = (_ item: MediaItem, _ decryptedPhoto: Data?) throws -> Void

    /// Blocking (PBKDF2 and, for videos, a full read): call off the main thread.
    public static func importFile(
        _ staged: URL,
        preferredName: String,
        into vault: URL,
        secret: Secret,
        cache: KeyCache = .shared,
        makeThumbnail: ThumbnailMaker? = nil
    ) throws -> Outcome {
        let isVideo = MediaNames.isVideo(preferredName)
        let name = ImportValidator.sanitizeName(preferredName, isVideo: isVideo)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: vault, withIntermediateDirectories: true)

        if let existing = identicalFile(to: staged, in: vault) {
            return .alreadyInVault(item(for: existing))
        }

        let target = VaultFiles.uniqueURL(in: vault, for: name)
        try fileManager.copyItem(at: staged, to: target)
        do {
            let item = item(for: target)
            if isVideo {
                guard EncvReader.verify(url: target, secret: secret, cache: cache) != .failed else {
                    try? fileManager.removeItem(at: target)
                    return .wrongPassword
                }
                try? makeThumbnail?(item, nil)
            } else {
                let decrypted: Data
                do {
                    decrypted = try ImageCrypto.open(Data(contentsOf: target), secret: secret, cache: cache)
                } catch CryptoError.locked {
                    throw CryptoError.locked
                } catch {
                    try? fileManager.removeItem(at: target)
                    return .wrongPassword
                }
                try? makeThumbnail?(item, decrypted)
            }
            return .imported(item)
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
    }

    /// A media file in `vault` with exactly the bytes of `file`, whatever its name (a
    /// re-shared photo, or a restore of files already there). Only same-size files are
    /// compared, so this stays cheap.
    static func identicalFile(to file: URL, in vault: URL) -> URL? {
        let fileManager = FileManager.default
        guard let size = (try? fileManager.attributesOfItem(atPath: file.path))?[.size] as? Int64 else { return nil }
        // Listings resolve symlinks (/var → /private/var); answer in the caller's terms.
        return VaultFiles.media(in: vault).lazy
            .map { vault.appendingPathComponent($0.name) }
            .first { candidate in
                (try? fileManager.attributesOfItem(atPath: candidate.path))?[.size] as? Int64 == size &&
                    fileManager.contentsEqual(atPath: candidate.path, andPath: file.path)
            }
    }

    private static func item(for url: URL) -> MediaItem {
        let date = MediaNames.captureDate(fromName: url.lastPathComponent)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
        return MediaItem(url: url, captureDate: date)
    }
}
