@preconcurrency import AVFoundation
import AESCore
import Observation
import UIKit

/// Camera screen state. Mirrors Android's `MainActivity` behaviour:
/// - camera permission is asked after unlock, the microphone on the first switch to video;
/// - a refused mic records silently; a refused camera shows an explanation;
/// - the session runs only while unlocked and on screen (no camera indicator while locked);
/// - normal mode disables the controls until the photo is saved; rapid capture keeps the
///   shutter live with at most 3 photos waiting to be saved.
@MainActor @Observable
final class CameraModel {
    enum Mode { case photo, video }
    enum Permission { case unknown, granted, denied }

    static let maxPendingSaves = 3

    private(set) var mode: Mode = .photo
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var flashOn = false
    private(set) var permission: Permission = .unknown
    private(set) var isRecording = false
    private(set) var isStartingOrStopping = false
    private(set) var recordingStarted: Date?
    private(set) var pendingSaves = 0
    private(set) var lastCapture: UIImage?
    /// Increments on every shutter, to flash the preview.
    private(set) var shutterCount = 0
    var message: String?

    let service = CaptureService()
    var isSimulated: Bool { service.isSimulated }

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private var lockHandler: UUID?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var previewObservation: NSKeyValueObservation?
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var micAsked = false
    @ObservationIgnored private var micGranted = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var zoomAtGestureStart: CGFloat = 1

    init() {}

    func attach(to session: AppSession) {
        guard self.session == nil else { return }
        self.session = session
        lockHandler = session.onLock { [weak self] in self?.handleLock() }
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micAsked = AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    // MARK: Lifecycle

    /// Starts the camera when unlocked and on screen.
    func activate() async {
        guard let session, session.isUnlocked, !active else { return }
        active = true
        if isSimulated {
            permission = .granted
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: permission = .granted
            case .notDetermined:
                permission = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
            default: permission = .denied
            }
        }
        guard permission == .granted, active else { return }
        do {
            try await service.start(position: position, mode: serviceMode, withAudio: micGranted)
            setUpRotation()
        } catch {
            message = error.localizedDescription
        }
        refreshLastCapture()
    }

    func deactivate() {
        active = false
        if isRecording { Task { await stopRecording() } }
        service.stop()
    }

    private func handleLock() {
        lastCapture = nil
        deactivate()
    }

    private var serviceMode: CaptureService.Mode { mode == .photo ? .photo : .video }

    // MARK: Rotation

    func previewLayerDidLoad(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        setUpRotation()
    }

    private func setUpRotation() {
        guard let device = service.device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// The angle that makes the capture upright (portrait UI, device held any way).
    private var captureAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? (isSimulated ? 0 : 90)
    }

    // MARK: Controls

    var controlsEnabled: Bool {
        !isStartingOrStopping && (session?.settings.rapidCapture == true || pendingSaves == 0)
    }

    var shutterEnabled: Bool {
        guard permission == .granted, !isStartingOrStopping else { return false }
        if mode == .video { return true }
        return session?.settings.rapidCapture == true ? pendingSaves < Self.maxPendingSaves : pendingSaves == 0
    }

    var hasFlash: Bool { isSimulated || service.hasFlash }

    func shutter() {
        switch mode {
        case .photo: takePhoto()
        case .video:
            Task { isRecording ? await stopRecording() : await startRecording() }
        }
    }

    func toggleMode() async {
        guard !isRecording, pendingSaves == 0 else { return }
        let next: Mode = mode == .photo ? .video : .photo
        if next == .video && !micAsked && !isSimulated {
            micAsked = true
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            if !micGranted { message = "No microphone access: videos record without sound." }
        }
        mode = next
        if flashOn { service.setTorch(false); flashOn = false }
        await service.setMode(serviceMode, withAudio: micGranted)
        session?.prewarmKeys()
    }

    func flip() async {
        guard !isRecording else { return }
        do {
            position = try await service.flip()
            if position == .front, flashOn { flashOn = false }
            setUpRotation()
        } catch {
            message = error.localizedDescription
        }
    }

    func toggleFlash() {
        flashOn.toggle()
        if mode == .video { service.setTorch(flashOn) }
    }

