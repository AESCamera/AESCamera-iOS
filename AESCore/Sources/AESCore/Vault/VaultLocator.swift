import CryptoKit
import Foundation

/// Finds, creates and (for a duress password) wipes vault directories.
///
/// Vault directories have random names. Each holds a hidden verifier (`.vault`) sealed
/// with the password (AESP v1, 210k). The vault for a password is found by test-opening
/// verifiers, so the tree reveals nothing and every guess costs a full PBKDF2.
///
/// Any password opens a vault. Lookups never create anything; the app calls `create`
/// only when the first file is saved, so a mistyped password leaves nothing behind.
///
/// Verifier v2 (`VerifierPayload`) is one fixed size and carries the duress settings.
/// Older verifiers are rewritten as v2 when their vault is opened, the same way Android
/// does it: the v1 magic, a legacy CBC verifier, and an MD5(password)-named vault without
/// a verifier (adopted and renamed).
///
/// Only `unlock` acts on an armed (duress) vault. `find` and `match`, used by Settings,
/// never wipe.
public enum VaultLocator {
    public static let verifierName = ".vault"
    static let verifierMagicV1 = Data("AESCameraVault:v1".utf8)

    /// Leading bytes of each file overwritten before a wipe deletes it. Covers every
    /// header: without its salt a file key can't be derived, even with the password.
    static let shredBytes = 4096

    /// A vault a password opens, with the settings its verifier carries.
    public struct Match: Sendable {
        public let url: URL
        public let payload: VerifierPayload
    }

    /// The duress password already opens a vault; using it would make that vault a target.
    public struct DuressPasswordInUse: Error {}

