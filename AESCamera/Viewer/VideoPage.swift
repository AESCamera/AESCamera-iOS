@preconcurrency import AVFoundation
import AVKit
import AESCore
import SwiftUI

/// Integrity verdicts, so a long video isn't re-read on every visit. Emptied on lock.
@MainActor
final class VerificationCache {
    static let shared = VerificationCache()
    private var verdicts: [String: EncvVerification] = [:]

    func verdict(for url: URL, secret: Secret) -> EncvVerification? {
        verdicts["\(secret.fingerprint)/\(url.path)"]
    }

    func store(_ verdict: EncvVerification, for url: URL, secret: Secret) {
        verdicts["\(secret.fingerprint)/\(url.path)"] = verdict
    }

    func purge() {
        verdicts.removeAll()
    }
}

/// A video page. It owns a player only while it's the visible page, so at most one
/// player exists. Before the first play the file is checked against its HMAC trailer:
/// failed → refuse; unverified (old or interrupted recording) → play with a badge.
struct VideoPage: View {
    let item: MediaItem
    let isCurrent: Bool
    let onTap: () -> Void

    private enum Phase {
        case idle
        case verifying
        case playing(AVPlayer, EncryptedAssetLoader)
        case failed(String)
    }

    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .idle
    @State private var unverified = false

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                Thumbnail(item: item)
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            case .verifying:
                ProgressView("Checking video…").tint(.white).foregroundStyle(.white)
            case .playing(let player, _):
                VideoPlayer(player: player)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(alignment: .top) {
            if unverified, case .playing = phase {
                Label("Unverified", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.top, 110)
                    .accessibilityHint("This video has no integrity check: it's an older or interrupted recording.")
            }
        }
        .task(id: isCurrent) {
            if isCurrent {
                await start()
            } else {
                stop()
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() async {
        guard let secret = session.secret else { return }
        let url = item.url
        let verdict: EncvVerification
        if let cached = VerificationCache.shared.verdict(for: url, secret: secret) {
            verdict = cached
        } else {
            phase = .verifying
            verdict = await Task.detached(priority: .userInitiated) { EncvReader.verify(url: url, secret: secret) }.value
            guard !Task.isCancelled else { return }
            VerificationCache.shared.store(verdict, for: url, secret: secret)
        }
        if verdict == .failed {
            phase = .failed("This video doesn't open with this password, or it was changed or damaged.")
            return
        }
        unverified = verdict == .unverified

        do {
            let reader = try await Task.detached { try EncvReader(url: url, secret: secret) }.value
            guard reader.header.container == .fragmentedMP4 else {
                phase = .failed("Playing videos recorded on Android isn't supported yet.")
                return
            }
            let loader = EncryptedAssetLoader(reader: reader)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
            guard !Task.isCancelled else { return }
            phase = .playing(player, loader)
            player.play()
        } catch {
            phase = .failed("This video can't be opened.")
        }
    }

    private func stop() {
        if case .playing(let player, _) = phase {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        phase = .idle
    }
}