    func focus(atLayerPoint point: CGPoint) {
        guard let previewLayer else { return }
        service.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }

    func zoomGestureBegan() {
        zoomAtGestureStart = service.zoomFactor
    }

    func zoomGestureChanged(_ scale: CGFloat) {
        service.setZoom(zoomAtGestureStart * scale)
    }

    // MARK: Photos

    private func takePhoto() {
        guard shutterEnabled, let session else { return }
        pendingSaves += 1
        let flash = flashOn && position == .back
        let angle = captureAngle
        Task {
            defer {
                pendingSaves -= 1
                session.prewarmKeys()
            }
            do {
                let jpeg = try await service.capturePhoto(flash: flash, rotationAngle: angle)
                shutterCount += 1
                let vault = try await session.ensureVault()
                guard let secret = session.secret else { return }
                let salt = session.takePhotoSalt()
                let saved = try await MediaSaver.shared.savePhoto(jpeg, vault: vault, secret: secret, salt: salt)
                if session.settings.showLastCapture, session.isUnlocked {
                    lastCapture = saved.thumbnail.flatMap(UIImage.init(data:))
                }
                session.vaultDidChange()
            } catch CryptoError.locked {
                // Locked mid-save: nothing to report.
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Video

    private func startRecording() async {
        guard !isRecording, !isStartingOrStopping, let session else { return }
        isStartingOrStopping = true
        defer { isStartingOrStopping = false }
        do {
            let vault = try await session.ensureVault()
            guard let secret = session.secret else { return }
            let salt = session.takeVideoSalt()
            let angle = captureAngle
            let settings = await service.recordingSettings()
            let url = VaultFiles.uniqueURL(in: vault, for: MediaNames.newVideoName())
            let transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            let recorder = try await Task.detached {
                try VideoRecorder(
                    url: url, secret: secret, salt: salt,
                    videoSettings: settings.video, audioSettings: settings.audio, transform: transform
                )
            }.value
            let item = MediaItem(url: url, captureDate: Date())
            let wantsPreview = session.settings.showLastCapture
            recorder.onFirstFrame = { [weak self] pixelBuffer in
                let buffer = SendableBox(pixelBuffer)
                DispatchQueue.global(qos: .utility).async {
                    let jpeg = MediaSaver.storeVideoThumbnail(buffer.value, rotationAngle: angle, for: item, secret: secret)
                    guard wantsPreview, let jpeg else { return }
                    Task { @MainActor in
                        if self?.session?.isUnlocked == true { self?.lastCapture = UIImage(data: jpeg) }
                    }
                }
            }
            service.startRecording(recorder)
            if flashOn { service.setTorch(true) }
            isRecording = true
            recordingStarted = Date()
            UIApplication.shared.isIdleTimerDisabled = true
        } catch CryptoError.locked {
        } catch {
            message = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording, let session else { return }
        isRecording = false
        recordingStarted = nil
        isStartingOrStopping = true
        UIApplication.shared.isIdleTimerDisabled = false
        // Finishing may run while the app goes to the background (lock on background).
        let task = UIApplication.shared.beginBackgroundTask(withName: "Finish recording")
        defer {
            isStartingOrStopping = false
            UIApplication.shared.endBackgroundTask(task)
        }
        do {
            _ = try await service.stopRecording()
            session.vaultDidChange()
        } catch {
            message = error.localizedDescription
        }
        if mode == .video, flashOn { service.setTorch(false); flashOn = false }
        session.prewarmKeys()
    }

    // MARK: Last capture

    func refreshLastCapture() {
        guard let session, session.settings.showLastCapture, let secret = session.secret else {
            lastCapture = nil
            return
        }
        let vault = session.vaultURL
        Task {
            let image = await Task.detached(priority: .utility) { () -> Data? in
                guard let latest = VaultFiles.media(in: vault).first,
                      let sealed = try? Data(contentsOf: latest.thumbnailURL)
                else { return nil }
                return try? ImageCrypto.open(sealed, secret: secret)
            }.value
            if session.isUnlocked, session.secret === secret {
                lastCapture = image.flatMap(UIImage.init(data:))
            }
        }
    }
}
