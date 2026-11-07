import Foundation
import Testing
@testable import AESCore

/// Ports of the video half of Android's EncryptionUtilsTest.
@Suite struct EncvTests {
    let secret = Secret(testPassword)

    func record(_ plaintext: Data, in dir: TempDir, header: EncvHeader? = nil,
                finishWith rotation: Int? = 0, chunk: Int = 7_777) throws -> URL {
        let url = dir.file("VID-\(UUID().uuidString).encv")
        let writer = try EncvWriter(url: url, secret: secret, header: header ?? EncvHeader())
        var offset = 0
        while offset < plaintext.count {
            let end = min(offset + chunk, plaintext.count)
            try writer.write(plaintext[offset..<end])
            offset = end
        }
        if let rotation { try writer.finish(rotationDegrees: rotation) } else { try writer.close() }
        return url
    }

    @Test func addToCounterCarriesAcrossBytes() {
        let zero = [UInt8](repeating: 0, count: 16)
        #expect(CTRCipher.addToCounter(zero, blocks: 0) == zero)
        #expect(CTRCipher.addToCounter(zero, blocks: 1)[15] == 1)
        let carried = CTRCipher.addToCounter(zero, blocks: 256)
        #expect(carried[14] == 1 && carried[15] == 0)
        let nearOverflow = (0..<16).map { $0 >= 8 ? UInt8(0xFF) : 0 }
        let wrapped = CTRCipher.addToCounter(nearOverflow, blocks: 1)
        #expect(wrapped[7] == 1)
        #expect(wrapped[8...].allSatisfy { $0 == 0 })
    }

