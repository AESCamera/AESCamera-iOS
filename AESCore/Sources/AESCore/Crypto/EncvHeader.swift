import Foundation

/// Plaintext header of `.encv` (encrypted video) files:
/// ```
/// [ "AESV":4 ][ version:1 ][ container:1 ][ rotation/90:1 ][ flags:1 ]
/// [ v4+: kdf iterations:4 BE ][ v4+: kdf algorithm id:1 ][ reserved:3 ]
/// [ salt:16 ][ iv:16 ]
/// [ AES-256-CTR ciphertext … ]
/// [ v3+, finalised only: "AESM":4 ][ HMAC-SHA256:32 ]
/// ```
/// - v2: CTR, no integrity, legacy KDF (read only).
/// - v3: adds the HMAC trailer, written when the authenticated flag is set.
/// - v4: KDF parameters in the header (PBKDF2-SHA256 at the photo cost).
///
/// Containers: 1 = MPEG-2 TS (Android recordings; rotation lives in this header),
/// 2 = fragmented MP4 (iOS recordings; rotation lives in the track matrix and the header
/// rotation is always 0).
public struct EncvHeader: Equatable, Sendable {
    public enum Container: UInt8, Sendable {
        case mpeg2TS = 1
        case fragmentedMP4 = 2
    }

    public static let magic: [UInt8] = Array("AESV".utf8)
    public static let trailerMagic: [UInt8] = Array("AESM".utf8)

    public static let versionCTR: UInt8 = 2
    public static let versionAuthenticated: UInt8 = 3
    public static let versionKDF: UInt8 = 4

    public static let size = 16
    public static let saltSize = 16
    public static let ivSize = 16
    /// Where the ciphertext starts.
    public static let prefixSize = size + saltSize + ivSize // 48
    public static let trailerSize = 4 + 32

    public static let flagAuthenticated: UInt8 = 0x01

    public let version: UInt8
    public let container: Container
    public let rotationDegrees: Int
    public let flags: UInt8
    public let kdf: KDFParameters

    public init(
        container: Container = .fragmentedMP4,
        rotationDegrees: Int = 0,
        flags: UInt8 = 0,
        version: UInt8 = EncvHeader.versionKDF,
        kdf: KDFParameters? = nil
    ) throws {
        guard [0, 90, 180, 270].contains(rotationDegrees) else {
            throw CryptoError.malformed("Rotation must be 0/90/180/270, got \(rotationDegrees)")
        }
        guard (Self.versionCTR...Self.versionKDF).contains(version) else {
            throw CryptoError.malformed("Unsupported .encv version \(version)")
        }
        let kdf = kdf ?? (version >= Self.versionKDF ? .image : .legacy)
        guard version >= Self.versionKDF || kdf == .legacy else {
            throw CryptoError.malformed("Pre-v4 headers cannot carry KDF parameters")
        }
        self.version = version
        self.container = container
        self.rotationDegrees = rotationDegrees
        self.flags = flags
        self.kdf = kdf
    }

    /// True if the file was finalised with the authentication trailer.
    public var isAuthenticated: Bool {
        version >= Self.versionAuthenticated && (flags & Self.flagAuthenticated) != 0
    }

    /// Bytes after the ciphertext: the trailer, or 0 for v2 and unfinished files.
    public var trailerSize: Int {
        isAuthenticated ? Self.trailerSize : 0
    }

    /// The header written when recording finishes: final rotation, authenticated flag,
    /// at least v3 (a v4 header keeps its KDF parameters).
    public func finalized(rotationDegrees: Int) throws -> EncvHeader {
        try EncvHeader(
            container: container,
            rotationDegrees: rotationDegrees,
            flags: flags | Self.flagAuthenticated,
            version: max(version, Self.versionAuthenticated),
            kdf: kdf
        )
    }

    public func bytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes.replaceSubrange(0..<4, with: Self.magic)
        bytes[4] = version
        bytes[5] = container.rawValue
        bytes[6] = UInt8(rotationDegrees / 90)
        bytes[7] = flags
        if version >= Self.versionKDF {
            bytes.replaceSubrange(8..<12, with: Bytes.uint32BE(UInt32(kdf.iterations)))
            bytes[12] = kdf.algorithm.rawValue
        }
        return Data(bytes)
    }

    public static func parse<D: DataProtocol>(_ data: D) throws -> EncvHeader {
        let bytes = Array(data.prefix(size))
        guard bytes.count == size else { throw CryptoError.truncated }
        guard Array(bytes[0..<4]) == magic else { throw CryptoError.malformed("Not an .encv file") }
        let version = bytes[4]
        guard (versionCTR...versionKDF).contains(version) else {
            throw CryptoError.malformed("Unsupported .encv version \(version)")
        }
        guard let container = Container(rawValue: bytes[5]) else {
            throw CryptoError.malformed("Unknown .encv container \(bytes[5])")
        }
        let kdf: KDFParameters = version >= versionKDF
            ? try KDFParameters(algorithmID: bytes[12], iterations: Int(Bytes.readUInt32BE(bytes, at: 8)))
            : .legacy
        return try EncvHeader(
            container: container,
            rotationDegrees: Int(bytes[6]) * 90,
            flags: bytes[7],
            version: version,
            kdf: kdf
        )
    }

    public static func read(from url: URL) throws -> EncvHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(try handle.read(upToCount: size) ?? Data())
    }
}

/// Outcome of an `.encv` integrity check.
public enum EncvVerification: Sendable {
    /// Trailer present and correct: authentic and complete.
    case verified
    /// No trailer to check: a v2 file, or a recording that died before finishing.
    case unverified
    /// Trailer expected but wrong: tampered, corrupt, or the wrong password.
    case failed
}
