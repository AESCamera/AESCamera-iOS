import CryptoKit
import Foundation
import Testing
@testable import AESCore

/// Expected values computed independently with Python's hashlib/hmac and the openssl CLI
/// (see the generator script in the test plan). They pin the primitives to the same
/// definitions Java's JCA uses on Android.
@Suite struct ReferenceVectorTests {
    let salt = Array(0..<16 as Range<UInt8>)

    func derive(_ password: String, _ algorithm: KDFParameters.Algorithm) throws -> SymmetricKey {
        try KDF.derive(Secret(password), salt: salt,
                       parameters: KDFParameters(algorithm: algorithm, iterations: 1_000))
    }

    @Test func pbkdf2SHA256() throws {
        #expect(try derive("test-password", .pbkdf2SHA256).hex ==
            "0ac89cbd459b1c6b36b6d5a1e65b966122cfcd07627d57b3d3111ef5c27db611")
    }

    @Test func pbkdf2SHA1() throws {
        #expect(try derive("test-password", .pbkdf2SHA1).hex ==
            "ac84284f385ee4d9df612ace65a7a2e246a2593f18afba9177d5df1239da34da")
    }

    /// Passwords are UTF-8 as typed, never normalised: NFC and NFD forms derive different
    /// keys, exactly as on Android.
    @Test func nonASCIIPasswordsAreNotNormalised() throws {
        let nfc = "p\u{E4}ssw\u{F6}rd"
        let nfd = "pa\u{308}sswo\u{308}rd"
        #expect(try derive(nfc, .pbkdf2SHA256).hex ==
            "2f56986c68f37683f0c4f846ad3742cc90085e0bfdf205d7f45ec47e3caadce8")
        #expect(try derive(nfd, .pbkdf2SHA256).hex ==
            "8602ef6adaae267b928f7ae96bff28e72677294eedaec3209023e3fbfc5f259a")
        #expect(try derive("🔒key", .pbkdf2SHA256).hex ==
            "fc7e9a4cbc1446ab41adbb525e95afa55cc73452bf61779b7a4f1ddb074b46aa")
    }

    /// AES-256-CTR with a big-endian counter that carries out of the low bytes after the
    /// first block (IV ends in ff ff).
    @Test func ctrMatchesOpenSSL() throws {
        let key = try derive("test-password", .pbkdf2SHA256)
        let iv = Array(0..<14 as Range<UInt8>) + [0xFF, 0xFF]
        let plaintext = Data((0..<4096).map { UInt8($0 % 251) })

        let ciphertext = try CTRCipher(key: key, iv: iv).process(plaintext)
        #expect(ciphertext.prefix(48).hex ==
            "c6239b6491f7f5cbe0ca9f4b527ca4e18d38d32c6c93278f3cddf63f1cddf3fac44ef2e4fd3117df756a21aeefe36bec")
        #expect(Data(SHA256.hash(data: ciphertext)).hex ==
            "b380506722d8af1e4498383d22f7e88a1bdccd8f858f21a5823ff17881030191")
    }

    @Test func encvMacKey() throws {
        let key = try derive("test-password", .pbkdf2SHA256)
        #expect(EncvKeys.macKey(fileKey: key).hex ==
            "717bbdc18b42ebed9505b1ef176d65204d189fd162d3e4449ebf4e10b343f886")
    }

    /// `salt ‖ iv ‖ AES-256-CBC(PBKDF2-SHA1 65,536)` made by openssl opens through the
    /// normal photo path.
    @Test func legacyCBCFromOpenSSL() throws {
        let file = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
            "b32be6d3c91a33e352058b47c3d194917f1ce62d5cdf2a740013514e889e48ac")
        let plaintext = try ImageCrypto.open(file, secret: Secret("test-password"), cache: KeyCache())
        #expect(String(decoding: plaintext, as: UTF8.self) == "legacy photo bytes")
    }
}
