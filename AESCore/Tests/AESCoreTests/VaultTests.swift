import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AESCore

/// Fast verifier cost for tests; one test keeps the real 210k.
private let fast = 1_000

@Suite struct VaultLocatorTests {
    @Test func createsRandomNamedVaultAndFindsItAgain() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let secret = Secret("correct horse")
        #expect(try VaultLocator.find(secret, in: dir.url) == nil)
        let vault = try VaultLocator.create(secret, in: dir.url) // real cost
        #expect(vault.lastPathComponent.count == 32)
        #expect(vault.lastPathComponent != (try VaultLocator.legacyName(for: secret)))
        let verifier = try Data(contentsOf: vault.appendingPathComponent(".vault"))
        #expect(ImageCrypto.isAuthenticated(verifier))
        #expect(try VaultLocator.find(secret, in: dir.url)?.standardizedFileURL == vault.standardizedFileURL)
    }

    @Test func findNeverCreates() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        #expect(try VaultLocator.find(Secret("typo"), in: dir.url, verifierIterations: fast) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
        // A base dir that doesn't exist yet is simply empty.
        #expect(try VaultLocator.find(Secret("typo"), in: dir.file("missing"), verifierIterations: fast) == nil)
    }

    @Test func differentPasswordsGetDifferentVaults() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let a = try VaultLocator.create(Secret("key-a"), in: dir.url, verifierIterations: fast)
        let b = try VaultLocator.create(Secret("key-b"), in: dir.url, verifierIterations: fast)
        #expect(a != b)
        #expect(try VaultLocator.find(Secret("key-a"), in: dir.url)?.lastPathComponent == a.lastPathComponent)
        #expect(try VaultLocator.find(Secret("key-b"), in: dir.url)?.lastPathComponent == b.lastPathComponent)
        #expect(try VaultLocator.find(Secret("key-c"), in: dir.url) == nil)
    }

    @Test func legacyMD5VaultIsAdoptedAndRenamed() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let secret = Secret("test")
        // MD5("test"), as Android's CommonUtils.getKeyDigest computes it.
        let legacyName = "098f6bcd4621d373cade4e832627b4f6"
        #expect(try VaultLocator.legacyName(for: secret) == legacyName)
        let legacy = dir.file(legacyName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: legacy.appendingPathComponent("IMG-1.enc"))

        let vault = try #require(try VaultLocator.find(secret, in: dir.url, verifierIterations: fast))
        #expect(vault.lastPathComponent != legacyName)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("IMG-1.enc").path))
        #expect(try VaultLocator.find(secret, in: dir.url)?.lastPathComponent == vault.lastPathComponent)
    }

    @Test func legacyCBCVerifierIsAcceptedAndUpgraded() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let secret = Secret("legacy key")
        let vault = dir.file("0123456789abcdef0123456789abcdef")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try LegacyCBC.encrypt(VaultLocator.verifierMagic, secret: secret).write(to: vault.appendingPathComponent(".vault"))

        #expect(try VaultLocator.find(secret, in: dir.url, verifierIterations: fast)?.lastPathComponent == vault.lastPathComponent)
        #expect(ImageCrypto.isAuthenticated(try Data(contentsOf: vault.appendingPathComponent(".vault"))))
        #expect(try VaultLocator.find(secret, in: dir.url)?.lastPathComponent == vault.lastPathComponent)
    }

    @Test func wipedSecretIsReportedNotTreatedAsWrongPassword() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let secret = Secret("pw")
        _ = try VaultLocator.create(secret, in: dir.url, verifierIterations: fast)
        secret.wipe()
        #expect(throws: CryptoError.locked) { try VaultLocator.find(secret, in: dir.url, cache: KeyCache()) }
    }
}

