import Foundation
import Testing
@testable import AESCore

/// Ports of the photo half of Android's EncryptionUtilsTest.
@Suite struct ImageCryptoTests {
    let secret = Secret(testPassword)

    @Test func cbcRoundTrip() throws {
        let plaintext = Data.random(100_000)
        let encrypted = try LegacyCBC.encrypt(plaintext, secret: secret)
        #expect(!ImageCrypto.isAuthenticated(encrypted))
        #expect(try ImageCrypto.open(encrypted, secret: secret) == plaintext)
    }

    @Test func authenticatedRoundTrip() throws {
        let plaintext = Data.random(100_000)
        let encrypted = try ImageCrypto.seal(plaintext, secret: secret)
        #expect(ImageCrypto.isAuthenticated(encrypted))
        #expect(Array(encrypted.prefix(5)) == [0x41, 0x45, 0x53, 0x50, 1])
        #expect(Array(encrypted[5..<9]) == [0x00, 0x03, 0x34, 0x50]) // 210,000 BE
        #expect(encrypted.count == 25 + 12 + plaintext.count + 16)
        #expect(try ImageCrypto.open(encrypted, secret: secret) == plaintext)
    }

    @Test func iterationsComeFromTheHeader() throws {
        let plaintext = Data.random(1_000)
        let encrypted = try ImageCrypto.seal(plaintext, secret: secret, iterations: KDFParameters.thumbnail.iterations)
        #expect(try ImageCrypto.open(encrypted, secret: secret) == plaintext)
    }

    @Test func rejectsWrongPassword() throws {
        let encrypted = try ImageCrypto.seal(Data.random(1_000), secret: secret)
        #expect(throws: CryptoError.authenticationFailed) {
            try ImageCrypto.open(encrypted, secret: Secret("wrong-password"))
        }
    }

    @Test func rejectsTampering() throws {
        var encrypted = try ImageCrypto.seal(Data.random(1_000), secret: secret)
        encrypted[encrypted.count / 2] &+= 1
        #expect(throws: CryptoError.authenticationFailed) {
            try ImageCrypto.open(encrypted, secret: secret)
        }
    }

    @Test func rejectsAbsurdIterationCount() throws {
        var encrypted = try ImageCrypto.seal(Data.random(100), secret: secret)
        for index in 5...8 { encrypted[index] = 0x7F }
        #expect(throws: CryptoError.self) { try ImageCrypto.open(encrypted, secret: secret) }
    }

    @Test func prewarmedSaltEncryptsLikeAColdDerivation() throws {
        let cache = KeyCache()
        let salt = Bytes.random(16)
        _ = try cache.key(for: secret, salt: salt, parameters: .image)
        let warm = try ImageCrypto.seal(Data("x".utf8), secret: secret, salt: salt, cache: cache)
        #expect(Array(warm[9..<25]) == salt)
        #expect(try ImageCrypto.open(warm, secret: secret, cache: KeyCache()) == Data("x".utf8))
    }

    @Test func wipedSecretThrowsLocked() throws {
        let doomed = Secret("pw")
        doomed.wipe()
        #expect(throws: CryptoError.locked) {
            try ImageCrypto.seal(Data("x".utf8), secret: doomed, cache: KeyCache())
        }
    }

    @Test func cacheEvictsOldestBeyondCapacity() throws {
        let cache = KeyCache(capacity: 2)
        let fast = try KDFParameters(algorithm: .pbkdf2SHA256, iterations: 1)
        for _ in 0..<5 { _ = try cache.key(for: secret, salt: Bytes.random(16), parameters: fast) }
        #expect(cache.count == 2)
        cache.clear()
        #expect(cache.count == 0)
    }
}
