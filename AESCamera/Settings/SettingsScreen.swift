import AESCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @Environment(AppSession.self) private var session
    @State private var pendingLocation: VaultLocation?
    @State private var exporting = false
    @State private var restoring = false
    @State private var progress: TransferProgress?
    @State private var message: String?

    var body: some View {
        @Bindable var settings = session.settings
        Form {
            Section {
                Picker("Vault location", selection: Binding(
                    get: { settings.vaultLocation },
                    set: { if $0 != settings.vaultLocation { pendingLocation = $0 } }
                )) {
                    Text("Private").tag(VaultLocation.private)
                    Text("Files app").tag(VaultLocation.shared)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(settings.vaultLocation == .private
                    ? "Encrypted files are kept where only AES Camera can reach them."
                    : "Encrypted files are visible in the Files app (On My iPhone › AES Camera). Other apps and people with your unlocked phone can see file names, dates and sizes, and delete files, but can't open them.")
            }

            Section {
                Button("Export Vault…") { exporting = true }
                    .disabled(session.vaultURL == nil)
                Button("Restore Files…") { restoring = true }
            } header: {
                Text("Backup")
            } footer: {
                Text("Exports copy the encrypted files to a folder you choose, such as iCloud Drive or a USB drive. They stay encrypted and open only with this password, on iPhone or Android.")
            }

            Section {
                Toggle("Rapid capture", isOn: $settings.rapidCapture)
                Toggle("Show last capture", isOn: $settings.showLastCapture)
            } header: {
                Text("Capture")
            } footer: {
                Text("Rapid capture keeps the shutter ready while earlier photos are still being encrypted. Show last capture puts your latest photo or video on the camera screen's vault button.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("Source code (MPL-2.0)", destination: URL(string: "https://github.com/AESCamera/AESCamera-iOS")!)
                Text("iOS can't block screenshots. AES Camera hides your vault in the app switcher and while the screen is recorded or mirrored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(moveTitle, isPresented: Binding(get: { pendingLocation != nil }, set: { if !$0 { pendingLocation = nil } }), titleVisibility: .visible) {
            Button("Move") { if let pendingLocation { move(to: pendingLocation) } }
        } message: {
            Text("All vaults are moved, for every password. Nothing is decrypted.")
        }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { export(to: folder) }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { restore(urls) }
        }
        .sheet(item: $progress) { progress in
            ProgressSheet(progress: progress)
                .interactiveDismissDisabled()
                .presentationDetents([.height(220)])
        }
        .alert("AES Camera", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var moveTitle: String {
        pendingLocation == .shared ? "Move the vault to the Files app?" : "Move the vault to private storage?"
    }

    private func move(to location: VaultLocation) {
        let tracker = TransferProgress(title: "Moving vault…")
        progress = tracker
        Task {
            do {
                try await session.moveVault(to: location, isCancelled: tracker.isCancelledCheck, progress: tracker.reporter)
            } catch is VaultMoveCancelled {
                message = "Move cancelled. Nothing was changed."
            } catch {
                message = "The vault couldn't be moved: \(error.localizedDescription). Nothing was changed."
            }
            progress = nil
        }
    }

    private func export(to folder: URL) {
        guard let vault = session.vaultURL else { return }
        let tracker = TransferProgress(title: "Exporting…")
        progress = tracker
        Task {
            do {
                let summary = try await Task.detached {
                    try VaultTransfer.export(VaultFiles.backupFiles(in: vault), to: folder,
                                             isCancelled: tracker.isCancelledCheck, progress: tracker.reporter)
                }.value
                message = summary.failed == 0
                    ? "Exported \(summary.exported) file(s) to \(summary.folderName)."
                    : "Exported \(summary.exported) file(s); \(summary.failed) failed."
            } catch is VaultMoveCancelled {
                message = "Export cancelled."
            } catch {
                message = error.localizedDescription
            }
            progress = nil
        }
    }

    private func restore(_ urls: [URL]) {
        let tracker = TransferProgress(title: "Restoring…")
        progress = tracker
        Task {
            do {
                let vault = try await session.ensureVault()
                guard let secret = session.secret else { return }
                let summary = try await Task.detached {
                    try await VaultTransfer.restore(urls, into: vault, secret: secret,
                                                    isCancelled: tracker.isCancelledCheck, progress: tracker.reporter)
                }.value
                var parts = ["Restored \(summary.restored)"]
                if summary.alreadyThere > 0 { parts.append("\(summary.alreadyThere) already in the vault") }
                if summary.wrongPassword > 0 { parts.append("\(summary.wrongPassword) under another password") }
                if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
                message = parts.joined(separator: ", ") + "."
                session.vaultDidChange()
            } catch is VaultMoveCancelled {
                message = "Restore cancelled. Files restored so far were kept."
                session.vaultDidChange()
            } catch {
                message = error.localizedDescription
            }
            progress = nil
        }
    }
}

/// Progress of a long file operation, reported from a background task.
@MainActor @Observable
final class TransferProgress: Identifiable {
    let id = UUID()
    let title: String
    private(set) var done = 0
    private(set) var total = 0
    @ObservationIgnored private let cancelled = CancelFlag()

    init(title: String) {
        self.title = title
    }

    func cancel() { cancelled.set() }

    nonisolated var isCancelledCheck: @Sendable () -> Bool {
        let flag = cancelled
        return { flag.value }
    }

    nonisolated var reporter: @Sendable (Int, Int) -> Void {
        { [weak self] done, total in
            Task { @MainActor in
                self?.done = done
                self?.total = total
            }
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

struct ProgressSheet: View {
    let progress: TransferProgress

    var body: some View {
        VStack(spacing: 16) {
            Text(progress.title).font(.headline)
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("\(progress.done) of \(progress.total)").font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Button("Cancel", role: .cancel) { progress.cancel() }
        }
        .padding(24)
    }
}
