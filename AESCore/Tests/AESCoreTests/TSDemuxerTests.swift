import Foundation
import Testing
@testable import AESCore

@Suite struct TSDemuxerTests {
    static let sps = Data([0x67, 0x42, 0x00, 0x1F, 0xAA])
    static let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    static let config = TSDemuxer.AudioConfig(objectType: 2, sampleRate: 44_100, channels: 1)

    /// `count` access units at 30 fps, IDR every 30, plus audio, MediaRecorder-shaped.
    static func stream(frames count: Int, audio: Bool = true, frameSize: Int = 3_000) -> Data {
        var muxer = TSMuxer(hasAudio: audio)
        var out = muxer.take()
        for index in 0..<count {
            let pts = Int64(index) * 3_000
            var unit = Data()
            if index % 30 == 0 {
                unit += Data([0, 0, 0, 1]) + sps + Data([0, 0, 0, 1]) + pps + Data([0, 0, 0, 1, 0x65])
            } else {
                unit += Data([0, 0, 0, 1, 0x41])
            }
            unit += Data((0..<frameSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index) | 0x01 })
            muxer.writeVideo(annexB: unit, pts: pts)
            if audio, index % 2 == 0 {
                muxer.writeAudio(frames: [Data(repeating: UInt8(index & 0xFF), count: 200), Data(repeating: 1, count: 180)], config: config, pts: pts)
            }
            out += muxer.take()
        }
        return out
    }

    @Test func packetsAreAlignedAndMuxerCRCIsStandard() {
        let data = Self.stream(frames: 3)
        #expect(data.count % 188 == 0)
        #expect(stride(from: 0, to: data.count, by: 188).allSatisfy { data[$0] == 0x47 })
        // CRC-32/MPEG-2 check value for "123456789".
        #expect(TSMuxer.crc(Data("123456789".utf8)) == Data([0x03, 0x76, 0xE6, 0xE7]))
    }

    @Test func demuxesVideoAndAudioInOrder() {
        var demuxer = TSDemuxer()
        var frames = demuxer.push(Self.stream(frames: 60))
        frames += demuxer.finish()

        let video = frames.filter { $0.kind == .h264 }
        #expect(video.count == 60)
        #expect(video.map(\.pts) == (0..<60).map { Int64($0) * 3_000 })
        #expect(video.filter(\.isKeyframe).map(\.pts) == [0, 90_000])
        #expect(NALUnits.parameterSets(in: video[0].data)?.sps == Self.sps)

        let audio = frames.filter { $0.kind == .aacADTS }
        #expect(audio.count == 60) // 30 PES × 2 ADTS frames
        #expect(audio[0].audioConfig == Self.config)
        #expect(audio[0].data.count == 200 && audio[1].data.count == 180)
        // The second frame of a PES is 1024 samples later.
        #expect(audio[1].pts == 1024 * 90_000 / 44_100)
    }

    @Test func survivesArbitraryChunking() {
        let data = Self.stream(frames: 40)
        var demuxer = TSDemuxer()
        var frames: [TSDemuxer.Frame] = []
        var offset = 0
        var size = 1
        while offset < data.count {
            let end = min(data.count, offset + size)
            frames += demuxer.push(data[offset..<end])
            offset = end
            size = size * 3 % 977 + 1
        }
        frames += demuxer.finish()
        #expect(frames.filter { $0.kind == .h264 }.count == 40)
    }

    @Test func resyncsFromTheMiddleAfterASeek() {
        let data = Self.stream(frames: 90)
        var demuxer = TSDemuxer()
        _ = demuxer.push(data.prefix(188 * 2)) // PAT + PMT
        demuxer.resync()
        // Jump into the middle at an unaligned offset.
        let frames = demuxer.push(data[(data.count / 2 + 61)...]) + demuxer.finish()
        let video = frames.filter { $0.kind == .h264 }
        #expect(!video.isEmpty)
        let lastPTS: Int64? = video.last?.pts
        #expect(lastPTS == Int64(89 * 3_000))
        #expect(video.allSatisfy { $0.pts > 30 * 3_000 })
    }

    @Test func annexBToAVCC() {
        let annexB = Data([0, 0, 0, 1]) + Self.sps + Data([0, 0, 1]) + Self.pps + Data([0, 0, 0, 1, 0x65, 1, 2, 3])
        let avcc = NALUnits.avcc(fromAnnexB: annexB)
        #expect(avcc == Data([0, 0, 0, 4, 0x65, 1, 2, 3]))
    }

    @Test func audioSpecificConfig() {
        // AAC LC, 44.1 kHz, mono → 0x12 0x08.
        #expect(Self.config.audioSpecificConfig == Data([0x12, 0x08]))
    }

    @Test func timelineFromHeadAndTail() throws {
        let data = Self.stream(frames: 300, frameSize: 2_000) // 10 s, larger than one window
        #expect(data.count > 512 * 1024)
        let range = try #require(try TSTimeline.range(length: UInt64(data.count)) { offset, count in
            let start = Int(offset)
            return data[start..<min(data.count, start + count)]
        })
        #expect(range.first == 0)
        #expect(range.last == 299 * 3_000)
    }
}