@Suite struct MediaNamesTests {
    @Test func generatedNamesRoundTripTheCaptureTime() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000.123)
        let photo = MediaNames.newPhotoName(at: date)
        #expect(photo.hasPrefix("IMG-") && photo.hasSuffix(".enc"))
        #expect(photo.count == "IMG-yyyy-MM-dd-HH-mm-ss-SSS.enc".count)
        let parsed = try #require(MediaNames.captureDate(fromName: photo))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)

        let video = MediaNames.newVideoName(at: date)
        #expect(MediaNames.isVideo(video))
        #expect(MediaNames.captureDate(fromName: video) == parsed)
        // An import's "-1" suffix keeps the time.
        #expect(MediaNames.captureDate(fromName: photo.replacingOccurrences(of: ".enc", with: "-1.enc")) == parsed)
    }

    @Test func foreignNamesHaveNoCaptureTime() {
        #expect(MediaNames.captureDate(fromName: "holiday.enc") == nil)
        #expect(MediaNames.captureDate(fromName: "IMG-garbage.enc") == nil)
    }

    @Test func mediaFilter() {
        #expect(MediaNames.isMedia("IMG-1.enc"))
        #expect(MediaNames.isMedia("clip.ENCV"))
        #expect(!MediaNames.isMedia(".vault"))
        #expect(!MediaNames.isMedia(".hidden.enc"))
        #expect(!MediaNames.isMedia("notes.txt"))
    }

    @Test func listingIsNewestFirstAndSkipsNonMedia() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let old = MediaNames.newPhotoName(at: Date(timeIntervalSince1970: 1_700_000_000))
        let new = MediaNames.newVideoName(at: Date(timeIntervalSince1970: 1_800_000_000))
        for name in [old, new, ".vault", "readme.txt"] {
            try Data([0]).write(to: dir.file(name))
        }
        try FileManager.default.createDirectory(at: dir.file(".thumbs"), withIntermediateDirectories: true)
        let items = VaultFiles.media(in: dir.url)
        #expect(items.map(\.name) == [new, old])
        #expect(items[0].isVideo && !items[1].isVideo)
        #expect(VaultFiles.backupFiles(in: dir.url).map(\.lastPathComponent) == [".vault", old, new])
        #expect(VaultFiles.media(in: nil).isEmpty)
        #expect(VaultFiles.media(in: dir.file("missing")).isEmpty)
    }

    @Test func uniqueNames() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        #expect(VaultFiles.uniqueURL(in: dir.url, for: "a.enc").lastPathComponent == "a.enc")
        try Data().write(to: dir.file("a.enc"))
        try Data().write(to: dir.file("a-1.enc"))
        #expect(VaultFiles.uniqueURL(in: dir.url, for: "a.enc").lastPathComponent == "a-2.enc")
    }
}

@Suite struct ImportValidatorTests {
    @Test func displayNamesCannotEscapeTheVault() {
        #expect(ImportValidator.sanitizeName("../../x.enc", isVideo: false) == "x.enc")
        #expect(ImportValidator.sanitizeName("..\\..\\x.enc", isVideo: false) == "x.enc")
        #expect(ImportValidator.sanitizeName(".vault.enc", isVideo: false) == "vault.enc")
        #expect(ImportValidator.sanitizeName("IMG-2026-11-04 a/b.enc", isVideo: false) == "b.enc")
        #expect(ImportValidator.sanitizeName("IMG 2026 a.enc", isVideo: false) == "IMG_2026_a.enc")
    }

    @Test func nonASCIIBecomesOneUnderscorePerCodePoint() {
        // Matches Java's regex, which works on code points.
        #expect(ImportValidator.sanitizeName("pa\u{308}.enc", isVideo: false) == "pa_.enc")
        #expect(ImportValidator.sanitizeName("🔒.enc", isVideo: false) == "_.enc")
    }

    @Test func unusableNamesAreReplaced() {
        #expect(ImportValidator.sanitizeName(nil, isVideo: false).hasPrefix("IMG-"))
        #expect(ImportValidator.sanitizeName("", isVideo: true).hasSuffix(".encv"))
        #expect(ImportValidator.sanitizeName(".enc", isVideo: false).hasPrefix("IMG-"))
        #expect(ImportValidator.sanitizeName("clip.enc", isVideo: true).hasSuffix(".encv"))
        let long = ImportValidator.sanitizeName(String(repeating: "a", count: 300) + ".enc", isVideo: false)
        #expect(long.count <= 120)
        // A truncated tail must not start with a dot (a hidden file).
        let dotted = ImportValidator.sanitizeName(String(repeating: "a", count: 300) + "." + String(repeating: "b", count: 115) + ".enc", isVideo: false)
        #expect(!dotted.hasPrefix("."))
    }

