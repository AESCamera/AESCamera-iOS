import CryptoKit
import Foundation

enum EncvKeys {
    static let macInfo = Data("AESCamera encv v3 mac".utf8)

    /// The trailer's HMAC key: one HMAC block keyed by the file's CTR key with a fixed info
    /// string (effectively HKDF-expand), so encryption and authentication keys differ.
    static func macKey(fileKey: SymmetricKey) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: macInfo, using: fileKey)))
    }
}

/// Write side of a recording: encrypts plaintext into the file (AES-CTR) while an HMAC
/// accumulates over the ciphertext (encrypt-then-MAC).
///
/// `finish` patches the final header and appends the trailer. A writer that's closed
/// without finishing leaves a playable but unverified file, the same state a crash mid
/// recording leaves. Not thread-safe: drive it from one queue.
public final class EncvWriter {
    public let url: URL
    public private(set) var plaintextBytesWritten: UInt64 = 0

    private let header: EncvHeader
    private let salt: [UInt8]
    private let iv: [UInt8]
    private let cipher: CTRCipher
    private var mac: HMAC<SHA256>
    private var handle: FileHandle?

    /// Creates `url` (which must not exist) and writes the prefix. `salt` may be one whose
    /// key was prewarmed in `cache`, so recording starts without paying PBKDF2.
    public init(
        url: URL,
        secret: Secret,
        header: EncvHeader,
        salt: [UInt8]? = nil,
        cache: KeyCache = .shared,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        let salt = salt ?? Bytes.random(EncvHeader.saltSize)
        precondition(salt.count == EncvHeader.saltSize, "Salt must be \(EncvHeader.saltSize) bytes")
        let iv = Bytes.random(EncvHeader.ivSize)
        let key = try cache.key(for: secret, salt: salt, parameters: header.kdf)

        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes)
        else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }

        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: header.bytes() + Data(salt) + Data(iv))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.url = url
        self.header = header
        self.salt = salt
        self.iv = iv
        self.cipher = try CTRCipher(key: key, iv: iv)
        self.mac = HMAC(key: EncvKeys.macKey(fileKey: key))
        self.handle = handle
    }

    /// Encrypts and appends `plaintext`.
    public func write(_ plaintext: Data) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let ciphertext = cipher.process(plaintext)
        mac.update(data: ciphertext)
        try handle.write(contentsOf: ciphertext)
        plaintextBytesWritten += UInt64(plaintext.count)
    }

    /// Closes the file without a trailer (an unfinished recording).
    public func close() throws {
        guard let handle else { return }
        self.handle = nil
        try handle.synchronize()
        try handle.close()
    }

    /// Patches the final header (rotation + authenticated flag) and appends the trailer.
    /// MAC input is ciphertext ‖ final header ‖ salt ‖ iv: the header comes last because
    /// its final contents are only known when recording ends.
    public func finish(rotationDegrees: Int = 0) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let finalHeader = try header.finalized(rotationDegrees: rotationDegrees)
        let headerBytes = finalHeader.bytes()
        mac.update(data: headerBytes)
        mac.update(data: salt)
        mac.update(data: iv)
        let tag = Data(mac.finalize())

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: headerBytes)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(EncvHeader.trailerMagic) + tag)
        try close()
    }

    /// Closes and deletes the file (ciphertext only). For failed recordings.
    public func abort() {
        try? close()
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        try? handle?.close()
    }
}

/// Random-access decrypted reads from an `.encv` file, for playback and thumbnails.
/// Thread-safe (reads are serialised).
public final class EncvReader: @unchecked Sendable {
    public let url: URL
    public let header: EncvHeader
    /// Size of the decrypted stream (the ciphertext between prefix and trailer).
    public let plaintextLength: UInt64

    private let key: SymmetricKey
    private let iv: [UInt8]
    private let handle: FileHandle
    private let lock = NSLock()

    public init(url: URL, secret: Secret, cache: KeyCache = .shared) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let prefix = try handle.read(upToCount: EncvHeader.prefixSize) ?? Data()
            guard prefix.count == EncvHeader.prefixSize else { throw CryptoError.truncated }
            let header = try EncvHeader.parse(prefix)
            let salt = Array(prefix[16..<32])
            let fileSize = try handle.seekToEnd()
            let end = fileSize - UInt64(header.trailerSize)
            guard end >= UInt64(EncvHeader.prefixSize) else { throw CryptoError.truncated }

            self.url = url
            self.header = header
            self.plaintextLength = end - UInt64(EncvHeader.prefixSize)
            self.iv = Array(prefix[32..<48])
            self.key = try cache.key(for: secret, salt: salt, parameters: header.kdf)
            self.handle = handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    /// Decrypts up to `count` bytes of the stream starting at `offset`. Returns fewer
    /// bytes at the end of the stream, and empty data past it.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < plaintextLength, count > 0 else { return Data() }
        let length = Int(min(UInt64(count), plaintextLength - offset))
        let ciphertext: Data = try lock.withLock {
            try handle.seek(toOffset: UInt64(EncvHeader.prefixSize) + offset)
            return try handle.read(upToCount: length) ?? Data()
        }
        return try CTRCipher(key: key, iv: iv, offset: offset).process(ciphertext)
    }

    /// Integrity check against the trailer. Reads the whole file: call off the main thread.
    public static func verify(url: URL, secret: Secret, cache: KeyCache = .shared) -> EncvVerification {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: EncvHeader.prefixSize) ?? Data()
            guard prefix.count == EncvHeader.prefixSize else { return .failed }
            let headerBytes = prefix[0..<16]
            let header = try EncvHeader.parse(headerBytes)
            guard header.isAuthenticated else { return .unverified }

            let fileSize = try handle.seekToEnd()
            guard fileSize >= UInt64(EncvHeader.prefixSize + EncvHeader.trailerSize) else { return .failed }
            let trailerStart = fileSize - UInt64(EncvHeader.trailerSize)

            let salt = Array(prefix[16..<32])
            let key = try cache.key(for: secret, salt: salt, parameters: header.kdf)
            var mac = HMAC<SHA256>(key: EncvKeys.macKey(fileKey: key))

            try handle.seek(toOffset: UInt64(EncvHeader.prefixSize))
            var remaining = trailerStart - UInt64(EncvHeader.prefixSize)
            while remaining > 0 {
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
                }
                guard !chunk.isEmpty else { return .failed }
                mac.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
            mac.update(data: headerBytes)
            mac.update(data: prefix[16..<48])
            let expected = mac.finalize()

            let trailer = try handle.read(upToCount: EncvHeader.trailerSize) ?? Data()
            guard trailer.count == EncvHeader.trailerSize,
                  Array(trailer.prefix(4)) == EncvHeader.trailerMagic
            else { return .failed }
            // HashedAuthenticationCode == Data compares in constant time.
            return expected == Data(trailer.suffix(32)) ? .verified : .failed
        } catch {
            return .failed
        }
    }
}
