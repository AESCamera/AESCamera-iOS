import AESCore
import Foundation

/// Backup and restore through the system file picker, so the destination can be iCloud
/// Drive, a USB drive or any document provider. Files stay ciphertext. Blocking: call off
/// the main actor.
enum VaultTransfer {
    struct ExportSummary: Sendable {
        let exported: Int
        let failed: Int
        let folderName: String
    }

    struct RestoreSummary: Sendable {
        var restored = 0
        var alreadyThere = 0
        var wrongPassword = 0
        var skipped = 0
    }

    /// Copies `files` into a new `AESCamera-yyyy-MM-dd-HH-mm` folder under the picked
    /// (security-scoped) `destination`, the same layout as Android's export.
    static func export(
        _ files: [URL],
        to destination: URL,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> ExportSummary {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        let folderName = "AESCamera-" + formatter.string(from: Date())
        let folder = destination.appendingPathComponent(folderName, isDirectory: true)

        var exported = 0
        var failed = 0
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordinationError) { folder in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                failed = files.count
                return
            }
            for (index, file) in files.enumerated() {
                if isCancelled() { break }
                let target = folder.appendingPathComponent(file.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: file, to: target)
                    exported += 1
                } catch {
                    failed += 1
                }
                progress(index + 1, files.count)
            }
        }
        if let coordinationError { throw coordinationError }
        if isCancelled() { throw VaultMoveCancelled() }
        return ExportSummary(exported: exported, failed: failed, folderName: folderName)
    }

    /// Brings picked files into `vault`: each is validated like a shared file, staged in
    /// `tmp/`, then imported (which rejects files sealed with another password and builds
    /// thumbnails). An exported `.vault` verifier is skipped silently.
    static func restore(
        _ urls: [URL],
        into vault: URL,
        secret: Secret,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> RestoreSummary {
        let staging = ImportStaging.directory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var summary = RestoreSummary()
        for (index, url) in urls.enumerated() {
            if isCancelled() { throw VaultMoveCancelled() }
            defer { progress(index + 1, urls.count) }
            if url.lastPathComponent == VaultLocator.verifierName { continue }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard case .success(let accepted) = ImportValidator.inspect(url) else {
                summary.skipped += 1
                continue
            }
            let staged = staging.appendingPathComponent(accepted.name)
            guard (try? ImportValidator.copy(from: url, to: staged, limit: accepted.limit)) == true else {
                summary.skipped += 1
                continue
            }
            defer { try? FileManager.default.removeItem(at: staged) }
            switch try await ImportStaging.addToVault(staged, name: accepted.name, vault: vault, secret: secret) {
            case .imported: summary.restored += 1
            case .alreadyInVault: summary.alreadyThere += 1
            case .wrongPassword: summary.wrongPassword += 1
            }
        }
        return summary
    }
}

/// `tmp/import/`: ciphertext copied in from other apps before the user decides. Wiped at
/// launch and after use.
enum ImportStaging {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("import", isDirectory: true)
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Imports a staged file and builds its thumbnail (photos from the decrypted bytes,
    /// iOS videos from their first frame).
    static func addToVault(_ staged: URL, name: String, vault: URL, secret: Secret) async throws -> VaultImporter.Outcome {
        let outcome = try VaultImporter.importFile(staged, preferredName: name, into: vault, secret: secret) { item, photo in
            if let photo, let jpeg = Thumbnails.jpeg(fromImageData: photo) {
                try Thumbnails.store(jpeg, for: item, secret: secret, options: .completeFileProtection)
            }
        }
        if case .imported(let item) = outcome {
            FileProtection.markComplete(item.url)
            if item.isVideo {
                _ = try? await VideoFrames.makeThumbnail(for: item, secret: secret)
            }
        }
        return outcome
    }
}
