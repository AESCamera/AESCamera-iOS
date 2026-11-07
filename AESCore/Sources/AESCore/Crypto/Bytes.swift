import Foundation
import Security

/// Errors raised by the format and crypto code.
public enum CryptoError: Error, Equatable, Sendable {
    /// The input ends before a required field.
    case truncated
    /// A header field is outside what this app reads (magic, version, KDF parameters).
    case malformed(String)
    /// AES-GCM tag mismatch: wrong password or tampered data.
    case authenticationFailed
    /// Legacy AES-CBC padding check failed: wrong password or corrupt data.
    case badPadding
    /// The password was wiped (the app locked) while it was still needed.
    case locked
    /// A CommonCrypto call failed with this status.
    case commonCrypto(Int32)
}

enum Bytes {
    /// Cryptographically secure random bytes.
    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// Reads a big-endian UInt32 at `offset` (relative to `data.startIndex`).
    static func readUInt32BE<D: DataProtocol>(_ data: D, at offset: Int) -> UInt32 where D.Index == Int {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16) |
            (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
