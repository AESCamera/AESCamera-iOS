@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Owns the `AVCaptureSession`. All session work happens on `sessionQueue`; sample buffers
/// arrive on `dataQueue`, which also drives the active `VideoRecorder`.
///
/// ```
/// AVCaptureSession
///  ├─ video device input (back/front wide camera)
///  ├─ mic input                 ← video mode, only after mic permission
///  ├─ AVCapturePhotoOutput      ← always
///  ├─ AVCaptureVideoDataOutput  ┐ video mode
///  └─ AVCaptureAudioDataOutput  ┘
/// ```
///
/// Without a camera (the Simulator) it runs a `SimulatedFeed` instead, so recording,
/// encryption and playback can still be exercised end to end.
final class CaptureService: NSObject, @unchecked Sendable {
    enum Mode: Sendable { case photo, video }

    let session = AVCaptureSession()
    let isSimulated: Bool

    private let sessionQueue = DispatchQueue(label: "dev.dineshkumar.aescamera.session")
    private let dataQueue = DispatchQueue(label: "dev.dineshkumar.aescamera.capture-data")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private let lock = NSLock()
    private var _device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var mode: Mode = .photo
    private var photoContinuations: [Int64: CheckedContinuation<Data, Error>] = [:]

    // dataQueue only
    private var recorder: VideoRecorder?
    private lazy var simulatedFeed = SimulatedFeed(queue: dataQueue) { [weak self] buffer in
        self?.recorder?.appendVideo(buffer)
    }

    override init() {
        isSimulated = AVCaptureDevice.default(for: .video) == nil
        super.init()
    }

    /// The active camera, for the rotation coordinator and preview.
    var device: AVCaptureDevice? {
        lock.withLock { _device }
    }

    var hasFlash: Bool {
        device?.hasFlash ?? false
    }

    // MARK: Session lifecycle

    /// Configures the session on first use (back camera, photo mode) and starts it.
    func start(position: AVCaptureDevice.Position, mode: Mode, withAudio: Bool) async throws {
        guard !isSimulated else { return }
        try await onSessionQueue {
            if !self.configured {
                try self.configure(position: position)
                self.configured = true
            }
            self.applyMode(mode, withAudio: withAudio)
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        guard !isSimulated else { return }
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setMode(_ mode: Mode, withAudio: Bool) async {
        guard !isSimulated else { return }
        try? await onSessionQueue { self.applyMode(mode, withAudio: withAudio) }
    }

    /// Switches cameras; returns the new position.
    func flip() async throws -> AVCaptureDevice.Position {
        guard !isSimulated else { return .back }
        return try await onSessionQueue {
            let current = self.videoInput?.device.position ?? .back
            let next: AVCaptureDevice.Position = current == .back ? .front : .back
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            try self.setVideoDevice(position: next)
            return next
        }
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        try setVideoDevice(position: position)

        guard session.canAddOutput(photoOutput) else { throw CameraError.unavailable }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = true
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
    }

    private func setVideoDevice(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        if let videoInput { session.removeInput(videoInput) }
        guard session.canAddInput(input) else {
            if let videoInput { session.addInput(videoInput) }
            throw CameraError.unavailable
        }
        session.addInput(input)
        videoInput = input
        lock.withLock { _device = device }
    }

    private func applyMode(_ mode: Mode, withAudio: Bool) {
        self.mode = mode
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        switch mode {
        case .photo:
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        case .video:
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            if withAudio, audioInput == nil,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if audioInput != nil, !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }
    }

    // MARK: Controls

    /// Focus and expose at a point in device coordinates (0…1, sensor orientation).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    var zoomFactor: CGFloat {
        device?.videoZoomFactor ?? 1
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let maximum = min(device.maxAvailableVideoZoomFactor, 10)
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(factor, maximum))
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
        }
    }

    // MARK: Photos

    /// Captures a JPEG in memory (never a file). `rotationAngle` comes from the rotation
    /// coordinator; the orientation ends up in EXIF.
    func capturePhoto(flash: Bool, rotationAngle: CGFloat) async throws -> Data {
        if isSimulated {
            return try await MainActor.run { try SimulatedFeed.photoJPEG() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                // JPEG, not HEIC: Android (minSdk 26) can't decode HEIF.
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                if self.photoOutput.supportedFlashModes.contains(.on) {
                    settings.flashMode = flash ? .on : .off
                }
                if #available(iOS 18.0, *), self.photoOutput.isShutterSoundSuppressionSupported {
                    settings.isShutterSoundSuppressionEnabled = true
                }
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                self.lock.withLock { self.photoContinuations[settings.uniqueID] = continuation }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Recording

    /// Settings for the writer, from what this device recommends for MP4 (H.264).
    func recordingSettings() async -> (video: [String: Any], audio: [String: Any]?) {
        if isSimulated {
            return (SimulatedFeed.videoSettings, nil)
        }
        let settings = await withCheckedContinuation { (continuation: CheckedContinuation<SendableBox<([String: Any], [String: Any]?)>, Never>) in
            sessionQueue.async {
                let video = self.videoOutput.recommendedVideoSettings(forVideoCodecType: .h264, assetWriterOutputFileType: .mp4)
                    ?? [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080]
                let audio = self.audioInput == nil ? nil : self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
                continuation.resume(returning: SendableBox((video, audio)))
            }
        }
        return settings.value
    }

    func startRecording(_ recorder: VideoRecorder) {
        dataQueue.async {
            self.recorder = recorder
            if self.isSimulated { self.simulatedFeed.start() }
        }
    }

    /// Stops feeding the recorder and finishes the file.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            dataQueue.async {
                guard let recorder = self.recorder else {
                    continuation.resume(throwing: CameraError.nothingRecorded)
                    return
                }
                self.recorder = nil
                if self.isSimulated { self.simulatedFeed.stop() }
                recorder.finish { continuation.resume(with: $0) }
            }
        }
    }

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension CaptureService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let continuation = lock.withLock { photoContinuations.removeValue(forKey: photo.resolvedSettings.uniqueID) }
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraError.photoFailed)
        }
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let recorder else { return }
        if output === videoOutput {
            recorder.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            recorder.appendAudio(sampleBuffer)
        }
    }
}
