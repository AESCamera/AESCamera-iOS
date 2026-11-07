import Foundation

/// A minimal MPEG-2 TS demuxer for the streams Android's MediaRecorder writes into `.encv`
/// (container 1): H.264 video + AAC (ADTS) audio, PAT/PMT only once at the start, no PCR,
/// no H.264 access-unit delimiters. One PES packet carries one video access unit; an
/// audio PES carries one or more ADTS frames.
///
/// Feed it bytes in order with `push(_:)`; it returns the complete frames found so far.
/// After a seek, call `resync()` and push bytes from any offset: it realigns on the next
/// sync byte and skips partial PES packets.
public struct TSDemuxer {
    public static let packetSize = 188
    static let syncByte: UInt8 = 0x47

    public enum StreamKind: Sendable {
        case h264
        case aacADTS
    }

    /// One video access unit (Annex B) or one AAC frame (ADTS header stripped).
    public struct Frame: Sendable {
        public let kind: StreamKind
        /// 90 kHz presentation timestamp.
        public let pts: Int64
        /// 90 kHz decode timestamp (equals `pts` when the PES carries no DTS).
        public let dts: Int64
        public let data: Data
        /// Video: contains an IDR slice. Audio: always true.
        public let isKeyframe: Bool
        /// Audio only: the stream format from the ADTS header.
        public let audioConfig: AudioConfig?
    }

    public struct AudioConfig: Equatable, Sendable {
        /// MPEG-4 audio object type (2 = AAC LC).
        public let objectType: Int
        public let sampleRate: Int
        public let channels: Int

        /// The 2-byte AudioSpecificConfig (the decoder's "magic cookie").
        public var audioSpecificConfig: Data {
            let index = UInt8(TSDemuxer.sampleRates.firstIndex(of: sampleRate) ?? 4)
            return Data([
                UInt8(objectType << 3) | (index >> 1),
                ((index & 1) << 7) | UInt8(channels << 3),
            ])
        }
    }

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private var buffer = Data()
    private var pmtPID: Int?
    /// Stream PIDs from the PMT. Remembered across `resync()`: the PMT appears only once.
    public private(set) var streams: [Int: StreamKind] = [:]
    private var pes: [Int: Data] = [:]

    public init() {}

    /// True once the PMT has been read, so frames can be classified.
    public var hasStreams: Bool { !streams.isEmpty }

    /// Forget partial data (after a seek). Stream assignments are kept.
    public mutating func resync() {
        buffer.removeAll(keepingCapacity: true)
        pes.removeAll()
    }

