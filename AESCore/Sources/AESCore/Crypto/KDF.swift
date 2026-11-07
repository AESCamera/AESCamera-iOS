import CommonCrypto
import CryptoKit
import Foundation
import os

/// PBKDF2 parameters. Video headers (v4) store them as `algorithm id ‖ iterations`; photos
/// always use SHA-256 with the count from their header.
public struct KDFParameters: Hashable, Sendable {
    public enum Algorithm: UInt8, Sendable {
        case pbkdf2SHA1 = 1
        case pbkdf2SHA256 = 2
    }

    public let algorithm: Algorithm
    public let iterations: Int

    /// Upper bound for any count read from a file, so a crafted header can't stall the app.
    public static let maxIterations = 2_000_000

    /// Photos, the vault verifier and v4 videos.
    public static let image = KDFParameters(unchecked: .pbkdf2SHA256, 210_000)
    /// Thumbnails: the grid pays one derivation per tile.
    public static let thumbnail = KDFParameters(unchecked: .pbkdf2SHA256, 65_000)
    /// Legacy CBC photos and v2/v3 videos.
    public static let legacy = KDFParameters(unchecked: .pbkdf2SHA1, 65_536)

    public init(algorithm: Algorithm, iterations: Int) throws {
        guard (1...Self.maxIterations).contains(iterations) else {
            throw CryptoError.malformed("Bad iteration count: \(iterations)")
        }
        self.algorithm = algorithm
        self.iterations = iterations
    }

    /// Parses a stored algorithm id; unknown ids are rejected.
    public init(algorithmID: UInt8, iterations: Int) throws {
        guard let algorithm = Algorithm(rawValue: algorithmID) else {
            throw CryptoError.malformed("Unknown KDF algorithm id \(algorithmID)")
        }
        try self.init(algorithm: algorithm, iterations: iterations)
    }

    private init(unchecked algorithm: Algorithm, _ iterations: Int) {
        self.algorithm = algorithm
        self.iterations = iterations
    }
}

public enum KDF {
    public static let saltSize = 16
    static let keySize = 32

    /// A fresh random 16-byte salt for a photo or video key.
    public static func newSalt() -> [UInt8] {
        Bytes.random(saltSize)
    }

    /// PBKDF2 → 256-bit AES key. Uncached; use `KeyCache` in app code.
    public static func derive(_ secret: Secret, salt: [UInt8], parameters: KDFParameters) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: keySize)
        let prf = parameters.algorithm == .pbkdf2SHA1
            ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            : CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        let status: Int32 = try secret.withBytes { password in
            password.withMemoryRebound(to: CChar.self) { passwordChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordChars.baseAddress, passwordChars.count,
                    salt, salt.count,
                    prf, UInt32(parameters.iterations),
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw CryptoError.commonCrypto(status) }
        defer { for index in derived.indices { derived[index] = 0 } }
        return SymmetricKey(data: derived)
    }
}

/// LRU of derived keys, keyed by (algorithm, iterations, salt, password fingerprint).
///
/// Videos re-open on every seek and the viewer revisits files, so derivations are cached.
/// Prewarming is just an early lookup: derive the key for a salt generated ahead of time,
/// and the later encrypt with that salt is a cache hit. Cleared when the app locks.
public final class KeyCache: Sendable {
    public static let shared = KeyCache()

    private struct State {
        var keys: [String: SymmetricKey] = [:]
        var order: [String] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int = 16) {
        self.capacity = capacity
    }

    public func key(for secret: Secret, salt: [UInt8], parameters: KDFParameters) throws -> SymmetricKey {
        let cacheKey = "\(parameters.algorithm.rawValue):\(parameters.iterations):\(Bytes.hex(salt)):\(secret.fingerprint)"
        if let cached = state.withLock({ state -> SymmetricKey? in
            guard let key = state.keys[cacheKey] else { return nil }
            state.order.removeAll { $0 == cacheKey }
            state.order.append(cacheKey)
            return key
        }) {
            return cached
        }

        // Derive outside the lock: PBKDF2 takes tens of milliseconds.
        let key = try KDF.derive(secret, salt: salt, parameters: parameters)
        state.withLock { state in
            if state.keys[cacheKey] == nil {
                state.order.append(cacheKey)
            }
            state.keys[cacheKey] = key
            while state.order.count > capacity {
                state.keys.removeValue(forKey: state.order.removeFirst())
            }
        }
        return key
    }

    public func clear() {
        state.withLock { $0 = State() }
    }

    var count: Int {
        state.withLock { $0.keys.count }
    }
}
