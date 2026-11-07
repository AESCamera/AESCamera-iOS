import CommonCrypto
import CryptoKit
import Foundation

/// Photos, thumbnails and the vault verifier (`.enc`).
///
/// Authenticated format v1 (all new writes):
/// ```
/// [ "AESP":4 | version:1 = 1 | iterations:4 BE | salt:16 ][ nonce:12 ][ AES-256-GCM ciphertext ‖ tag:16 ]
/// ```
/// The key derives from the password and header fields only (PBKDF2-SHA256), so a shared
/// or exported file opens anywhere with the password.
///
/// Legacy format (read only): `[ salt:16 ][ iv:16 ][ AES-256-CBC/PKCS7 ]`, PBKDF2-SHA1 at
/// 65,536 iterations, no authentication. Files without the magic take this path.
public enum ImageCrypto {
    static let magic: [UInt8] = Array("AESP".utf8)
    static let version: UInt8 = 1
    static let nonceSize = 12
    static let headerSize = 4 + 1 + 4 + KDF.saltSize // 25

    /// True if `data` starts with the v1 magic and version.
    public static func isAuthenticated<D: DataProtocol>(_ data: D) -> Bool {
        guard data.count >= magic.count + 1 else { return false }
        return data.prefix(magic.count).elementsEqual(magic) &&
            data[data.index(data.startIndex, offsetBy: magic.count)] == version
    }

    /// Seals `plaintext` in the v1 format. `salt` may be one prewarmed in `cache`.
    public static func seal(
        _ plaintext: Data,
        secret: Secret,
        iterations: Int = KDFParameters.image.iterations,
        salt: [UInt8]? = nil,
        cache: KeyCache = .shared
    ) throws -> Data {
        let salt = salt ?? Bytes.random(KDF.saltSize)
        precondition(salt.count == KDF.saltSize, "Salt must be \(KDF.saltSize) bytes")
        let parameters = try KDFParameters(algorithm: .pbkdf2SHA256, iterations: iterations)
        let key = try cache.key(for: secret, salt: salt, parameters: parameters)
        let nonce = try AES.GCM.Nonce(data: Bytes.random(nonceSize))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = sealed.combined else { throw CryptoError.malformed("No combined GCM box") }

        var out = Data(capacity: headerSize + combined.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(contentsOf: Bytes.uint32BE(UInt32(iterations)))
        out.append(contentsOf: salt)
        out.append(combined) // nonce ‖ ciphertext ‖ tag, Android's layout
        return out
    }

    /// Opens a v1 file, or a legacy CBC file when the magic is absent.
    public static func open(_ data: Data, secret: Secret, cache: KeyCache = .shared) throws -> Data {
        let data = Data(data) // zero-based indices
        guard isAuthenticated(data) else {
            return try LegacyCBC.decrypt(data, secret: secret, cache: cache)
        }
        guard data.count >= headerSize + nonceSize + 16 else { throw CryptoError.truncated }
        let iterations = Int(Bytes.readUInt32BE(data, at: 5))
        let parameters = try KDFParameters(algorithm: .pbkdf2SHA256, iterations: iterations)
        let salt = Array(data[9..<25])
        let key = try cache.key(for: secret, salt: salt, parameters: parameters)
        do {
            let box = try AES.GCM.SealedBox(combined: data[headerSize...])
            return try AES.GCM.open(box, using: key)
        } catch is CryptoKitError {
            throw CryptoError.authenticationFailed
        }
    }
}

/// Read path for pre-authentication photos. Never used for writing, except by tests.
enum LegacyCBC {
    static func decrypt(_ data: Data, secret: Secret, cache: KeyCache) throws -> Data {
        guard data.count >= 48, (data.count - 32) % 16 == 0 else { throw CryptoError.truncated }
        let salt = Array(data[0..<16])
        let iv = Array(data[16..<32])
        let key = try cache.key(for: secret, salt: salt, parameters: .legacy)
        return try crypt(CCOperation(kCCDecrypt), key: key, iv: iv, input: data[32...])
    }

    static func encrypt(_ plaintext: Data, secret: Secret, cache: KeyCache = .shared) throws -> Data {
        let salt = Bytes.random(16)
        let iv = Bytes.random(16)
        let key = try cache.key(for: secret, salt: salt, parameters: .legacy)
        return Data(salt + iv) + (try crypt(CCOperation(kCCEncrypt), key: key, iv: iv, input: plaintext[...]))
    }

    private static func crypt(_ operation: CCOperation, key: SymmetricKey, iv: [UInt8], input: Data.SubSequence) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inBytes in
                output.withUnsafeMutableBytes { outBytes in
                    CCCrypt(
                        operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count, iv,
                        inBytes.baseAddress, inBytes.count,
                        outBytes.baseAddress, outBytes.count, &moved
                    )
                }
            }
        }
        if status == kCCDecodeError { throw CryptoError.badPadding }
        guard status == kCCSuccess else { throw CryptoError.commonCrypto(status) }
        output.count = moved
        return output
    }
}
