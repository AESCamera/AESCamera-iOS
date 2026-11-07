import AESCore
import Foundation
import Observation

/// The few user settings, in `UserDefaults` (nothing sensitive).
@MainActor @Observable
final class AppSettings {
    private enum Key {
        static let vaultLocation = "vault_location"
        static let rapidCapture = "rapid_capture"
        static let showLastCapture = "show_last_capture"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where the vault tree lives. Only `AppSession.moveVault` should change it.
    var vaultLocation: VaultLocation {
        didSet { defaults.set(vaultLocation.rawValue, forKey: Key.vaultLocation) }
    }

    /// Keep the shutter live while earlier photos are still being encrypted and saved.
    var rapidCapture: Bool {
        didSet { defaults.set(rapidCapture, forKey: Key.rapidCapture) }
    }

    /// Show the latest capture on the camera screen's gallery button. Off by default, so
    /// nothing from the vault shows on the camera screen unless asked for.
    var showLastCapture: Bool {
        didSet { defaults.set(showLastCapture, forKey: Key.showLastCapture) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rapidCapture = defaults.bool(forKey: Key.rapidCapture)
        showLastCapture = defaults.bool(forKey: Key.showLastCapture)
        if let stored = defaults.string(forKey: Key.vaultLocation).flatMap(VaultLocation.init(rawValue:)) {
            vaultLocation = stored
        } else {
            // Decided once: an install that already has a shared vault (e.g. copied in
            // through the Files app) stays shared, otherwise private.
            let shared = VaultStorage.baseURL(for: .shared)
            let hasSharedVault = ((try? FileManager.default.contentsOfDirectory(atPath: shared.path)) ?? [])
                .contains { !$0.hasPrefix(".") }
            vaultLocation = hasSharedVault ? .shared : .private
            defaults.set(vaultLocation.rawValue, forKey: Key.vaultLocation)
        }
    }
}
