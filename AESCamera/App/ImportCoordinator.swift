import AESCore
import Foundation
import Observation

/// Files handed to the app by other apps ("Open in AES Camera", the share sheet, Files).
/// Everything about them is untrusted: each is validated (extension, magic bytes, size)
/// before the user is asked, then the ciphertext is copied with a byte limit into
/// `tmp/import/`. Only then does the viewer open, which is where the password is needed.
@MainActor @Observable
final class ImportCoordinator {
    /// Files waiting for the user's confirmation.
    private(set) var pending: [ImportValidator.Accepted] = []
    /// Staged copies being shown in the imported viewer.
    private(set) var staged: [URL]?
    var message: String?

    @ObservationIgnored private var incoming: [URL] = []
    @ObservationIgnored private var collecting: Task<Void, Never>?

    var isAsking: Bool { !pending.isEmpty }

    /// Called for every URL the system opens us with. URLs arriving together (a multi-file
    /// share) are collected into one confirmation.
    func receive(_ url: URL) {
        incoming.append(url)
        collecting?.cancel()
        collecting = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await inspectIncoming()
        }
    }

    private func inspectIncoming() async {
        let urls = incoming
        incoming = []
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { url -> Result<ImportValidator.Accepted, ImportValidator.Rejection> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return ImportValidator.inspect(url)
            }
        }.value

        var accepted: [ImportValidator.Accepted] = []
        var rejected: [ImportValidator.Rejection] = []
        for result in results {
            switch result {
            case .success(let file): accepted.append(file)
            case .failure(let reason): rejected.append(reason)
            }
        }
        if !rejected.isEmpty {
            message = rejected.count == results.count
                ? Self.describe(rejected[0])
                : "\(rejected.count) of \(results.count) files can't be opened: they aren't AES Camera files or are too large."
        }
        pending = accepted
    }

    /// The user agreed: stage the files and open the viewer.
    func confirm() {
        let files = pending
        pending = []
        Task {
            ImportStaging.wipe()
            let staged = await Task.detached(priority: .userInitiated) { () -> [URL] in
                let directory = ImportStaging.directory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return files.compactMap { file in
                    let scoped = file.url.startAccessingSecurityScopedResource()
                    defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
                    let target = VaultFiles.uniqueURL(in: directory, for: file.name)
                    return (try? ImportValidator.copy(from: file.url, to: target, limit: file.limit)) == true ? target : nil
                }
            }.value
            if staged.count < files.count {
                message = "\(files.count - staged.count) file(s) couldn't be read."
            }
            self.staged = staged.isEmpty ? nil : staged
        }
    }

    func cancel() {
        pending = []
    }

    /// Closes the imported viewer and deletes the staged ciphertext.
    func close() {
        staged = nil
        ImportStaging.wipe()
    }

    private static func describe(_ rejection: ImportValidator.Rejection) -> String {
        switch rejection {
        case .notEncrypted: "This isn't an AES Camera photo or video."
        case .unreadable: "The file couldn't be read."
        case .tooLarge: "The file is too large."
        }
    }
}
