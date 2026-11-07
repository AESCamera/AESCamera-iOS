import SwiftUI

@main
struct AESCameraApp: App {
    @State private var session = AppSession()
    @State private var privacy = PrivacyMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(privacy)
        }
        .onChange(of: scenePhase) { _, phase in
            session.scenePhaseChanged(to: phase)
        }
    }
}

enum Route: Hashable {
    case gallery
    case settings
}

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrivacyMonitor.self) private var privacy
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CameraScreen(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .gallery: GalleryScreen(path: $path)
                    case .settings: SettingsScreen()
                    }
                }
                .navigationDestination(for: ViewerRoute.self) { route in
                    ViewerScreen(source: .vault(startID: route.startID))
                }
        }
        .overlay {
            if session.isUnlocked && privacy.hidesContent {
                CaptureShield()
            }
        }
        .overlay {
            if !session.isUnlocked {
                UnlockView()
            }
        }
        .overlay {
            if scenePhase != .active {
                SnapshotShield()
            }
        }
        .overlay(alignment: .top) {
            if privacy.screenshotTaken && session.isUnlocked {
                Text("Screenshots can't be blocked on iOS")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: privacy.screenshotTaken)
        .background(CaptureStateReader { privacy.update(captured: $0) })
        .onChange(of: session.isUnlocked) { _, unlocked in
            // Every screen above the camera shows vault content: drop back on lock.
            if !unlocked { path = NavigationPath() }
        }
    }
}