    /// Appends `bytes` and returns the frames completed by them.
    public mutating func push(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= Self.packetSize {
            guard buffer[offset] == Self.syncByte else {
                offset += 1
                continue
            }
            let packet = buffer[offset..<(offset + Self.packetSize)]
            offset += Self.packetSize
            frames.append(contentsOf: handle(packet: packet))
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
        return frames
    }

    /// Flushes PES packets still being collected (end of stream).
    public mutating func finish() -> [Frame] {
        var frames: [Frame] = []
        for pid in pes.keys.sorted() {
            if let data = pes.removeValue(forKey: pid), let kind = streams[pid] {
                frames.append(contentsOf: Self.frames(fromPES: data, kind: kind))
            }
        }
        return frames
    }

    private mutating func handle(packet: Data.SubSequence) -> [Frame] {
        let base = packet.startIndex
        let unitStart = packet[base + 1] & 0x40 != 0
        let pid = (Int(packet[base + 1] & 0x1F) << 8) | Int(packet[base + 2])
        let adaptation = (packet[base + 3] >> 4) & 0x3
        var payloadStart = base + 4
        if adaptation & 0x2 != 0 {
            payloadStart += 1 + Int(packet[base + 4])
        }
        guard adaptation & 0x1 != 0, payloadStart < packet.endIndex else { return [] }
        let payload = packet[payloadStart..<packet.endIndex]

        if pid == 0 {
            if unitStart { parsePAT(payload) }
            return []
        }
        if pid == pmtPID {
            if unitStart { parsePMT(payload) }
            return []
        }
        guard let kind = streams[pid] else { return [] }

        var frames: [Frame] = []
        if unitStart {
            if let previous = pes.removeValue(forKey: pid) {
                frames = Self.frames(fromPES: previous, kind: kind)
            }
            pes[pid] = Data(payload)
        } else if pes[pid] != nil {
            pes[pid]!.append(contentsOf: payload)
        }
        // else: continuation of a PES that started before a seek point; skip it.
        return frames
    }

    /// The section after the pointer field, or nil.
    private func section(_ payload: Data.SubSequence) -> Data? {
        guard let pointer = payload.first else { return nil }
        let start = payload.startIndex + 1 + Int(pointer)
        guard start + 3 <= payload.endIndex else { return nil }
        let length = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let end = min(payload.endIndex, start + 3 + length)
        return Data(payload[start..<end])
    }

    private mutating func parsePAT(_ payload: Data.SubSequence) {
        guard let table = section(payload), table.count >= 12, table[0] == 0x00 else { return }
        // Programs from byte 8 to the CRC (4 bytes), 4 bytes each.
        var index = 8
        while index + 4 <= table.count - 4 {
            let program = (Int(table[index]) << 8) | Int(table[index + 1])
            let pid = (Int(table[index + 2] & 0x1F) << 8) | Int(table[index + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            index += 4
        }
    }

    private mutating func parsePMT(_ payload: Data.SubSequence) {
        guard let table = section(payload), table.count >= 16, table[0] == 0x02 else { return }
        let programInfoLength = (Int(table[10] & 0x0F) << 8) | Int(table[11])
        var index = 12 + programInfoLength
        var found: [Int: StreamKind] = [:]
        while index + 5 <= table.count - 4 {
            let streamType = table[index]
            let pid = (Int(table[index + 1] & 0x1F) << 8) | Int(table[index + 2])
            let infoLength = (Int(table[index + 3] & 0x0F) << 8) | Int(table[index + 4])
            switch streamType {
            case 0x1B: found[pid] = .h264
            case 0x0F: found[pid] = .aacADTS
            default: break
            }
            index += 5 + infoLength
        }
        if !found.isEmpty { streams = found }
    }

    static func frames(fromPES pes: Data, kind: StreamKind) -> [Frame] {
        let pes = Data(pes)
        guard pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return [] }
        let flags = pes[7]
        let headerLength = Int(pes[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= pes.count else { return [] }
        let hasPTS = flags & 0x80 != 0
        let hasDTS = flags & 0x40 != 0
        guard hasPTS, pes.count >= 14 else { return [] }
        let pts = timestamp(pes, at: 9)
        let dts = hasDTS && pes.count >= 19 ? timestamp(pes, at: 14) : pts
        let payload = pes[payloadStart...]

        switch kind {
        case .h264:
            let isKeyframe = NALUnits.split(annexB: payload).contains { ($0.first ?? 0) & 0x1F == 5 }
            return [Frame(kind: .h264, pts: pts, dts: dts, data: Data(payload), isKeyframe: isKeyframe, audioConfig: nil)]
        case .aacADTS:
            return adtsFrames(payload, pts: pts)
        }
    }

    static func timestamp(_ data: Data, at index: Int) -> Int64 {
        let b0 = Int64(data[index]), b1 = Int64(data[index + 1]), b2 = Int64(data[index + 2])
        let b3 = Int64(data[index + 3]), b4 = Int64(data[index + 4])
        return ((b0 >> 1) & 0x07) << 30 | b1 << 22 | ((b2 >> 1) & 0x7F) << 15 | b3 << 7 | ((b4 >> 1) & 0x7F)
    }

    static func adtsFrames(_ payload: Data.SubSequence, pts: Int64) -> [Frame] {
        var frames: [Frame] = []
        var index = payload.startIndex
        var frameNumber: Int64 = 0
        while index + 7 <= payload.endIndex {
            guard payload[index] == 0xFF, payload[index + 1] & 0xF0 == 0xF0 else {
                index += 1
                continue
            }
            let protectionAbsent = payload[index + 1] & 0x01 == 1
            let objectType = Int((payload[index + 2] >> 6) & 0x3) + 1
            let rateIndex = Int((payload[index + 2] >> 2) & 0xF)
            let channels = Int(payload[index + 2] & 0x1) << 2 | Int((payload[index + 3] >> 6) & 0x3)
            let length = Int(payload[index + 3] & 0x3) << 11 | Int(payload[index + 4]) << 3 | Int((payload[index + 5] >> 5) & 0x7)
            let headerSize = protectionAbsent ? 7 : 9
            guard rateIndex < sampleRates.count, length > headerSize, index + length <= payload.endIndex else { break }
            let config = AudioConfig(objectType: objectType, sampleRate: sampleRates[rateIndex], channels: channels)
            let framePTS = pts + frameNumber * 1024 * 90_000 / Int64(config.sampleRate)
            frames.append(Frame(
                kind: .aacADTS, pts: framePTS, dts: framePTS,
                data: Data(payload[(index + headerSize)..<(index + length)]),
                isKeyframe: true, audioConfig: config
            ))
            frameNumber += 1
            index += length
        }
        return frames
    }
}

public enum NALUnits {
    /// Splits an Annex B byte stream on 3- or 4-byte start codes (start codes removed).
    public static func split<D: DataProtocol>(annexB: D) -> [Data] where D.Index == Int {
        var units: [Data] = []
        var start: Int?
        var index = annexB.startIndex
        let end = annexB.endIndex
        while index + 2 < end {
            if annexB[index] == 0, annexB[index + 1] == 0, annexB[index + 2] == 1 {
                if let start {
                    var unitEnd = index
                    if unitEnd > start, annexB[unitEnd - 1] == 0 { unitEnd -= 1 } // 4-byte start code
                    if unitEnd > start { units.append(Data(annexB[start..<unitEnd])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < end {
            units.append(Data(annexB[start..<end]))
        }
        return units
    }

    /// Converts Annex B to AVCC (4-byte big-endian lengths), dropping parameter sets and
    /// delimiters, which live in the format description instead.
    public static func avcc(fromAnnexB annexB: Data) -> Data {
        var out = Data()
        for unit in split(annexB: annexB) {
            let type = (unit.first ?? 0) & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    /// The first SPS and PPS in an Annex B access unit.
    public static func parameterSets(in annexB: Data) -> (sps: Data, pps: Data)? {
        let units = split(annexB: annexB)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = units.first(where: { ($0.first ?? 0) & 0x1F == 8 })
        else { return nil }
        return (sps, pps)
    }
}

/// Time range of a TS stream from its first and last PES timestamps, like Android's
/// `EncvDurationReader` (MediaRecorder's TS has no PCR to derive it from).
public enum TSTimeline {
    /// Reads the head and tail (256 KiB each) of the stream through `read`.
    public static func range(length: UInt64, read: (UInt64, Int) throws -> Data) throws -> (first: Int64, last: Int64)? {
        let window = 256 * 1024
        var head = TSDemuxer()
        let headFrames = head.push(try read(0, window))
        guard let first = headFrames.first(where: { $0.kind == .h264 })?.pts ?? headFrames.first?.pts else { return nil }

        let tailStart = length > UInt64(window) ? length - UInt64(window) : 0
        var tail = TSDemuxer()
        _ = tail.push(try read(0, window)) // learn the stream PIDs from the PAT/PMT
        tail.resync()
        var tailFrames = tail.push(try read(tailStart, Int(length - tailStart)))
        tailFrames += tail.finish()
        let last = tailFrames.filter { $0.kind == .h264 }.map(\.pts).max() ?? tailFrames.map(\.pts).max() ?? first
        return (first, max(first, last))
    }
}
