import AVFoundation
import Foundation
import OSLog

private let gameAudioLog = Logger(subsystem: "com.cubacadabra.app", category: "game-audio")

struct LoadedGameAudioAsset {
    let url: URL
    let volume: Float
}

struct EngineAudioCommand: Decodable {
    let type: String
    let id: String
    let volume: Float?
}

/// Plays game-owned, overlapping one-shot sounds without exposing native audio
/// objects or file paths to the game script.
@MainActor
final class GameAudio {
    private final class Playback {
        let player: AVPlayer
        var observers: [NSObjectProtocol] = []

        init(player: AVPlayer) {
            self.player = player
        }
    }

    private var assets: [String: LoadedGameAudioAsset] = [:]
    private var active: [UUID: Playback] = [:]
    private var audioSessionActive = false

    func configure(with assets: [String: LoadedGameAudioAsset]) {
        stopAll()
        self.assets = assets
    }

    @discardableResult
    func play(_ command: EngineAudioCommand) -> Bool {
        guard command.type == "play" else { return false }
        guard let asset = assets[command.id] else {
            gameAudioLog.warning("Game requested unknown audio asset \"\(command.id, privacy: .public)\".")
            return false
        }

        activateAudioSessionIfNeeded()

        let item = AVPlayerItem(url: asset.url)
        let player = AVPlayer(playerItem: item)
        player.volume = asset.volume * clampedVolume(command.volume ?? 1)
        let id = UUID()
        let playback = Playback(player: player)
        let center = NotificationCenter.default
        playback.observers = [
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishPlayback(id) }
            },
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                        gameAudioLog.error("Audio playback failed: \(error.localizedDescription, privacy: .public)")
                    }
                    self?.finishPlayback(id)
                }
            },
        ]
        active[id] = playback
        player.play()
        return true
    }

    func stopAll() {
        let center = NotificationCenter.default
        for playback in active.values {
            playback.player.pause()
            playback.observers.forEach(center.removeObserver)
        }
        active.removeAll()
        deactivateAudioSessionIfNeeded()
    }

    private func finishPlayback(_ id: UUID) {
        guard let playback = active.removeValue(forKey: id) else { return }
        playback.observers.forEach(NotificationCenter.default.removeObserver)
        if active.isEmpty {
            deactivateAudioSessionIfNeeded()
        }
    }

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            gameAudioLog.error("Could not activate game audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSessionIfNeeded() {
        guard audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            gameAudioLog.error("Could not deactivate game audio: \(error.localizedDescription, privacy: .public)")
        }
        audioSessionActive = false
    }

    private func clampedVolume(_ value: Float) -> Float {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
