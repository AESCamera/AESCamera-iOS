import SwiftUI

@main
struct AESCameraApp: App {
    @State private var session = AppSession()
    @State private var privacy = PrivacyMonitor()
    @State private var importer = ImportCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Staged imports are ciphertext, but there's no reason to keep them across launches.
        ImportStaging.wipe()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(privacy)
                .environment(importer)
                .onOpenURL { importer.receive($0) }
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
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()

    var body: some View {
        ZStack {
            mainStack
            // The imported viewer sits inside the same view tree, so the unlock and
            // privacy overlays below cover it too.
            if let staged = importer.staged {
                NavigationStack {
                    ViewerScreen(source: .imported(staged)) { importer.close() }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.default, value: importer.staged)
        .confirmationDialog(importTitle, isPresented: Binding(get: { importer.isAsking }, set: { if !$0 { importer.cancel() } }), titleVisibility: .visible) {
            Button("Open") { importer.confirm() }
            Button("Cancel", role: .cancel) { importer.cancel() }
        } message: {
            Text(importer.pending.map(\.name).joined(separator: "\n"))
        }
        .alert("AES Camera", isPresented: Binding(get: { importer.message != nil }, set: { if !$0 { importer.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.message ?? "")
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

    private var importTitle: String {
        importer.pending.count == 1 ? "Open 1 encrypted file?" : "Open \(importer.pending.count) encrypted files?"
    }

    private var mainStack: some View {
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
        // The camera is always dark; set here, not on CameraScreen, because a preferred
        // scheme there would apply to the whole window and every screen pushed over it.
        .preferredColorScheme(path.isEmpty && session.isUnlocked ? .dark : nil)
    }
}