    @Test func magicBytesGateWhatIsOpened() throws {
        let secret = Secret("pw")
        let photo = try ImageCrypto.seal(Data.random(100), secret: secret, iterations: fast)
        #expect(ImportValidator.looksEncrypted(head: photo, size: Int64(photo.count), isVideo: false))

        let legacy = try LegacyCBC.encrypt(Data.random(100), secret: secret)
        let head = legacy.prefix(48)
        #expect(ImportValidator.looksEncrypted(head: head, size: Int64(legacy.count), isVideo: false))
        #expect(ImportValidator.looksEncrypted(head: head, size: nil, isVideo: false))
        #expect(!ImportValidator.looksEncrypted(head: head, size: Int64(legacy.count + 1), isVideo: false))

        let video = try EncvHeader(container: .mpeg2TS).bytes() + Data.random(32)
        #expect(ImportValidator.looksEncrypted(head: video, size: 10_000, isVideo: true))
        #expect(!ImportValidator.looksEncrypted(head: Data.random(48), size: 10_000, isVideo: true))
        #expect(!ImportValidator.looksEncrypted(head: video.prefix(10), size: 10_000, isVideo: true))
    }

    @Test func inspectChecksExtensionContentAndName() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let photo = dir.file("my photo.enc")
        try ImageCrypto.seal(Data.random(100), secret: Secret("pw"), iterations: fast).write(to: photo)
        let accepted = try ImportValidator.inspect(photo).get()
        #expect(accepted.name == "my_photo.enc")
        #expect(!accepted.isVideo)

        let fake = dir.file("fake.encv")
        try Data.random(100).write(to: fake)
        #expect(ImportValidator.inspect(fake) == .failure(.notEncrypted))

        let text = dir.file("notes.txt")
        try Data("hi".utf8).write(to: text)
        #expect(ImportValidator.inspect(text) == .failure(.notEncrypted))
        #expect(ImportValidator.inspect(dir.file("gone.enc")) == .failure(.unreadable))
    }

    @Test func copyStopsAtTheLimit() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let source = dir.file("src")
        let data = Data.random(600_000)
        try data.write(to: source)
        #expect(try ImportValidator.copy(from: source, to: dir.file("ok"), limit: 600_000))
        #expect(try Data(contentsOf: dir.file("ok")) == data)
        #expect(try !ImportValidator.copy(from: source, to: dir.file("capped"), limit: 300_000))
        #expect(!FileManager.default.fileExists(atPath: dir.file("capped").path))
    }
}

@Suite struct VaultStorageTests {
    @Test func migrateMovesTheTreeAndTheVaultIsFoundAgain() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let from = dir.file("from"), to = dir.file("to")
        let secret = Secret("pw")
        let vault = try VaultLocator.create(secret, in: from, verifierIterations: fast)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".thumbs"), withIntermediateDirectories: true)
        try Data([1]).write(to: vault.appendingPathComponent("IMG-a.enc"))
        try Data([2]).write(to: vault.appendingPathComponent(".thumbs/IMG-a.enc"))

        var reported: [(Int, Int)] = []
        try VaultStorage.migrate(from: from, to: to, progress: { reported.append(($0, $1)) })
        #expect(!FileManager.default.fileExists(atPath: from.path))
        let moved = try #require(try VaultLocator.find(secret, in: to))
        #expect(moved.lastPathComponent == vault.lastPathComponent)
        #expect(try Data(contentsOf: moved.appendingPathComponent(".thumbs/IMG-a.enc")) == Data([2]))
        #expect(reported.last.map { $0.0 == $0.1 && $0.1 == 3 } == true)
    }

    @Test func cancelLeavesTheSourceIntact() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let from = dir.file("from"), to = dir.file("to")
        let vault = try VaultLocator.create(Secret("pw"), in: from, verifierIterations: fast)
        for index in 0..<3 { try Data([UInt8(index)]).write(to: vault.appendingPathComponent("IMG-\(index).enc")) }

        var calls = 0
        #expect(throws: VaultMoveCancelled.self) {
            try VaultStorage.migrate(from: from, to: to, isCancelled: { calls += 1; return calls > 2 })
        }
        #expect(VaultStorage.files(under: from).count == 4)
        #expect(VaultStorage.files(under: to).isEmpty)
    }

    @Test func sameDirectoryIsANoOp() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        try Data([1]).write(to: dir.file("x"))
        try VaultStorage.migrate(from: dir.url, to: dir.url)
        #expect(FileManager.default.fileExists(atPath: dir.file("x").path))
    }
}

@Suite struct VaultImporterTests {
    let secret = Secret("pw")

