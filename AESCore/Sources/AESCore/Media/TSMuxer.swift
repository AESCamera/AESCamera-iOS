import Foundation

/// Writes MPEG-2 TS shaped like Android MediaRecorder's output: PAT and PMT once at the
/// start, no PCR, one PES per video access unit, ADTS audio. The app never records TS;
/// this exists to build test fixtures for the TS playback path (tests and `aescore-tool`).
public struct TSMuxer {
    public static let videoPID = 0x100
    public static let audioPID = 0x101
    static let pmtPID = 0x1000

    private var continuity: [Int: UInt8] = [:]
    private var output = Data()

    public init(hasAudio: Bool) {
        writeSection(pid: 0, table: Self.pat())
        writeSection(pid: Self.pmtPID, table: Self.pmt(hasAudio: hasAudio))
    }

    /// Takes everything written so far.
    public mutating func take() -> Data {
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    /// One H.264 access unit in Annex B form (include SPS/PPS before IDR frames).
    public mutating func writeVideo(annexB: Data, pts: Int64) {
        writePES(pid: Self.videoPID, streamID: 0xE0, payload: annexB, pts: pts)
    }

    /// Raw AAC frames, each wrapped in an ADTS header, in one PES.
    public mutating func writeAudio(frames: [Data], config: TSDemuxer.AudioConfig, pts: Int64) {
        var payload = Data()
        for frame in frames {
            payload.append(Self.adtsHeader(length: frame.count, config: config))
            payload.append(frame)
        }
        writePES(pid: Self.audioPID, streamID: 0xC0, payload: payload, pts: pts)
    }

    static func adtsHeader(length: Int, config: TSDemuxer.AudioConfig) -> Data {
        let total = length + 7
        let rateIndex = UInt8(TSDemuxer.sampleRates.firstIndex(of: config.sampleRate) ?? 4)
        let profile = UInt8(config.objectType - 1)
        let channels = UInt8(config.channels)
        return Data([
            0xFF, 0xF1,
            (profile << 6) | (rateIndex << 2) | (channels >> 2),
            ((channels & 0x3) << 6) | UInt8((total >> 11) & 0x3),
            UInt8((total >> 3) & 0xFF),
            UInt8((total & 0x7) << 5) | 0x1F,
            0xFC,
        ])
    }

    private mutating func writePES(pid: Int, streamID: UInt8, payload: Data, pts: Int64) {
        var pes = Data([0, 0, 1, streamID])
        let length = payload.count + 8
        let lengthField = streamID == 0xE0 || length > 0xFFFF ? 0 : length // video: unbounded
        pes.append(contentsOf: [UInt8(lengthField >> 8), UInt8(lengthField & 0xFF), 0x80, 0x80, 5])
        pes.append(Self.timestampBytes(pts, marker: 0x21))
        pes.append(payload)
        writePackets(pid: pid, payload: pes, unitStart: true)
    }

    static func timestampBytes(_ value: Int64, marker: UInt8) -> Data {
        Data([
            marker | UInt8((value >> 29) & 0x0E),
            UInt8((value >> 22) & 0xFF),
            UInt8((value >> 14) & 0xFE) | 1,
            UInt8((value >> 7) & 0xFF),
            UInt8((value << 1) & 0xFE) | 1,
        ])
    }

    private mutating func writeSection(pid: Int, table: Data) {
        writePackets(pid: pid, payload: Data([0]) + table, unitStart: true) // pointer field 0
    }

    private mutating func writePackets(pid: Int, payload: Data, unitStart: Bool) {
        var offset = 0
        var first = unitStart
        while offset < payload.count {
            let counter = continuity[pid, default: 0]
            continuity[pid] = (counter + 1) & 0x0F
            let remaining = payload.count - offset
            var packet = Data([
                0x47,
                (first ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F),
                UInt8(pid & 0xFF),
            ])
            if remaining >= 184 {
                packet.append(0x10 | counter)
                packet.append(payload[offset..<(offset + 184)])
                offset += 184
            } else {
                // Pad with an adaptation field of stuffing bytes.
                let stuffing = 184 - remaining - 1
                packet.append(0x30 | counter)
                packet.append(UInt8(stuffing))
                if stuffing > 0 {
                    packet.append(0x00)
                    packet.append(Data(repeating: 0xFF, count: stuffing - 1))
                }
                packet.append(payload[offset...])
                offset = payload.count
            }
            output.append(packet)
            first = false
        }
    }

    private static func pat() -> Data {
        var table = Data([0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01])
        table.append(contentsOf: [0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)])
        return table + crc(table)
    }

    private static func pmt(hasAudio: Bool) -> Data {
        var streams = Data([0x1B, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        if hasAudio {
            streams.append(contentsOf: [0x0F, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        }
        let length = 9 + streams.count + 4
        var table = Data([0x02, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00])
        table.append(contentsOf: [0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00]) // PCR PID, no info
        table.append(streams)
        return table + crc(table)
    }

    /// MPEG-2 CRC-32.
    static func crc(_ data: Data) -> Data {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return Data([UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
    }
}
