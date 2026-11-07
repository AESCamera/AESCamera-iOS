@preconcurrency import AVFoundation
import CoreVideo
import UIKit

/// A stand-in camera for the Simulator (which has none): synthetic 720×1280 frames at
/// 30 fps for recordings and a rendered JPEG for photos. Only used when no capture
/// device exists.
final class SimulatedFeed: @unchecked Sendable {
    static let size = CGSize(width: 720, height: 1280)
    static var videoSettings: [String: Any] { [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
    ] }

    private let queue: DispatchQueue
    private let output: (CMSampleBuffer) -> Void
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?

    init(queue: DispatchQueue, output: @escaping (CMSampleBuffer) -> Void) {
        self.queue = queue
        self.output = output
    }

    /// Call on `queue`.
    func start() {
        frame = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        timer.resume()
        self.timer = timer
    }

    /// Call on `queue`.
    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emitFrame() {
        guard let buffer = makePixelBuffer() else { return }
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        if let sample { output(sample) }
        frame += 1
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(Self.size.width),
                kCVPixelBufferHeightKey as String: Int(Self.size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }
        Self.draw(in: context, size: Self.size, phase: Double(frame) / 30)
        return buffer
    }

    /// A slowly shifting gradient with a sweeping bar and a ticking dot: enough motion to
    /// see that playback and seeking work.
    static func draw(in context: CGContext, size: CGSize, phase: Double) {
        let hue = CGFloat((phase / 10).truncatingRemainder(dividingBy: 1))
        let top = UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor
        let bottom = UIColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.4, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        let barY = size.height * CGFloat((phase / 4).truncatingRemainder(dividingBy: 1))
        context.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        context.fill(CGRect(x: 0, y: barY, width: size.width, height: 24))
        let second = Int(phase) % 10
        context.setFillColor(UIColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(x: 40 + CGFloat(second) * 60, y: 80, width: 40, height: 40))
    }

    @MainActor
    static func photoJPEG() throws -> Data {
        let size = CGSize(width: 1080, height: 1440)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(in: context, size: size, phase: Date().timeIntervalSinceReferenceDate)
            context.restoreGState()
            let stamp = Date().formatted(date: .abbreviated, time: .standard)
            (stamp as NSString).draw(
                at: CGPoint(x: 48, y: size.height - 120),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white]
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CameraError.photoFailed }
        return data
    }
}