    /// The existing vault for `secret` under `base`, or nil. Never creates or wipes.
    public static func find(
        _ secret: Secret,
        in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> URL? {
        try match(secret, in: base, cache: cache, verifierIterations: verifierIterations)?.url
    }

    /// The vault `secret` opens and its verifier settings, or nil. Never creates or wipes,
    /// but upgrades an older vault it finds (verifier format, MD5 name).
    public static func match(
        _ secret: Secret,
        in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> Match? {
        for directory in vaultDirectories(in: base) {
            if let payload = try readVerifier(in: directory, secret: secret, cache: cache, iterations: verifierIterations) {
                return Match(url: try renameIfLegacy(directory, secret: secret), payload: payload)
            }
        }

        let legacy = base.appendingPathComponent(try legacyName(for: secret), isDirectory: true)
        if isDirectory(legacy) {
            try writeVerifier(.plain, in: legacy, secret: secret, cache: cache, iterations: verifierIterations)
            return Match(url: try renameIfLegacy(legacy, secret: secret), payload: .plain)
        }
        return nil
    }

    /// Opens the vault for `secret` at the unlock prompt. If `secret` is a duress
    /// password, its targets are wiped first and the duress (decoy) vault is returned.
    public static func unlock(
        _ secret: Secret,
        in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> Match? {
        guard let match = try match(secret, in: base, cache: cache, verifierIterations: verifierIterations) else {
            return nil
        }
        if match.payload.armed {
            wipeTargets(of: match, in: base)
        }
        return match
    }

    /// Creates a new vault for `secret`. Only call when `find` returned nil.
    public static func create(
        _ secret: Secret,
        in base: URL,
        payload: VerifierPayload = .plain,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws -> URL {
        let vault = base.appendingPathComponent(randomName(), isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true, attributes: attributes)
        try writeVerifier(payload, in: vault, secret: secret, cache: cache, iterations: verifierIterations)
        return vault
    }

    // MARK: Duress password

    /// Sets up `duressSecret` as the duress password of `ownerVault` (opened by
    /// `ownerSecret`): creates its decoy vault, armed to wipe `scope`, and records it in
    /// the owner's verifier. Any duress vault the owner already had is wiped first.
    /// Runs several PBKDF2 derivations; call off the main thread.
    ///
    /// Throws `DuressPasswordInUse` if `duressSecret` is the owner's password or already
    /// opens a vault.
    @discardableResult
    public static func setDuress(
        owner ownerSecret: Secret, vault ownerVault: URL, duress duressSecret: Secret, scope: WipeScope, in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws -> Match {
        guard var owner = try readVerifier(in: ownerVault, secret: ownerSecret, cache: cache, iterations: verifierIterations) else {
            throw CryptoError.authenticationFailed
        }
        if try duressSecret.matches(ownerSecret)
            || match(duressSecret, in: base, cache: cache, verifierIterations: verifierIterations) != nil {
            throw DuressPasswordInUse()
        }
        if let previous = owner.duressVault {
            let url = base.appendingPathComponent(previous, isDirectory: true)
            if isDirectory(url) { wipe(vault: url) }
        }

        let payload = VerifierPayload(
            armed: true, wipeScope: scope, wipeTarget: scope == .thisVault ? ownerVault.lastPathComponent : nil
        )
        let decoy = try create(duressSecret, in: base, payload: payload, cache: cache,
                               verifierIterations: verifierIterations, attributes: attributes)
        owner.duressVault = decoy.lastPathComponent
        owner.duressScope = scope
        try writeVerifier(owner, in: ownerVault, secret: ownerSecret, cache: cache, iterations: verifierIterations)
        return Match(url: decoy, payload: payload)
    }

    /// Removes the duress password of `ownerVault`, wiping its decoy vault. Returns the
    /// owner's updated settings.
    @discardableResult
    public static func removeDuress(
        owner ownerSecret: Secret, vault ownerVault: URL, in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> VerifierPayload {
        guard var owner = try readVerifier(in: ownerVault, secret: ownerSecret, cache: cache, iterations: verifierIterations) else {
            throw CryptoError.authenticationFailed
        }
        if let name = owner.duressVault {
            let url = base.appendingPathComponent(name, isDirectory: true)
            if isDirectory(url) { wipe(vault: url) }
        }
        owner.duressVault = nil
        owner.duressScope = nil
        try writeVerifier(owner, in: ownerVault, secret: ownerSecret, cache: cache, iterations: verifierIterations)
        return owner
    }

    /// The decoy vault of `ownerVault` if `duressSecret` is its duress password, for
    /// adding decoy content from Settings. Never wipes anything.
    public static func duressVault(
        owner ownerSecret: Secret, vault ownerVault: URL, duress duressSecret: Secret, in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> URL? {
        guard let name = try readVerifier(in: ownerVault, secret: ownerSecret, cache: cache, iterations: verifierIterations)?
            .duressVault else { return nil }
        let url = base.appendingPathComponent(name, isDirectory: true)
        let payload = try readVerifier(in: url, secret: duressSecret, cache: cache, iterations: verifierIterations)
        return payload?.armed == true ? url : nil
    }

    // MARK: Wipe

    /// Wipes what an armed duress vault targets. Each target's verifier goes first, so
    /// even an interrupted wipe leaves the target unopenable; the next duress unlock
    /// finishes the rest.
    private static func wipeTargets(of match: Match, in base: URL) {
        let own = match.url.standardizedFileURL.lastPathComponent
        let targets: [URL] = switch match.payload.wipeScope {
        case .thisVault:
            match.payload.wipeTarget.map { [base.appendingPathComponent($0, isDirectory: true)] } ?? []
        case .allOthers:
            vaultDirectories(in: base)
        case nil:
            []
        }
        for target in targets where target.lastPathComponent != own && isDirectory(target) {
            wipe(vault: target)
        }
    }

    /// Shreds every file of `vault`, verifier first, then removes the directory tree.
    public static func wipe(vault: URL) {
        shred(vault.appendingPathComponent(verifierName))
        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                shred(url)
            }
        }
        try? fileManager.removeItem(at: vault)
    }

    /// Overwrites the leading bytes (every header and salt) with random data, syncs, then
    /// deletes.
    static func shred(_ url: URL) {
        if let handle = try? FileHandle(forUpdating: url) {
            if let size = try? handle.seekToEnd(), size > 0 {
                let count = Int(min(size, UInt64(shredBytes)))
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: Bytes.random(count))
                try? handle.synchronize()
            }
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Verifier

    /// The settings in `directory`'s verifier if `secret` opens it, else nil. A v1 or
    /// legacy CBC verifier that `secret` opens is rewritten as v2 in place.
    private static func readVerifier(in directory: URL, secret: Secret, cache: KeyCache, iterations: Int) throws -> VerifierPayload? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(verifierName)) else { return nil }
        let plain: Data
        do {
            plain = try ImageCrypto.open(bytes, secret: secret, cache: cache)
        } catch CryptoError.locked {
            throw CryptoError.locked
        } catch {
            return nil // wrong password or corrupt verifier
        }
        if let payload = VerifierPayload.decode(plain) { return payload }
        guard plain == verifierMagicV1 else { return nil }
        try writeVerifier(.plain, in: directory, secret: secret, cache: cache, iterations: iterations)
        return .plain
    }

    private static func writeVerifier(
        _ payload: VerifierPayload, in directory: URL, secret: Secret, cache: KeyCache, iterations: Int
    ) throws {
        let sealed = try ImageCrypto.seal(payload.encode(), secret: secret, iterations: iterations, cache: cache)
        try sealed.write(to: directory.appendingPathComponent(verifierName), options: [.atomic, .completeFileProtection])
    }

    private static func vaultDirectories(in base: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Renames an MD5-named vault (offline brute-forceable) to a random name. On failure
    /// the vault keeps working under its old name and the rename is retried next unlock.
    private static func renameIfLegacy(_ directory: URL, secret: Secret) throws -> URL {
        guard directory.lastPathComponent == (try legacyName(for: secret)) else { return directory }
        let renamed = directory.deletingLastPathComponent().appendingPathComponent(randomName(), isDirectory: true)
        do {
            try FileManager.default.moveItem(at: directory, to: renamed)
            return renamed
        } catch {
            return directory
        }
    }

    /// The pre-2026 Android vault name: hex MD5 of the password's UTF-8 bytes.
    static func legacyName(for secret: Secret) throws -> String {
        try secret.withBytes { Bytes.hex(Insecure.MD5.hash(data: $0)) }
    }

    static func randomName() -> String {
        Bytes.hex(Bytes.random(16))
    }
}
