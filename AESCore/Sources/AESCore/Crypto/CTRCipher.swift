import CommonCrypto
import CryptoKit
import Foundation

/// AES-256-CTR positioned at any plaintext offset in O(1).
///
/// Keystream block n = AES(key, iv + n), with the 16-byte counter treated as a big-endian
/// 128-bit integer (Java's `AES/CTR/NoPadding`). Seeking adds `offset / 16` to the counter
/// and discards `offset % 16` keystream bytes. Encryption and decryption are the same
/// operation. Not thread-safe: use one instance per queue.
public final class CTRCipher {
    private var cryptor: CCCryptorRef?

    public init(key: SymmetricKey, iv: [UInt8], offset: UInt64 = 0) throws {
        precondition(iv.count == 16, "IV must be 16 bytes")
        let counter = Self.addToCounter(iv, blocks: offset / 16)
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding), counter, keyBytes.baseAddress, keyBytes.count,
                nil, 0, 0, CCModeOptions(0x0002 /* kCCModeOptionCTR_BE */), &ref
            )
        }
        guard status == kCCSuccess, let ref else { throw CryptoError.commonCrypto(status) }
        cryptor = ref

        let skip = Int(offset % 16)
        if skip > 0 {
            _ = process(Data(count: skip))
        }
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// Encrypts or decrypts `input`, continuing the keystream.
    public func process(_ input: Data) -> Data {
        var output = Data(count: input.count)
        input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                process(inBytes, into: outBytes)
            }
        }
        return output
    }

    /// In-place-capable variant; `output` must be at least as large as `input`.
    public func process(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) {
        guard input.count > 0 else { return }
        precondition(output.count >= input.count)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
        precondition(status == kCCSuccess && moved == input.count, "CTR update failed: \(status)")
    }

    /// `counter + blocks` as a big-endian 128-bit integer (wraps at 2^128).
    public static func addToCounter(_ counter: [UInt8], blocks: UInt64) -> [UInt8] {
        precondition(counter.count == 16, "Counter must be 16 bytes")
        var result = counter
        var carry = blocks
        var index = 15
        while carry != 0 && index >= 0 {
            let sum = UInt64(result[index]) + (carry & 0xFF)
            result[index] = UInt8(truncatingIfNeeded: sum)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }
        return result
    }
}
