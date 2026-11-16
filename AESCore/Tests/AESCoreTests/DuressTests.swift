import CryptoKit
import Foundation
import Testing
@testable import AESCore

/// Fast verifier cost for tests.
private let fast = 1_000

private func sha256(_ data: Data) -> String { Bytes.hex(SHA256.hash(data: data)) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// A vault for `password` holding one media file and its thumbnail.
private func makeVault(_ password: String, in base: URL) throws -> URL {
    let vault = try VaultLocator.create(Secret(password), in: base, verifierIterations: fast)
    try Data.random(10_000).write(to: vault.appendingPathComponent("IMG-2026-01-01-00-00-00-000.enc"))
    let thumbs = vault.appendingPathComponent(".thumbs", isDirectory: true)
    try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
    try Data.random(500).write(to: thumbs.appendingPathComponent("IMG-2026-01-01-00-00-00-000.enc"))
    return vault
}

@Suite struct VerifierPayloadTests {
    /// FORMAT_SPEC.md test vectors, shared with Android's CrossPlatformVectorsTest.
    @Test func referenceVectors() {
        #expect(sha256(VerifierPayload.plain.encode()) ==
            "4983133b4bb84bc34d1f0dfefd9d0e80ed25cad2621d19f6fa28a24dd7de92c3")

        let both = VerifierPayload(
            armed: true, wipeScope: .thisVault, wipeTarget: "0123456789abcdef0123456789abcdef",
            duressVault: "fedcba9876543210fedcba9876543210", duressScope: .allOthers
        )
        let encoded = both.encode()
        #expect(encoded.prefix(20).hex == "41455343616d6572615661756c743a7632030102")
        #expect(sha256(encoded) == "4637c87d7025782535ea62f1f5cf37dc126cdbbd68b50daffcc417005abeb036")
        #expect(VerifierPayload.decode(encoded) == both)
    }

    @Test func everyPayloadHasTheSameSize() {
        let payloads = [
            VerifierPayload.plain,
            VerifierPayload(armed: true, wipeScope: .allOthers),
            VerifierPayload(duressVault: "fedcba9876543210fedcba9876543210", duressScope: .thisVault),
        ]
        for payload in payloads {
            #expect(payload.encode().count == VerifierPayload.size)
            #expect(VerifierPayload.decode(payload.encode()) == payload)
        }
    }

    @Test func unknownScopesAndBadNamesAreIgnored() {
        var bytes = [UInt8](VerifierPayload.plain.encode())
        bytes[17] = 0x01 | 0x02 | 0x80 // armed, has duress, unknown bit
        bytes[18] = 7 // unknown scope
        bytes[19] = 2
        bytes.replaceSubrange(52..<84, with: Array("NOT-A-VAULT-NAME-0123456789ABCDE".utf8))
        let payload = VerifierPayload.decode(Data(bytes))
        #expect(payload?.armed == false)
        #expect(payload?.wipeScope == nil)
        #expect(payload?.duressVault == nil)
        #expect(VerifierPayload.decode(Data("AESCameraVault:v1".utf8)) == nil)
    }
}

