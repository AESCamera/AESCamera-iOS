@preconcurrency import AVFoundation
import AVKit
import AESCore
import SwiftUI

/// Switches for UI tests, which can't keep up with a playing video (the app never looks
/// idle to XCUITest while frames are being rendered).
enum UITestOptions {
    static let noAutoplay = ProcessInfo.processInfo.arguments.contains("-uitest-no-autoplay")
}

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
        case playingTS(TSPlayer)
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
            case .playingTS(let player):
                TSPlayerView(player: player)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isPlaying ? "Playing video" : "Video page")
        .overlay(alignment: .top) {
            if unverified, isPlaying {
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

    private var isPlaying: Bool {
        switch phase {
        case .playing, .playingTS: true
        default: false
        }
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
            if reader.header.container == .mpeg2TS {
                // Recorded on Android: AVPlayer can't play raw MPEG-TS.
                let player = try await TSPlayer(reader: reader)
                guard !Task.isCancelled else {
                    player.stop()
                    return
                }
                phase = .playingTS(player)
                if !UITestOptions.noAutoplay { player.play() }
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
        switch phase {
        case .playing(let player, _):
            player.pause()
            player.replaceCurrentItem(with: nil)
        case .playingTS(let player):
            player.stop()
        default:
            break
        }
        phase = .idle
    }
}

/// Minimal transport controls for the TS player: play/pause, scrubber, times.
struct TSPlayerView: View {
    let player: TSPlayer
    @State private var scrubbing: Double?
    @State private var seekTask: Task<Void, Never>?

    /// Seeks once the value has been still for a moment. Works for dragging, taps and
    /// VoiceOver adjustments alike (the latter never report "editing ended").
    private func scrub(to value: Double) {
        scrubbing = value
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await player.seek(to: value)
            if scrubbing == value { scrubbing = nil }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TSVideoSurface(player: player)
                .ignoresSafeArea()
            if let failure = player.failure {
                Text(failure).foregroundStyle(.white).padding()
            }
            HStack(spacing: 12) {
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Text(Self.format(scrubbing ?? player.currentTime))
                    .monospacedDigit()
                    .accessibilityIdentifier("Elapsed")
                Slider(
                    value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrub(to: $0) }),
                    in: 0...max(player.duration, 0.1)
                )
                .accessibilityLabel("Position")
                Text(Self.format(player.duration))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 110)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