    @Test func importsPhotoBuildsThumbnailAndSkipsIdenticalReimport() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let vault = dir.file("vault")
        let staged = dir.file("shared.enc")
        let jpeg = try #require(TestImages.jpeg(width: 800, height: 600))
        try ImageCrypto.seal(jpeg, secret: secret, iterations: fast).write(to: staged)

        var thumbnailed: [String] = []
        let first = try VaultImporter.importFile(staged, preferredName: "shared.enc", into: vault, secret: secret) { item, photo in
            #expect(photo == jpeg)
            thumbnailed.append(item.name)
        }
        guard case .imported(let item) = first else { Issue.record("not imported: \(first)"); return }
        #expect(item.name == "shared.enc")
        #expect(thumbnailed == ["shared.enc"])

        let again = try VaultImporter.importFile(staged, preferredName: "shared.enc", into: vault, secret: secret)
        #expect(again == .alreadyInVault(item))
        #expect(VaultFiles.media(in: vault).count == 1)
    }

    @Test func identicalBytesUnderAnotherNameAreRecognised() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let vault = dir.file("vault")
        let staged = dir.file("IMG-2026-01-01-00-00-00-000.enc")
        try ImageCrypto.seal(Data.random(10), secret: secret, iterations: fast).write(to: staged)
        guard case .imported(let first) = try VaultImporter.importFile(staged, preferredName: staged.lastPathComponent, into: vault, secret: secret) else {
            Issue.record("not imported"); return
        }
        let renamed = try VaultImporter.importFile(staged, preferredName: "shared photo.enc", into: vault, secret: secret)
        #expect(renamed == .alreadyInVault(first))
        #expect(VaultFiles.media(in: vault).count == 1)
    }

    @Test func differentBytesUnderTheSameNameGetASuffix() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let vault = dir.file("vault")
        for index in 0..<2 {
            let staged = dir.file("s\(index).enc")
            try ImageCrypto.seal(Data.random(10), secret: secret, iterations: fast).write(to: staged)
            _ = try VaultImporter.importFile(staged, preferredName: "same.enc", into: vault, secret: secret)
        }
        #expect(Set(VaultFiles.media(in: vault).map(\.name)) == ["same.enc", "same-1.enc"])
    }

    @Test func foreignPasswordIsRejectedAndRemoved() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let vault = dir.file("vault")
        let photo = dir.file("p.enc"), video = dir.file("v.encv")
        try ImageCrypto.seal(Data.random(10), secret: Secret("other"), iterations: fast).write(to: photo)
        let writer = try EncvWriter(url: video, secret: Secret("other"), header: EncvHeader())
        try writer.write(Data.random(1_000))
        try writer.finish()

        #expect(try VaultImporter.importFile(photo, preferredName: "p.enc", into: vault, secret: secret) == .wrongPassword)
        #expect(try VaultImporter.importFile(video, preferredName: "v.encv", into: vault, secret: secret) == .wrongPassword)
        #expect(VaultFiles.media(in: vault).isEmpty)
    }
}

@Suite struct ThumbnailTests {
    @Test func scalesToWidthHonouringEXIFOrientation() throws {
        // 800×600 pixels stored with orientation 6 (rotate 90°): displayed portrait 600×800.
        let jpeg = try #require(TestImages.jpeg(width: 800, height: 600, orientation: 6))
        let thumb = try #require(Thumbnails.jpeg(fromImageData: jpeg))
        let source = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect((425...428).contains(height))
    }

    @Test func storedThumbnailOpensWithThePassword() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let item = MediaItem(url: dir.file("IMG-x.enc"), captureDate: Date())
        try Thumbnails.store(Data([1, 2, 3]), for: item, secret: Secret("pw"))
        let sealed = try Data(contentsOf: item.thumbnailURL)
        #expect(Array(sealed[5..<9]) == Bytes.uint32BE(65_000))
        #expect(try ImageCrypto.open(sealed, secret: Secret("pw")) == Data([1, 2, 3]))
        // Existing thumbnails are kept unless asked to overwrite.
        try Thumbnails.store(Data([9]), for: item, secret: Secret("pw"))
        #expect(try ImageCrypto.open(Data(contentsOf: item.thumbnailURL), secret: Secret("pw")) == Data([1, 2, 3]))
    }
}

enum TestImages {
    static func jpeg(width: Int, height: Int, orientation: Int = 1) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
