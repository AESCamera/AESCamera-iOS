import CryptoKit
import Foundation

/// The vault password, held as UTF-8 bytes that are overwritten when the app locks.
///
/// The bytes are exactly what Java's `PBEKeySpec(char[])` feeds PBKDF2 on Android: the
/// UTF-8 encoding of the string as typed, with **no Unicode normalisation**. Normalising
/// here would make passwords with composed characters open different vaults on the two
/// platforms.
///
/// `SecureField` still hands the app a `String` copy that can't be wiped; this only
/// keeps the long-lived copy wipeable.
public final class Secret: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]
    private var wiped = false

    /// A keyed digest of the password, for cache keys and "same password?" checks
    /// without keeping more copies of the password around. The key is random per
    /// process, so the digest is useless outside it.
    public let fingerprint: String

    private static let fingerprintKey = SymmetricKey(size: .bits256)

    public init(_ password: String) {
        bytes = Array(password.utf8)
        fingerprint = Bytes.hex(HMAC<SHA256>.authenticationCode(for: bytes, using: Self.fingerprintKey))
    }

    public var isEmpty: Bool {
        lock.withLock { bytes.isEmpty }
    }

    public var isWiped: Bool {
        lock.withLock { wiped }
    }

    /// Runs `body` with a temporary copy of the password bytes, zeroed afterwards. The
    /// lock isn't held while `body` runs, so parallel PBKDF2 derivations don't queue up.
    /// Throws `CryptoError.locked` after `wipe()`.
    public func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) throws -> R {
        var copy: [UInt8] = try lock.withLock {
            if wiped { throw CryptoError.locked }
            return bytes
        }
        defer { for index in copy.indices { copy[index] = 0 } }
        return try copy.withUnsafeBufferPointer(body)
    }

    /// Overwrites the password bytes. Later uses throw `CryptoError.locked`.
    public func wipe() {
        lock.withLock {
            for index in bytes.indices { bytes[index] = 0 }
            bytes.removeAll()
            wiped = true
        }
    }

    /// True if both secrets hold the same password.
    public func matches(_ other: Secret) -> Bool {
        fingerprint == other.fingerprint
    }
}
