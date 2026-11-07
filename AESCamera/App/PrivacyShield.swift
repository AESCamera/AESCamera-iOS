import SwiftUI
import UIKit

/// iOS can't block screenshots (no FLAG_SECURE). What it can do:
/// - cover the app before the app-switcher snapshot is taken (scene inactive), and
/// - hide content while the screen is recorded, mirrored or AirPlayed.
@MainActor @Observable
final class PrivacyMonitor {
    /// The screen is being recorded or mirrored.
    private(set) var isCaptured = false
    /// The user chose to show content anyway (capture detection has false positives).
    var revealDespiteCapture = false
    /// Set briefly after a screenshot so the UI can say it couldn't be blocked.
    private(set) var screenshotTaken = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteScreenshot() }
        })
    }

    func update(captured: Bool) {
        guard captured != isCaptured else { return }
        isCaptured = captured
        revealDespiteCapture = false
    }

    var hidesContent: Bool { isCaptured && !revealDespiteCapture }

    private func noteScreenshot() {
        screenshotTaken = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            screenshotTaken = false
        }
    }
}

/// Reports the window scene's `sceneCaptureState` (iOS 17) as it changes.
struct CaptureStateReader: UIViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: (@MainActor (Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: ReaderView, _) in
                view.report()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            onChange?(traitCollection.sceneCaptureState == .active)
        }
    }
}

/// Covers the app in the app switcher.
struct SnapshotShield: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
        }
        .accessibilityHidden(true)
    }
}

/// Shown instead of vault content while the screen is being captured.
struct CaptureShield: View {
    @Environment(PrivacyMonitor.self) private var privacy

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 44))
                Text("Hidden while the screen is being recorded or mirrored")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Show Anyway") {
                    privacy.revealDespiteCapture = true
                }
                .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
    }
}
