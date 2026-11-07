import AESCore
import Foundation
import Observation
import SwiftUI

/// Lock state, the password and the current vault. The iOS counterpart of Android's
/// `AESCameraApplication` + `ProtectedBaseActivity`.
///
/// - Unlock looks up an existing vault (one PBKDF2 per vault scanned, off the main
///   actor). Nothing is created; `ensureVault()` creates the vault on the first save.
/// - The app locks as soon as it goes to the background: iOS can suspend it at any time,
///   so a grace-period timer isn't reliable.
@MainActor @Observable
final class AppSession {
    enum State: Equatable {
        case locked
        case unlocking
        case unlocked
    }

    private(set) var state: State = .locked
    /// The password while unlocked. Wiped on lock.
    private(set) var secret: Secret?
    /// The vault of the current password, nil while locked or before the first save.
    private(set) var vaultURL: URL?
    /// Bumped whenever the vault contents change in a way list screens should reload for.
    private(set) var vaultRevision = 0

    let settings = AppSettings()

    @ObservationIgnored private var vaultCreation: Task<URL, Error>?
    @ObservationIgnored private var lockHandlers: [UUID: @MainActor () -> Void] = [:]

    // Salts whose keys are already derived into `KeyCache.shared`, so the shutter pays
    // only AES-GCM, not PBKDF2.
    @ObservationIgnored private var preparedPhotoSalt: [UInt8]?
    @ObservationIgnored private var preparedVideoSalt: [UInt8]?
    @ObservationIgnored private var prewarming = false

    var isUnlocked: Bool { state == .unlocked }

    var baseURL: URL { VaultStorage.baseURL(for: settings.vaultLocation) }

    // MARK: Unlock / lock

    func unlock(password: String) async {
        guard state == .locked, !password.isEmpty else { return }
        state = .unlocking
        let secret = Secret(password)
        let base = baseURL
        let vault = await Task.detached(priority: .userInitiated) {
            try? VaultLocator.find(secret, in: base)
        }.value
        // Locked (backgrounded) while unlocking: drop the result.
        guard state == .unlocking else {
            secret.wipe()
            return
        }
        self.secret = secret
        vaultURL = vault
        vaultRevision += 1
        state = .unlocked
        prewarmKeys()
    }

    /// Clears the password, derived keys and every handle on vault content.
    func lock() {
        guard state != .locked else { return }
        for handler in lockHandlers.values { handler() }
        state = .locked
        secret?.wipe()
        secret = nil
        vaultURL = nil
        vaultCreation = nil
        preparedPhotoSalt = nil
        preparedVideoSalt = nil
        KeyCache.shared.clear()
        ThumbnailStore.shared.purge()
        VerificationCache.shared.purge()
        vaultRevision += 1
    }

    /// Runs `handler` just before every lock (stop a recording, drop decoded images).
    func onLock(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        lockHandlers[id] = handler
        return id
    }

    func removeLockHandler(_ id: UUID) {
        lockHandlers[id] = nil
    }

    // MARK: Vault

    /// The vault for the current password, created on first use. Throws when locked.
    func ensureVault() async throws -> URL {
        if let vaultURL { return vaultURL }
        guard let secret else { throw CryptoError.locked }
        if let vaultCreation { return try await vaultCreation.value }

        let base = baseURL
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            try VaultStorage.prepare(base)
            return try VaultLocator.create(secret, in: base, attributes: FileProtection.directoryAttributes)
        }
        vaultCreation = task
        defer { vaultCreation = nil }
        let created = try await task.value
        // Locked or re-keyed while creating.
        guard self.secret === secret else { throw CryptoError.locked }
        vaultURL = created
        return created
    }

    func vaultDidChange() {
        vaultRevision += 1
    }

    /// Moves the whole vault tree to `location` (cancellable), then finds the vault again.
    func moveVault(
        to location: VaultLocation,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        guard location != settings.vaultLocation else { return }
        let from = VaultStorage.baseURL(for: settings.vaultLocation)
        let to = VaultStorage.baseURL(for: location)
        try await Task.detached(priority: .userInitiated) {
            try VaultStorage.migrate(from: from, to: to, isCancelled: isCancelled, progress: progress)
            try VaultStorage.prepare(to)
        }.value
        settings.vaultLocation = location
        if let secret {
            let base = to
            vaultURL = await Task.detached { try? VaultLocator.find(secret, in: base) }.value
        }
        vaultRevision += 1
    }

    // MARK: Key prewarming

    /// Derives the next photo and video keys in the background if they aren't ready.
    /// Cheap to call often (after every save, on unlock, on a mode switch).
    func prewarmKeys() {
        guard let secret, !prewarming, preparedPhotoSalt == nil || preparedVideoSalt == nil else { return }
        prewarming = true
        let needPhoto = preparedPhotoSalt == nil
        let needVideo = preparedVideoSalt == nil
        Task {
            let (photo, video) = await Task.detached(priority: .utility) { () -> ([UInt8]?, [UInt8]?) in
                func prepare(_ needed: Bool, _ parameters: KDFParameters) -> [UInt8]? {
                    guard needed else { return nil }
                    let salt = KDF.newSalt()
                    return (try? KeyCache.shared.key(for: secret, salt: salt, parameters: parameters)) != nil ? salt : nil
                }
                return (prepare(needPhoto, .image), prepare(needVideo, .image))
            }.value
            prewarming = false
            guard self.secret === secret else { return }
            if let photo { preparedPhotoSalt = photo }
            if let video { preparedVideoSalt = video }
        }
    }

    /// A salt with a pre-derived photo key, or nil (the save derives on the spot).
    func takePhotoSalt() -> [UInt8]? {
        defer { preparedPhotoSalt = nil }
        return preparedPhotoSalt
    }

    func takeVideoSalt() -> [UInt8]? {
        defer { preparedVideoSalt = nil }
        return preparedVideoSalt
    }

    // MARK: Lifecycle

    func scenePhaseChanged(to phase: ScenePhase) {
        if phase == .background {
            lock()
        }
    }
}

/// Data-protection classes for vault content.
enum FileProtection {
    /// Vault directories: new files inherit "complete" (unreadable while the phone is locked).
    static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.complete]
    }

    /// A recording in progress keeps an open handle, so it can finish writing its trailer
    /// if the phone locks mid-recording. Set back to `complete` afterwards.
    static var recordingAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUnlessOpen]
    }

    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    static func markComplete(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
}