@Suite struct DuressTests {
    @Test func everyV2VerifierHasTheSameSize() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        let decoy = try VaultLocator.setDuress(
            owner: Secret("owner"), vault: owner, duress: Secret("duress"), scope: .thisVault,
            in: dir.url, verifierIterations: fast
        ).url
        let plain = try VaultLocator.create(Secret("plain"), in: dir.url, verifierIterations: fast)
        for vault in [owner, decoy, plain] {
            let size = try Data(contentsOf: vault.appendingPathComponent(".vault")).count
            #expect(size == 181)
        }
    }

    @Test func v1VerifierIsUpgradedToV2() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let secret = Secret("old")
        let vault = dir.file("0123456789abcdef0123456789abcdef")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try ImageCrypto.seal(VaultLocator.verifierMagicV1, secret: secret, iterations: fast)
            .write(to: vault.appendingPathComponent(".vault"))

        let match = try #require(try VaultLocator.match(secret, in: dir.url, verifierIterations: fast))
        #expect(match.payload == .plain)
        let rewritten = try ImageCrypto.open(Data(contentsOf: vault.appendingPathComponent(".vault")), secret: secret)
        #expect(VerifierPayload.decode(rewritten) == .plain)
    }

    @Test func setupRecordsTheDuressVaultInTheOwner() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        let decoy = try VaultLocator.setDuress(
            owner: Secret("owner"), vault: owner, duress: Secret("duress"), scope: .thisVault,
            in: dir.url, verifierIterations: fast
        )
        let ownerMatch = try #require(try VaultLocator.match(Secret("owner"), in: dir.url))
        #expect(ownerMatch.payload.duressVault == decoy.url.lastPathComponent)
        #expect(ownerMatch.payload.duressScope == .thisVault)
        #expect(!ownerMatch.payload.armed)
        #expect(decoy.payload.armed)
        #expect(decoy.payload.wipeTarget == owner.lastPathComponent)
    }

    @Test func refusesPasswordsThatAlreadyOpenAVault() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        _ = try makeVault("other", in: dir.url)
        for taken in ["owner", "other"] {
            #expect(throws: VaultLocator.DuressPasswordInUse.self) {
                try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret(taken),
                                           scope: .thisVault, in: dir.url, verifierIterations: fast)
            }
        }
    }

    @Test func thisVaultScopeWipesOnlyTheOwner() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        let other = try makeVault("other", in: dir.url)
        let decoy = try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("duress"),
                                               scope: .thisVault, in: dir.url, verifierIterations: fast).url

        let opened = try #require(try VaultLocator.unlock(Secret("duress"), in: dir.url))
        #expect(opened.url.lastPathComponent == decoy.lastPathComponent)
        #expect(!exists(owner))
        #expect(exists(other))
        #expect(try VaultLocator.find(Secret("owner"), in: dir.url) == nil)
        #expect(try VaultLocator.find(Secret("other"), in: dir.url) != nil)
    }

    @Test func allOthersScopeKeepsOnlyTheDecoy() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        let other = try makeVault("other", in: dir.url)
        let decoy = try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("duress"),
                                               scope: .allOthers, in: dir.url, verifierIterations: fast).url

        _ = try #require(try VaultLocator.unlock(Secret("duress"), in: dir.url))
        #expect(!exists(owner))
        #expect(!exists(other))
        #expect(exists(decoy))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == [decoy.lastPathComponent])

        // Stays armed: a vault created since is wiped by the next duress unlock.
        let later = try makeVault("later", in: dir.url)
        _ = try VaultLocator.unlock(Secret("duress"), in: dir.url)
        #expect(!exists(later))
    }

    @Test func lookupsNeverWipe() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("duress"),
                                   scope: .allOthers, in: dir.url, verifierIterations: fast)
        #expect(try VaultLocator.find(Secret("duress"), in: dir.url) != nil)
        #expect(try VaultLocator.match(Secret("duress"), in: dir.url) != nil)
        #expect(try VaultLocator.duressVault(owner: Secret("owner"), vault: owner, duress: Secret("duress"), in: dir.url) != nil)
        #expect(try VaultLocator.duressVault(owner: Secret("owner"), vault: owner, duress: Secret("wrong"), in: dir.url) == nil)
        #expect(exists(owner.appendingPathComponent(".vault")))
        #expect(try VaultLocator.find(Secret("owner"), in: dir.url) != nil)
    }

    @Test func anInterruptedWipeIsFinishedNextTime() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("duress"),
                                   scope: .thisVault, in: dir.url, verifierIterations: fast)
        // As if a wipe stopped right after shredding the verifier.
        VaultLocator.shred(owner.appendingPathComponent(".vault"))
        #expect(try VaultLocator.find(Secret("owner"), in: dir.url) == nil)
        #expect(exists(owner))

        _ = try VaultLocator.unlock(Secret("duress"), in: dir.url)
        #expect(!exists(owner))
    }

    @Test func changingWipesThePreviousDecoyAndRemovingWipesTheCurrentOne() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let owner = try makeVault("owner", in: dir.url)
        let first = try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("first"),
                                               scope: .thisVault, in: dir.url, verifierIterations: fast).url
        let second = try VaultLocator.setDuress(owner: Secret("owner"), vault: owner, duress: Secret("second"),
                                                scope: .allOthers, in: dir.url, verifierIterations: fast).url
        #expect(!exists(first))
        #expect(exists(second))
        #expect(try VaultLocator.match(Secret("owner"), in: dir.url)?.payload.duressScope == .allOthers)

        let payload = try VaultLocator.removeDuress(owner: Secret("owner"), vault: owner, in: dir.url, verifierIterations: fast)
        #expect(payload == .plain)
        #expect(!exists(second))
        #expect(try VaultLocator.match(Secret("owner"), in: dir.url)?.payload == .plain)
    }

    @Test func shreddingOverwritesTheHeaderBeforeDeleting() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let file = dir.file("IMG.enc")
        let original = Data.random(10_000)
        try original.write(to: file)
        // Keep a second link so the overwritten bytes can be read after the delete.
        let link = dir.file("link")
        try FileManager.default.linkItem(at: file, to: link)

        VaultLocator.shred(file)
        #expect(!exists(file))
        let after = try Data(contentsOf: link)
        #expect(after.count == original.count)
        #expect(after.prefix(4096) != original.prefix(4096))
        #expect(after.suffix(from: 4096) == original.suffix(from: 4096))
    }
}
