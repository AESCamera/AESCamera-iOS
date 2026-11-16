import Foundation

/// What a duress password wipes when it is entered at unlock.
public enum WipeScope: UInt8, Sendable, CaseIterable {
    /// The vault that set the duress password up.
    case thisVault = 1
    /// Every vault except the duress vault itself.
    case allOthers = 2
}

/// The plaintext of a v2 verifier (FORMAT_SPEC.md, "Verifier plaintext"). Two roles can
/// share one vault: a duress vault is *armed* with what it wipes, and any vault can record
/// the duress vault it owns. Every payload encodes to exactly `size` bytes, so a duress
/// vault can't be told apart from any other vault without its password.
public struct VerifierPayload: Equatable, Sendable {
    public static let size = 128
    static let magic = Data("AESCameraVault:v2".utf8)

    private static let flagsOffset = 17
    private static let wipeScopeOffset = 18
    private static let duressScopeOffset = 19
    private static let wipeTargetOffset = 20
    private static let duressVaultOffset = 52
    private static let nameLength = 32
    private static let armedFlag: UInt8 = 0x01
    private static let hasDuressFlag: UInt8 = 0x02

    /// This is a duress vault: opening it at the unlock prompt wipes `wipeScope`.
    public var armed: Bool
    public var wipeScope: WipeScope?
    /// The vault folder wiped when armed with `.thisVault`.
    public var wipeTarget: String?
    /// The folder of the duress vault this vault owns, if it set one up.
    public var duressVault: String?
    /// What that duress vault wipes (shown in Settings).
    public var duressScope: WipeScope?

    public init(
        armed: Bool = false, wipeScope: WipeScope? = nil, wipeTarget: String? = nil,
        duressVault: String? = nil, duressScope: WipeScope? = nil
    ) {
        self.armed = armed
        self.wipeScope = wipeScope
        self.wipeTarget = wipeTarget
        self.duressVault = duressVault
        self.duressScope = duressScope
    }

    /// A plain vault: no duress role either way.
    public static let plain = VerifierPayload()

    public func encode() -> Data {
        var out = [UInt8](repeating: 0, count: Self.size)
        out.replaceSubrange(0..<Self.magic.count, with: Self.magic)
        var flags: UInt8 = 0
        if armed { flags |= Self.armedFlag }
        if duressVault != nil { flags |= Self.hasDuressFlag }
        out[Self.flagsOffset] = flags
        out[Self.wipeScopeOffset] = armed ? wipeScope?.rawValue ?? 0 : 0
        out[Self.duressScopeOffset] = duressVault != nil ? duressScope?.rawValue ?? 0 : 0
        if armed && wipeScope == .thisVault {
            Self.write(wipeTarget, into: &out, at: Self.wipeTargetOffset)
        }
        Self.write(duressVault, into: &out, at: Self.duressVaultOffset)
        return Data(out)
    }

    /// Parses a v2 plaintext; nil if it isn't one. Unknown flag bits are ignored, and an
    /// armed verifier with an unknown scope wipes nothing.
    public static func decode(_ plain: Data) -> VerifierPayload? {
        let bytes = [UInt8](plain)
        guard bytes.count == size, bytes.prefix(magic.count).elementsEqual(magic) else { return nil }
        let flags = bytes[flagsOffset]
        let hasDuress = flags & hasDuressFlag != 0
        let scope = flags & armedFlag != 0 ? WipeScope(rawValue: bytes[wipeScopeOffset]) : nil
        return VerifierPayload(
            armed: scope != nil,
            wipeScope: scope,
            wipeTarget: scope == .thisVault ? readName(bytes, at: wipeTargetOffset) : nil,
            duressVault: hasDuress ? readName(bytes, at: duressVaultOffset) : nil,
            duressScope: hasDuress ? WipeScope(rawValue: bytes[duressScopeOffset]) : nil
        )
    }

    /// 32 lowercase hex characters: the shape of every vault folder name.
    public static func isVaultName(_ name: String) -> Bool {
        name.utf8.count == nameLength && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func write(_ name: String?, into out: inout [UInt8], at offset: Int) {
        guard let name else { return }
        precondition(isVaultName(name), "Not a vault name")
        out.replaceSubrange(offset..<offset + nameLength, with: Array(name.utf8))
    }

    private static func readName(_ bytes: [UInt8], at offset: Int) -> String? {
        let name = String(decoding: bytes[offset..<offset + nameLength], as: UTF8.self)
        return isVaultName(name) ? name : nil
    }
}
