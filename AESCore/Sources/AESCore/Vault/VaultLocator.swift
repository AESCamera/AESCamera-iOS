import CryptoKit
import Foundation

/// Finds or creates the vault directory for a password.
///
/// Vault directories have random names. Each holds a hidden verifier (`.vault`): a fixed
/// magic string sealed with the password (AESP v1, 210k). The vault for a password is
/// found by test-opening verifiers, so the tree reveals nothing and every guess costs a
/// full PBKDF2.
///
/// Any password opens a vault. `find` never creates anything; the app calls `create`
/// only when the first file is saved, so a mistyped password leaves nothing behind.
///
/// Android layouts copied in through the Files app are upgraded the same way Android
/// does it: a legacy CBC verifier is resealed, and an MD5(password)-named vault without a
/// verifier is adopted and renamed.
public enum VaultLocator {
    public static let verifierName = ".vault"
    static let verifierMagic = Data("AESCameraVault:v1".utf8)

    /// The existing vault for `secret` under `base`, or nil. Never creates one.
    public static func find(
        _ secret: Secret,
        in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations
    ) throws -> URL? {
        let fileManager = FileManager.default
        let children = (try? fileManager.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        let directories = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for directory in directories {
            if try verifierMatches(in: directory, secret: secret, cache: cache, iterations: verifierIterations) {
                return try renameIfLegacy(directory, secret: secret)
            }
        }

        let legacy = base.appendingPathComponent(try legacyName(for: secret), isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try writeVerifier(in: legacy, secret: secret, cache: cache, iterations: verifierIterations)
            return try renameIfLegacy(legacy, secret: secret)
        }
        return nil
    }

    /// Creates a new vault for `secret`. Only call when `find` returned nil.
    public static func create(
        _ secret: Secret,
        in base: URL,
        cache: KeyCache = .shared,
        verifierIterations: Int = KDFParameters.image.iterations,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws -> URL {
        let vault = base.appendingPathComponent(randomName(), isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true, attributes: attributes)
        try writeVerifier(in: vault, secret: secret, cache: cache, iterations: verifierIterations)
        return vault
    }

    private static func verifierMatches(in directory: URL, secret: Secret, cache: KeyCache, iterations: Int) throws -> Bool {
        let verifier = directory.appendingPathComponent(verifierName)
        guard let bytes = try? Data(contentsOf: verifier) else { return false }
        let isLegacy = !ImageCrypto.isAuthenticated(bytes)
        let matches: Bool
        do {
            matches = try ImageCrypto.open(bytes, secret: secret, cache: cache) == verifierMagic
        } catch CryptoError.locked {
            throw CryptoError.locked
        } catch {
            matches = false // wrong password or corrupt verifier
        }
        if matches && isLegacy {
            try writeVerifier(in: directory, secret: secret, cache: cache, iterations: iterations)
        }
        return matches
    }

    private static func writeVerifier(in directory: URL, secret: Secret, cache: KeyCache, iterations: Int) throws {
        let sealed = try ImageCrypto.seal(verifierMagic, secret: secret, iterations: iterations, cache: cache)
        try sealed.write(to: directory.appendingPathComponent(verifierName), options: .atomic)
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
