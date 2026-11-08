@preconcurrency import AVFoundation
import SwiftUI

struct CameraScreen: View {
    @Binding var path: NavigationPath
    @Environment(AppSession.self) private var session
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var camera = CameraModel()
    @State private var onScreen = false
    @State private var flash = false
    @State private var focusPoint: CGPoint?
    @State private var zooming = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            if flash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
            controls
        }
        .toolbar(.hidden, for: .navigationBar)
        // Dark controls over the preview; RootView turns the status bar light here.
        .environment(\.colorScheme, .dark)
        .onAppear {
            camera.attach(to: session)
            onScreen = true
        }
        .onDisappear {
            onScreen = false
            camera.deactivate()
        }
        .task(id: cameraWanted) {
            if cameraWanted {
                await camera.activate()
            } else {
                camera.deactivate()
            }
        }
        .onChange(of: camera.shutterCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        .alert("AES Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.message ?? "")
        }
    }

    /// The camera runs only while unlocked and actually on screen.
    private var cameraWanted: Bool {
        onScreen && session.isUnlocked && importer.staged == nil
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        switch camera.permission {
        case .denied:
            permissionExplanation
        case .unknown:
            Color.black
        case .granted:
            GeometryReader { _ in
                ZStack {
                    if camera.isSimulated {
                        SimulatedPreview()
                    } else {
                        CameraPreview(session: camera.service.session) { camera.previewLayerDidLoad($0) }
                    }
                    if let focusPoint {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.yellow, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .position(focusPoint)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    camera.focus(atLayerPoint: location)
                    focusPoint = location
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        if focusPoint == location { focusPoint = nil }
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if !zooming {
                                zooming = true
                                camera.zoomGestureBegan()
                            }
                            camera.zoomGestureChanged(value.magnification)
                        }
                        .onEnded { _ in zooming = false }
                )
            }
            .ignoresSafeArea(edges: sizeClass == .regular ? .all : [])
        }
    }

    private var permissionExplanation: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 44))
            Text("Camera access is off")
                .font(.title3.bold())
            Text("AES Camera needs the camera to take photos and videos. Everything it captures is encrypted before it's saved.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack {
                if camera.hasFlash && camera.position == .back {
                    CameraButton(
                        systemImage: camera.flashOn ? "bolt.fill" : "bolt.slash.fill",
                        label: camera.flashOn ? "Flash on" : "Flash off",
                        filled: camera.flashOn
                    ) { camera.toggleFlash() }
                }
                Spacer()
                if camera.isRecording, let started = camera.recordingStarted {
                    RecordingBadge(started: started)
                }
                Spacer()
                CameraButton(systemImage: "lock.fill", label: "Lock") {
                    session.lock()
                }
                .disabled(camera.isStartingOrStopping)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            Group {
                if sizeClass == .regular {
                    // Tablets: controls clustered around the shutter, as on Android.
                HStack(spacing: 36) {
                    galleryButton
                    shutterButton
                    modeButton
                    flipButton
                }
            } else {
                HStack(alignment: .bottom) {
                    galleryButton
                    Spacer()
                    shutterButton
                    Spacer()
                    VStack(spacing: 18) {
                        modeButton
                        flipButton
                    }
                }
            }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var shutterButton: some View {
        ShutterButton(mode: camera.mode, recording: camera.isRecording) {
            camera.shutter()
        }
        .disabled(!camera.shutterEnabled)
    }

    private var modeButton: some View {
        CameraButton(
            systemImage: camera.mode == .photo ? "video.fill" : "camera.fill",
            label: camera.mode == .photo ? "Switch to video" : "Switch to photo"
        ) {
            Task { await camera.toggleMode() }
        }
        .disabled(camera.isRecording || camera.pendingSaves > 0 || camera.permission != .granted)
    }

    private var flipButton: some View {
        CameraButton(systemImage: "arrow.triangle.2.circlepath.camera.fill", label: "Switch camera") {
            Task { await camera.flip() }
        }
        .disabled(camera.isRecording || camera.permission != .granted || camera.isSimulated)
    }

    private var galleryButton: some View {
        Button {
            path.append(Route.gallery)
        } label: {
            if let image = camera.lastCapture {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            } else {
                CameraButtonLabel(systemImage: "photo.on.rectangle", filled: true)
            }
        }
        .accessibilityLabel("Open vault")
        .disabled(camera.isRecording || !camera.controlsEnabled)
        .opacity(camera.isRecording || !camera.controlsEnabled ? 0.5 : 1)
    }
}

// MARK: - Pieces

struct CameraButtonLabel: View {
    let systemImage: String
    var filled = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
    }
}

struct CameraButton: View {
    let systemImage: String
    let label: String
    var filled = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            CameraButtonLabel(systemImage: systemImage, filled: filled)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
    }
}

struct ShutterButton: View {
    let mode: CameraModel.Mode
    let recording: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(mode == .video ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
                    .frame(width: 84, height: 84)
                Image(systemName: recording ? "stop.fill" : (mode == .photo ? "camera.fill" : "record.circle"))
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 92, height: 92))
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(recording ? "Stop recording" : (mode == .photo ? "Take photo" : "Start recording"))
    }
}

struct RecordingBadge: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
        }
        .accessibilityLabel("Recording")
    }
}

/// `AVCaptureVideoPreviewLayer` in a view.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: @MainActor (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        onLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// What the Simulator shows instead of a camera: the same pattern the simulated feed
/// records, so photos and videos match what's on screen.
struct SimulatedPreview: View {
    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, size in
                graphics.withCGContext { cg in
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    SimulatedFeed.draw(in: cg, size: size, phase: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Text("Simulated camera")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 140)
        }
    }
}
