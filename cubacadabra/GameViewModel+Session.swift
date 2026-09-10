import Foundation

extension GameViewModel {
    /// Replayed by the shell even when no engine is loaded yet.
    func applyAccountSession(_ session: AppGameSession) {
        let previous = accountSession
        guard previous != session else { return }
        accountSession = session
        if previous.accountID != session.accountID {
            gameLoadGeneration &+= 1
            isSelectingGame = false
            isLoading = false
            disconnect()
            worldSocket.resetForGuest()
            serverAppearance = nil
            username = worldSocket.username
            hasEnteredGame = false
        }
        if previous.blockedUserIDs != session.blockedUserIDs {
            blockedPlayerIDs = session.blockedUserIDs
            engine?.setIgnoredPlayerIDs(blockedPlayerIDs)
        }
        worldSocket.setAccessToken(session.accessToken)
        if let name = session.username, !name.isEmpty {
            worldSocket.adoptUsername(name)
            username = name
        }
        engine?.setUsername(username)
        engine?.setAuthenticated(session.accountID != nil)
        // Full appearance comes from the authenticated world session; the
        // accepted body is also applied when updating/recreating a local engine.
        if previous.bodyID != session.bodyID, let engine { applyAccountAppearance(to: engine) }
    }

    func applyAccountAppearance(to engine: EngineBridge) {
        guard let body = accountSession.bodyID else { return }
        let appearance = WorldAppearance(version: 1, body: body, face: serverAppearance?.face,
            outfit: serverAppearance?.outfit, equipment: serverAppearance?.equipment,
            colors: serverAppearance?.colors, revision: engine.appearanceRevision &+ 1)
        guard let data = try? JSONEncoder().encode(appearance),
              let source = String(data: data, encoding: .utf8) else { return }
        _ = engine.setLocalAppearance(source)
    }

    func requestSettingsInteraction() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        requestMyCube()
    }

    func requestMyCube() { onAccountRequested?() }

    func cancelUsernameEdit() {
        usernameEditorOpen = false
        forward = 0
        strafe = 0
        jumpQueued = false
    }

    func saveUsername(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 24 else {
            usernameStatus = "Use 2–24 characters."
            return
        }
        usernameStatus = "Checking that name…"
        worldSocket.setUsername(trimmed)
    }
}
