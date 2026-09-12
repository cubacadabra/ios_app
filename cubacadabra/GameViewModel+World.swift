import Foundation
import simd

extension GameViewModel {
    var activeRemotePlayers: [RemotePlayerSummary] {
        remotePlayerNames.keys
            .filter { !blockedPlayerIDs.contains($0) }
            .sorted()
            .map { playerID in
                RemotePlayerSummary(id: playerID, username: remotePlayerNames[playerID] ?? defaultPlayerLabel(playerID))
            }
    }

    func reportPlayer(_ player: RemotePlayerSummary, reason: ReportReason, details: String) {
        let service = moderationService
        let currentWorldID = worldID
        Task { [weak self] in
            do {
                try await service.reportPlayer(playerID: player.id, username: player.username, reason: reason.rawValue, details: details, worldID: currentWorldID)
            } catch {
                self?.showModerationNotice("Report could not be sent. Contact support@cubacadabra.com.")
            }
        }
    }

    private var moderationService: ModerationService {
        ModerationService(playerID: worldSocket.playerID, accessToken: worldSocket.accessToken)
    }

    internal func handlePresenceEvent(_ event: WorldPresenceEvent) {
        if event.type == "player_leave" {
            remotePlayerNames.removeValue(forKey: event.playerID)
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        } else {
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        }
        if event.type == "player_join" {
            remotePlayerNames[event.playerID] = event.username ?? defaultPlayerLabel(event.playerID)
        }
        if event.type == "player_join" || event.type == "player_name" {
            remotePlayerNames[event.playerID] = event.username ?? defaultPlayerLabel(event.playerID)
        }
        if event.type != "appearance" { showPresenceEvent(event) }
    }

    internal func handleSessionEvent(_ event: WorldSessionEvent) {
        guard event.playerID == worldSocket.playerID else { return }
        if !event.loggedIn, accountSession.accountID != nil {
            onSessionRejected?(accountSession.sessionID)
        }
        if let serverUsername = event.username, (event.hasUsername || !event.loggedIn), !serverUsername.isEmpty {
            username = serverUsername
            engine?.setUsername(serverUsername)
        }
        if let appearance = event.appearance {
            serverAppearance = appearance
            if appearance.version == 2, let data = try? JSONEncoder().encode(appearance), let source = String(data: data, encoding: .utf8) {
                _ = engine?.setLocalAppearance(source)
                return
            }
            let localAppearance = WorldAppearance(version: appearance.version, base: nil, parts: nil, parameters: nil, body: appearance.body, face: appearance.face, outfit: appearance.outfit, equipment: appearance.equipment, colors: appearance.colors, revision: max(appearance.revision ?? 0, (engine?.appearanceRevision ?? 0) + 1))
            if let data = try? JSONEncoder().encode(localAppearance), let source = String(data: data, encoding: .utf8) { _ = engine?.setLocalAppearance(source) }
        }
    }

    internal func handleMovementEvent(_ event: WorldMovementEvent) {
        if event.isSelf {
            return
        }
        guard !blockedPlayerIDs.contains(event.playerID) else { return }
        if remotePlayerNames[event.playerID] == nil { remotePlayerNames[event.playerID] = defaultPlayerLabel(event.playerID) }
    }

    private func showPresenceEvent(_ event: WorldPresenceEvent) {
        let label = event.username ?? defaultPlayerLabel(event.playerID)
        let action = event.type == "player_join" ? "joined the world" : event.type == "player_name" ? "is now in the lobby" : "left the world"
        let notice = PresenceNotice(message: "\(label) \(action)", joined: event.type != "player_leave")
        presenceNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.presenceNotice?.id == notice.id else { return }
            self?.presenceNotice = nil
        }
    }

    internal func handleUsernameEvent(_ event: WorldUsernameEvent) {
        if event.type == "username_updated", let nextUsername = event.username {
            username = nextUsername
            engine?.setUsername(nextUsername)
            usernameEditorOpen = false
        } else if event.type == "username_error" {
            usernameStatus = switch event.code {
            case "username_taken": "That name is already in use. Try another."
            case "username_not_allowed": "Choose a different name."
            case "age_required": "Add your birthday in your player profile before choosing a name."
            default: "That name could not be saved. Try again."
            }
        }
    }

    internal func connectWorld(_ visualWorldID: String) {
        guard visualWorldID == worldID else { return }
        dispatchClientActions()
    }

    private func showModerationNotice(_ message: String) {
        let notice = ModerationNotice(message: message)
        moderationNotice = notice
        moderationNoticeTask?.cancel()
        moderationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.moderationNotice?.id == notice.id else { return }
            self?.moderationNotice = nil
        }
    }

    func dismissModerationNotice() {
        moderationNoticeTask?.cancel()
        moderationNotice = nil
    }


    private func defaultPlayerLabel(_ playerID: String) -> String {
        let platform = playerID.hasPrefix("ios-") ? "iOS" : playerID.hasPrefix("web-") ? "Web" : "Player"
        return "\(platform) Player \(String(playerID.suffix(4)).uppercased())"
    }
}
