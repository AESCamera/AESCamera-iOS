import CryptoKit
import Foundation
@testable import AESCore

extension SymmetricKey {
    var hex: String { withUnsafeBytes { Bytes.hex($0) } }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { Bytes.hex(self) }

    static func random(_ count: Int) -> Data { Data(Bytes.random(count)) }
}

/// A fresh directory under the system temp dir, removed by `cleanup()`.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AESCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

let testPassword = "test-password"