    @Test func streamRoundTripAndLayout() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let plaintext = Data.random(200_000)
        let url = try record(plaintext, in: dir, finishWith: nil)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == EncvHeader.prefixSize + plaintext.count)

        let header = try EncvHeader.parse(bytes)
        #expect(header.version == 4)
        #expect(header.container == .fragmentedMP4)
        #expect(header.kdf == .image)
        #expect(!header.isAuthenticated)

        let reader = try EncvReader(url: url, secret: secret)
        #expect(reader.plaintextLength == UInt64(plaintext.count))
        #expect(try reader.read(at: 0, count: plaintext.count) == plaintext)
    }

    @Test func seekMatchesFullDecrypt() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let plaintext = Data.random(70_000)
        let reader = try EncvReader(url: try record(plaintext, in: dir), secret: secret)
        for offset in [0, 1, 15, 16, 17, 4096, 65_537] {
            let got = try reader.read(at: UInt64(offset), count: 1024)
            #expect(got == plaintext[offset..<min(offset + 1024, plaintext.count)], "offset \(offset)")
        }
        #expect(try reader.read(at: 69_990, count: 100).count == 10)
        #expect(try reader.read(at: 70_000, count: 100).isEmpty)
    }

    @Test func finishPatchesHeaderAndAppendsTrailerOnly() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let plaintext = Data.random(10_000)
        let header = try EncvHeader(container: .mpeg2TS)
        let unfinished = try record(plaintext, in: dir, header: header, finishWith: nil)
        let finished = dir.file("copy.encv")
        // Re-create the same stream with finish() to compare layouts.
        let writer = try EncvWriter(url: finished, secret: secret, header: header)
        try writer.write(plaintext)
        try writer.finish(rotationDegrees: 270)

        let before = try Data(contentsOf: unfinished)
        let after = try Data(contentsOf: finished)
        #expect(after.count == before.count + EncvHeader.trailerSize)
        let parsed = try EncvHeader.parse(after)
        #expect(parsed.rotationDegrees == 270)
        #expect(parsed.isAuthenticated)
        #expect(parsed.version == 4)
        #expect(parsed.kdf == .image)
        #expect(Array(after[(after.count - 36)..<(after.count - 32)]) == Array("AESM".utf8))
    }

    @Test func finishedVideoVerifiesAndReadsWithoutTrailer() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let plaintext = Data.random(100_000)
        let url = try record(plaintext, in: dir)
        #expect(EncvReader.verify(url: url, secret: secret) == .verified)
        let reader = try EncvReader(url: url, secret: secret)
        #expect(reader.plaintextLength == UInt64(plaintext.count))
        #expect(try reader.read(at: 0, count: 200_000) == plaintext)
    }

    @Test func verifyDetectsTamperedCiphertext() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10_000), in: dir)
        var bytes = try Data(contentsOf: url)
        bytes[EncvHeader.prefixSize + 5_000] &+= 1
        try bytes.write(to: url)
        #expect(EncvReader.verify(url: url, secret: secret) == .failed)
    }

    @Test func verifyDetectsTamperedHeader() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10_000), in: dir, header: try EncvHeader(container: .mpeg2TS), finishWith: 270)
        var bytes = try Data(contentsOf: url)
        bytes[6] = 0
        try bytes.write(to: url)
        #expect(EncvReader.verify(url: url, secret: secret) == .failed)
    }

    @Test func verifyDetectsStrippedTrailer() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10_000), in: dir)
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count - EncvHeader.trailerSize).write(to: url)
        #expect(EncvReader.verify(url: url, secret: secret) == .failed)
    }

    @Test func verifyRejectsWrongPassword() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10_000), in: dir)
        #expect(EncvReader.verify(url: url, secret: Secret("wrong-password")) == .failed)
    }

    @Test func unfinishedRecordingIsUnverified() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10_000), in: dir, finishWith: nil)
        #expect(try !EncvHeader.read(from: url).isAuthenticated)
        #expect(EncvReader.verify(url: url, secret: secret) == .unverified)
    }

    @Test func legacyV2FileIsUnverifiedAndStillDecrypts() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let plaintext = Data.random(10_000)
        let salt = Bytes.random(16), iv = Bytes.random(16)
        let key = try KeyCache.shared.key(for: secret, salt: salt, parameters: .legacy)
        let header = try EncvHeader(container: .mpeg2TS, version: 2)
        let url = dir.file("v2.encv")
        try (header.bytes() + Data(salt) + Data(iv) + CTRCipher(key: key, iv: iv).process(plaintext)).write(to: url)

        #expect(EncvReader.verify(url: url, secret: secret) == .unverified)
        let reader = try EncvReader(url: url, secret: secret)
        #expect(reader.header.kdf == .legacy)
        #expect(reader.header.trailerSize == 0)
        #expect(try reader.read(at: 0, count: 10_000) == plaintext)
    }

    @Test func headerRejectsBadValues() throws {
        var bytes = try EncvHeader().bytes()
        bytes[12] = 9
        #expect(throws: CryptoError.self) { try EncvHeader.parse(bytes) }

        var absurd = try EncvHeader().bytes()
        for index in 8...11 { absurd[index] = 0x7F }
        #expect(throws: CryptoError.self) { try EncvHeader.parse(absurd) }

        var unknownContainer = try EncvHeader().bytes()
        unknownContainer[5] = 3
        #expect(throws: CryptoError.self) { try EncvHeader.parse(unknownContainer) }

        #expect(throws: CryptoError.self) { try EncvHeader.parse(Data.random(16)) }
        #expect(throws: CryptoError.self) { try EncvHeader(version: 3, kdf: .image) }
        #expect(throws: CryptoError.self) { try EncvHeader(rotationDegrees: 45) }
    }

    @Test func androidHeaderBytesParse() throws {
        // AESV 04, TS, rotation 90, authenticated, 210,000 iterations, SHA-256.
        let bytes = Data(hex: "41455356040101010003345002000000")
        let header = try EncvHeader.parse(bytes)
        #expect(header.container == .mpeg2TS)
        #expect(header.rotationDegrees == 90)
        #expect(header.isAuthenticated)
        #expect(header.kdf == .image)
        #expect(header.bytes() == bytes)
    }

    @Test func writerRefusesToOverwrite() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = try record(Data.random(10), in: dir)
        #expect(throws: (any Error).self) { try EncvWriter(url: url, secret: secret, header: EncvHeader()) }
    }

    @Test func abortDeletesTheFile() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let url = dir.file("aborted.encv")
        let writer = try EncvWriter(url: url, secret: secret, header: EncvHeader())
        try writer.write(Data.random(1_000))
        writer.abort()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
