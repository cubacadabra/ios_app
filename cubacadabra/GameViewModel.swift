import Foundation
import Combine
import SwiftUI
import simd
import OSLog
import UIKit

private let gameLog = Logger(subsystem: "com.cubacadabra.app", category: "game")

private struct EngineUIEvent: Decodable {
    let nodeID: String
    let action: String
    let phase: String
    let value: Float?
    let x: Float?
    let y: Float?

    enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId"
        case action
        case phase
        case value
        case x
        case y
    }
}

private struct RemotePlayerState {
    var position: SIMD3<Float>
    var yaw: Float
    var moving: Bool
    var sprinting: Bool
    var generation: UInt32
    var motionSequence: UInt64
    var appearance: WorldAppearance?
}

private struct RemoteUpdateMessage: Encodable {
    let version: UInt16
    let sequence: UInt64
    let worldID: String?
    let players: [RemoteUpdatePlayer]

    enum CodingKeys: String, CodingKey {
        case version, sequence
        case worldID = "worldId"
        case players
    }
}

private struct RemoteUpdatePlayer: Encodable {
    let id: String
    let generation: UInt32
    let position: [Float]
    let yaw: Float
    let moving: Bool
    let sprinting: Bool
    let motionSequence: UInt64
    let appearance: WorldAppearance?
}

@MainActor
final class GameViewModel: ObservableObject {
    @Published private(set) var package: GamePackage?
    @Published private(set) var worldID = "lobby"
    @Published private(set) var frame: EngineFrame?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionState = WorldConnectionState.disconnected
    @Published private(set) var presenceNotice: PresenceNotice?
    @Published private(set) var username = ""
    @Published private(set) var usernameStatus = "Choose a name other players can find you by."
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authUser: AppAuthUser?
    @Published private(set) var isSigningIn = false
    @Published private(set) var authenticationNotice: String?
    @Published private(set) var myCubeRequestID = 0
    @Published private(set) var settingsRoomState: UInt8 = 0
    @Published private(set) var usernameEditorOpen = false
    @Published private(set) var safetyRequestID = 0
    @Published private(set) var remotePlayerNames: [String: String] = [:]
    @Published private(set) var blockedPlayerIDs: Set<String>
    @Published private(set) var moderationNotice: ModerationNotice?
    @Published private(set) var gameExitRequestID = 0
    @Published private(set) var buildPrompt = ""
    @Published private(set) var buildPhase = "build"
    @Published private(set) var buildBlockCount = 0
    @Published private(set) var buildBlocks: [WorldBuildBlock] = []
    @Published private(set) var lobbyLaunchStartsAt: Date?
    private var lobbyLaunchClockOffset: TimeInterval = 0
    @Published var buildTool = "place"
    @Published var buildShape = "cube"
    @Published var buildColor = "coral"
    @Published private(set) var buildActionNotice: String?
    @Published private(set) var hasEnteredGame = false
    @Published private(set) var selectedGameID = "first-game"
    @Published private(set) var isSelectingGame = false
    private(set) var isFreshInstall = false
    @Published var sprinting = false

    var selectedGame: GameCatalogEntry {
        GameCatalogEntry.available.first { $0.id == selectedGameID } ?? GameCatalogEntry.available[0]
    }

    private let loader = GamePackageLoader()
    private let authentication = AppAuthenticationService()
    private let googleSignIn = NativeGoogleSignInService()
    private let installationMarkerKey = "cubacadabra.installation-marker"
    private let blockedPlayerIDsKey = "cubacadabra.blocked-player-ids"
    private var engine: EngineBridge?
    private var lastTick: Date?
    private var runtimeWorldIDs: [String] = []
    private var forward: Float = 0
    private var strafe: Float = 0
    private var jumpQueued = false
    private var lookX: Float = 0
    private var lookY: Float = 0
    private var zoomDelta: Float = 0
    private var noticeTask: Task<Void, Never>?
    private var moderationNoticeTask: Task<Void, Never>?
    private var buildActionNoticeTask: Task<Void, Never>?
    private var remotePlayers: [String: RemotePlayerState] = [:]
    private var remoteSequence: UInt64 = 0
    private var remoteRosterDirty = true
    private var connectedWorldID: String?
    private var pendingSessionWorldID: String?
    private var gamePaused = false
    private var characterLabActive = false
    private var characterLabMotion = "idle"
    private var characterLabJumpQueued = false
    private var characterLabAppearanceRevision: UInt32 = 0

    init() {
        // iOS can retain Keychain credentials after an app is deleted. The
        // UserDefaults marker does not survive deletion, so a missing marker
        // means this is a fresh install and the old signed-in session must not
        // put the user straight back into an under-13 gate.
        isFreshInstall = UserDefaults.standard.string(forKey: installationMarkerKey) == nil
        let hasLocalInstallData = UserDefaults.standard.string(forKey: "cubacadabra.player-id") != nil
        if isFreshInstall {
            UserDefaults.standard.set(UUID().uuidString, forKey: installationMarkerKey)
            if !hasLocalInstallData {
                authentication.clearTokens()
                googleSignIn.signOut()
            }
        }
        let storedIDs = UserDefaults.standard.stringArray(forKey: blockedPlayerIDsKey) ?? []
        blockedPlayerIDs = Set(storedIDs)
    }

    private lazy var worldSocket = WorldSocketClient(
        onStateChange: { [weak self] state in
            self?.connectionState = state
        },
        onEvent: { [weak self] event in
            self?.handlePresenceEvent(event)
        },
        onSession: { [weak self] event in
            self?.handleSessionEvent(event)
        },
        onMove: { [weak self] event in
            self?.handleMovementEvent(event)
        },
        onUsername: { [weak self] event in
            self?.handleUsernameEvent(event)
        },
        onExperience: { [weak self] event in
            self?.handleExperienceEvent(event)
        }
    )

    func load() async {
        guard engine == nil else {
            connectWorld(worldID)
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await loader.load(gameID: "first-game")
            let loadedPackage = loaded.package
            guard loadedPackage.worldDefinition(named: loadedPackage.startWorld) != nil else {
                throw GamePackageError.missingWorld(loadedPackage.startWorld)
            }
            let loadedEngine = try makeEngine(from: loaded)
            runtimeWorldIDs = loadedPackage.runtimeWorldEntries().map(\.id)
            package = loadedPackage
            selectedGameID = "first-game"
            username = worldSocket.username
            loadedEngine.setUsername(username)
            worldID = loadedPackage.startWorld
            worldSocket.setHidden(worldID == "settings")
            engine = loadedEngine
            let initialFrame = loadedEngine.frame()
            frame = initialFrame
            lastTick = nil
            isLoading = false
            if let authResult = await authentication.restore() {
                applyAuthentication(authResult)
            }
            Task { [weak self] in
                await self?.loader.refreshPackage(gameID: "first-game")
                await self?.refreshBlockedPlayers()
            }
        } catch {
            gameLog.error("Game load failed: \(error.localizedDescription, privacy: .public)")
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func retry() {
        worldSocket.disconnect()
        connectedWorldID = nil
        engine = nil
        package = nil
        frame = nil
        hasEnteredGame = false
        Task { await load() }
    }

    func refreshAuthentication() {
        guard engine != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if let authResult = await authentication.restore() {
                applyAuthentication(authResult)
            } else {
                clearAuthentication()
            }
        }
    }

    func tick(at date: Date) {
        guard let engine, frame != nil, !gamePaused else { return }
        guard let lastTick else {
            self.lastTick = date
            return
        }
        let delta = Float(min(max(date.timeIntervalSince(lastTick), 0), 0.05))
        self.lastTick = date
        syncRemotePlayers()
        let labForward: Float = switch characterLabMotion {
        case "walk": 1
        case "run": 1
        default: 0
        }
        engine.setInput(
            forward: characterLabActive ? labForward : (usernameEditorOpen ? 0 : forward),
            strafe: usernameEditorOpen ? 0 : strafe,
            sprint: characterLabActive ? characterLabMotion == "run" : (usernameEditorOpen ? false : sprinting),
            jump: characterLabActive ? characterLabJumpQueued : (usernameEditorOpen ? false : jumpQueued),
            lookX: usernameEditorOpen ? 0 : lookX,
            lookY: usernameEditorOpen ? 0 : lookY,
            zoomDelta: usernameEditorOpen ? 0 : zoomDelta
        )
        jumpQueued = false
        characterLabJumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        engine.step(delta)
        if characterLabActive {
            frame = engine.frame()
            return
        }
        handleUIEvents()
        let nextFrame = engine.frame()
        updateSettingsRoomState(nextFrame.settingsRoomState)
        if let activeWorldID = runtimeWorldIDs[safe: nextFrame.activeWorldIndex],
           activeWorldID != worldID {
            worldID = activeWorldID
            worldSocket.setHidden(activeWorldID == "settings")
            forward = 0
            strafe = 0
            sprinting = false
            connectWorld(activeWorldID)
        }
        frame = nextFrame
        if worldID != "settings" {
            worldSocket.sendMove(
                position: nextFrame.player.position,
                yaw: nextFrame.player.yaw,
                moving: nextFrame.player.moving,
                sprinting: nextFrame.player.sprinting
            )
        }
    }

    func setMove(strafe: Float, forward: Float) {
        guard !usernameEditorOpen else { return }
        self.strafe = strafe
        self.forward = forward
    }

    func jump() {
        guard !usernameEditorOpen else { return }
        jumpQueued = true
    }

    func lookChanged(to translation: CGSize) {
        guard !usernameEditorOpen else { return }
        lookX += Float(translation.width)
        lookY += Float(translation.height)
    }

    func lookEnded() {}

    func zoomChangedBy(delta: CGFloat) {
        guard !usernameEditorOpen else { return }
        zoomDelta -= Float(delta * 20)
    }

    func zoomEnded() {}

    func toggleSprinting() {
        guard !usernameEditorOpen else { return }
        sprinting.toggle()
    }

    func world() -> WorldDefinition? {
        package?.worldDefinition(named: worldID)
    }

    var renderEngine: EngineBridge? { engine }

    private func handleUIEvents() {
        guard let engine else { return }
        while let data = engine.pollUIEvent() {
            let event: EngineUIEvent
            do {
                event = try JSONDecoder().decode(EngineUIEvent.self, from: data)
            } catch {
                gameLog.error("Discarding malformed Rust UI event: \(error.localizedDescription, privacy: .public)")
                continue
            }
            switch event.action {
            case "player.move":
                setMove(strafe: event.x ?? 0, forward: -(event.y ?? 0))
            case "player.jump" where event.phase == "activate":
                jump()
            case "player.run" where event.phase == "activate":
                toggleSprinting()
            case "hud.safety" where event.phase == "activate":
                safetyRequestID &+= 1
            case "shared.about.open" where event.phase == "activate":
                UIApplication.shared.open(AppLinks.about)
            case "shared.sign_in" where event.phase == "activate":
                requestMyCube()
            case "shared.leave_game" where event.phase == "activate":
                gameExitRequestID &+= 1
            case "build.tool" where event.phase == "activate":
                let tools = ["place", "rotate", "remove", "recolor"]
                buildTool = tools[(tools.firstIndex(of: buildTool).map { ($0 + 1) % tools.count } ?? 0)]
            case let action where
                ["build.place", "build.rotate", "build.remove", "build.recolor"].contains(action) &&
                event.phase == "activate":
                buildTool = String(action.dropFirst("build.".count))
                performBuildAction()
            case "build.use" where event.phase == "activate":
                performBuildAction()
            case "build.save" where event.phase == "activate":
                saveBuild()
            case "build.return" where event.phase == "activate":
                returnToLobby()
            case "build.shape" where event.phase == "activate":
                cycleBuildShape()
            case "build.color" where event.phase == "activate":
                cycleBuildColor()
            case let action where action.hasPrefix("build.shape.") && event.phase == "activate":
                buildShape = String(action.dropFirst("build.shape.".count))
            case let action where action.hasPrefix("build.color.") && event.phase == "activate":
                buildColor = String(action.dropFirst("build.color.".count))
            default:
                break
            }
            gameLog.debug("Rust UI event node=\(event.nodeID, privacy: .public) action=\(event.action, privacy: .public) phase=\(event.phase, privacy: .public)")
        }
    }

    func requestSettingsInteraction() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        requestMyCube()
    }

    func requestMyCube() {
        guard !isSigningIn else { return }
        if isAuthenticated {
            myCubeRequestID &+= 1
        } else {
            beginSignIn(presentMyCube: true)
        }
    }

    /// Starts the account flow from the app's full-screen sign-in state.
    func signIn() {
        beginSignIn()
    }

    /// Ends the signed-in session and leaves the app at its sign-in screen.
    /// The profile's birthday is server-owned and is never removed locally.
    func logOut() {
        authentication.clearTokens()
        googleSignIn.signOut()
        worldSocket.disconnect()
        connectedWorldID = nil
        hasEnteredGame = false
        isAuthenticated = false
        authUser = nil
        authenticationNotice = nil
        engine?.setAuthenticated(false)
        worldSocket.setAccessToken(nil)
    }

    var profileAge: Int? {
        guard let dob = authUser?.dateOfBirth else { return nil }
        return Self.calculateAge(from: dob)
    }

    var needsBirthday: Bool {
        isAuthenticated && authUser?.dateOfBirth == nil
    }

    var isUnderThirteen: Bool {
        profileAge.map { $0 < 13 } ?? false
    }

    func storedParentEmail() -> String {
        guard let userID = authUser?.id else { return "" }
        return UserDefaults.standard.string(forKey: "cubacadabra.parent-email.\(userID)") ?? ""
    }

    func saveParentEmail(_ email: String) {
        guard let userID = authUser?.id else { return }
        UserDefaults.standard.set(email, forKey: "cubacadabra.parent-email.\(userID)")
    }

    func selectGame(_ game: GameCatalogEntry) async throws {
        guard GameCatalogEntry.available.contains(game) else { throw GamePackageError.invalidGameID }
        guard selectedGameID != game.id || package == nil else { return }

        isSelectingGame = true
        defer { isSelectingGame = false }

        let loaded = try await loader.load(gameID: game.id)
        let nextEngine = try makeEngine(from: loaded)
        let nextPackage = loaded.package

        worldSocket.disconnect()
        worldSocket.setGameID(game.id)
        connectedWorldID = nil
        pendingSessionWorldID = nil
        remotePlayers.removeAll()
        remotePlayerNames.removeAll()
        remoteSequence = 0
        remoteRosterDirty = true
        engine = nextEngine
        package = nextPackage
        selectedGameID = game.id
        runtimeWorldIDs = nextPackage.runtimeWorldEntries().map(\.id)
        worldID = nextPackage.startWorld
        frame = nextEngine.frame()
        buildPhase = "build"
        buildPrompt = ""
        buildBlockCount = 0
        buildBlocks = []
        nextEngine.setBuildBlocks([])
        worldSocket.setHidden(worldID == "settings")
        if hasEnteredGame {
            connectWorld(worldID)
        }
    }

    private func requestUsernameEdit() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        usernameStatus = "Choose a unique name using 2–24 characters."
        usernameEditorOpen = true
        forward = 0
        strafe = 0
        jumpQueued = false
    }

    private func beginSignIn(presentMyCube: Bool = false) {
        guard !isSigningIn else { return }
        isSigningIn = true
        authenticationNotice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await googleSignIn.signIn()
                let result = try await authentication.authenticateGoogle(credential: credential)
                applyAuthentication(result)
                if presentMyCube {
                    myCubeRequestID &+= 1
                }
            } catch let error as AppAuthError where error == .cancelled {
                // The user dismissed the Google sign-in flow.
            } catch {
                gameLog.error("Native sign-in failed: \(error.localizedDescription, privacy: .public)")
                authenticationNotice = "We couldn’t sign you in. Try again."
            }
            isSigningIn = false
        }
    }

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

    func saveBirthday(_ dob: String) async throws -> AppProfileUpdateResult {
        let result = try await authentication.saveBirthday(dob)
        authUser = result.user
        return result
    }

    func saveProfileUsername(_ value: String) async throws -> AppProfileUpdateResult {
        let result = try await authentication.saveUsername(value)
        applyProfileUpdate(result)
        return result
    }

    private func applyProfileUpdate(_ result: AppProfileUpdateResult) {
        authUser = result.user
        guard let nextUsername = result.user.username, !nextUsername.isEmpty else { return }
        username = nextUsername
        worldSocket.adoptUsername(nextUsername)
        engine?.setUsername(nextUsername)
    }

    func disconnect() {
        worldSocket.disconnect()
        connectedWorldID = nil
    }

    func enterGame() {
        guard engine != nil else { return }
        hasEnteredGame = true
        gamePaused = false
        lastTick = nil
        connectWorld(worldID)
    }

    func beginCharacterLab() {
        guard let engine else { return }
        characterLabActive = true
        gamePaused = false
        lastTick = nil
        forward = 0
        strafe = 0
        jumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        characterLabMotion = "idle"
        characterLabJumpQueued = false
        characterLabAppearanceRevision = max(engine.appearanceRevision, 1)
        remoteRosterDirty = true
        engine.setReducedEffects(false)
        engine.setUISuppressed(true)
        engine.resetShowcaseView()
        frame = engine.frame()
    }

    func endCharacterLab() {
        guard characterLabActive else { return }
        characterLabActive = false
        characterLabMotion = "idle"
        characterLabJumpQueued = false
        remoteRosterDirty = true
        engine?.setReducedEffects(false)
        engine?.setUISuppressed(false)
        pauseGame()
    }

    func setCharacterLabMotion(_ motion: String) {
        guard characterLabActive else { return }
        characterLabMotion = motion
        if motion == "jump" {
            characterLabJumpQueued = true
        }
    }

    func triggerCharacterLabWave() {
        guard characterLabActive else { return }
        engine?.triggerLocalWave()
    }

    @discardableResult
    func applyCharacterLabAppearance(body: String, face: String, outfit: String) -> UInt8 {
        guard let engine else { return 0 }
        characterLabAppearanceRevision = max(characterLabAppearanceRevision + 1, engine.appearanceRevision + 1)
        let definition: [String: Any] = [
            "version": 1,
            "body": body,
            "face": face,
            "outfit": outfit,
            "revision": characterLabAppearanceRevision,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: definition),
              let source = String(data: data, encoding: .utf8) else { return 0 }
        let status = engine.setLocalAppearance(source)
        if status == 1 || status == 3 {
            worldSocket.setAppearance(source)
        }
        frame = engine.frame()
        return status
    }

    func pauseGame() {
        gamePaused = true
        lastTick = nil
        forward = 0
        strafe = 0
        jumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        usernameEditorOpen = false
    }

    func leaveGame() {
        returnToLobby()
        disconnect()
        pauseGame()
        hasEnteredGame = false
    }

    func exitToHome() {
        disconnect()
        pauseGame()
    }

    var activeRemotePlayers: [RemotePlayerSummary] {
        remotePlayerNames.keys
            .filter { !blockedPlayerIDs.contains($0) }
            .sorted()
            .map { playerID in
                RemotePlayerSummary(
                    id: playerID,
                    username: remotePlayerNames[playerID] ?? defaultPlayerLabel(playerID)
                )
            }
    }

    func blockPlayer(_ player: RemotePlayerSummary) {
        guard !blockedPlayerIDs.contains(player.id) else { return }
        blockedPlayerIDs.insert(player.id)
        persistBlockedPlayerIDs()
        showModerationNotice("\(player.username) is blocked. You can unblock them in Players & Safety.")
        let service = moderationService
        Task { [weak self] in
            do {
                try await service.blockPlayer(player.id)
            } catch {
                guard let self else { return }
                blockedPlayerIDs.remove(player.id)
                persistBlockedPlayerIDs()
                showModerationNotice("That block could not be saved. Try again.")
            }
        }
    }

    func unblockPlayer(_ playerID: String) {
        guard blockedPlayerIDs.remove(playerID) != nil else { return }
        persistBlockedPlayerIDs()
        showModerationNotice("Player unblocked.")
        let service = moderationService
        Task { [weak self] in
            do {
                try await service.unblockPlayer(playerID)
            } catch {
                guard let self else { return }
                blockedPlayerIDs.insert(playerID)
                persistBlockedPlayerIDs()
                showModerationNotice("That unblock could not be saved. Try again.")
            }
        }
    }

    func reportPlayer(_ player: RemotePlayerSummary, reason: ReportReason, details: String) {
        let service = moderationService
        let currentWorldID = worldID
        Task { [weak self] in
            do {
                try await service.reportPlayer(
                    playerID: player.id,
                    username: player.username,
                    reason: reason.rawValue,
                    details: details,
                    worldID: currentWorldID
                )
            } catch {
                self?.showModerationNotice("Report could not be sent. Contact support@cubacadabra.com.")
            }
        }
    }

    private var moderationService: ModerationService {
        ModerationService(playerID: worldSocket.playerID, accessToken: worldSocket.accessToken)
    }

    private func refreshBlockedPlayers() async {
        guard let serverIDs = try? await moderationService.fetchBlockedPlayerIDs() else { return }
        blockedPlayerIDs.formUnion(serverIDs)
        persistBlockedPlayerIDs()
    }

    private func handlePresenceEvent(_ event: WorldPresenceEvent) {
        if event.type == "player_leave" {
            remotePlayers.removeValue(forKey: event.playerID)
            remotePlayerNames.removeValue(forKey: event.playerID)
            remoteRosterDirty = true
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        } else {
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        }
        if event.type == "player_join" {
            remotePlayers[event.playerID] = RemotePlayerState(
                position: .zero,
                yaw: 0,
                moving: false,
                sprinting: false,
                generation: event.generation,
                motionSequence: event.motionSequence,
                appearance: event.appearance
            )
            remoteRosterDirty = true
        } else if event.type == "appearance" {
            remotePlayers[event.playerID]?.appearance = event.appearance
            remoteRosterDirty = true
        }
        if event.type == "player_join" || event.type == "player_name" {
            remotePlayerNames[event.playerID] = event.username ?? defaultPlayerLabel(event.playerID)
        }
        if event.type != "appearance" {
            showPresenceEvent(event)
        }
    }

    private func handleSessionEvent(_ event: WorldSessionEvent) {
        guard event.playerID == worldSocket.playerID else { return }
        isAuthenticated = event.loggedIn
        if !event.loggedIn {
            authUser = nil
        }
        if let serverUsername = event.username,
           event.hasUsername,
           !serverUsername.isEmpty {
            username = serverUsername
            engine?.setUsername(serverUsername)
        }
        if let appearance = event.appearance,
           let data = try? JSONEncoder().encode(appearance),
           let source = String(data: data, encoding: .utf8) {
            _ = engine?.setLocalAppearance(source)
        }
    }

    private func applyAuthentication(_ result: AppAuthResult) {
        isAuthenticated = true
        authUser = result.user
        authenticationNotice = nil
        engine?.setAuthenticated(true)
        worldSocket.setAccessToken(result.accessToken)
        if let serverUsername = result.user.username, !serverUsername.isEmpty {
            worldSocket.adoptUsername(serverUsername)
            username = serverUsername
            engine?.setUsername(serverUsername)
        }
    }

    private func makeEngine(from loaded: LoadedGamePackage) throws -> EngineBridge {
        let loadedEngine = try EngineBridge()
        do {
            try loadedEngine.loadPackage(loaded.manifest)
            try loadedEngine.loadScript(loaded.script)
        } catch {
            throw error
        }
        loadedEngine.setAuthenticated(isAuthenticated)
        loadedEngine.setUsername(username)
        gameLog.info("Rust package and script loaded; UI nodes: \(loadedEngine.uiNodeCount, privacy: .public)")
        return loadedEngine
    }

    private func clearAuthentication() {
        isAuthenticated = false
        authUser = nil
        engine?.setAuthenticated(false)
        worldSocket.setAccessToken(nil)
    }

    private static func calculateAge(from dob: String) -> Int? {
        let values = dob.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              let year = values[safe: 0],
              let month = values[safe: 1],
              let day = values[safe: 2] else { return nil }
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let currentYear = now.year else { return nil }
        var age = currentYear - year
        if (now.month ?? 0, now.day ?? 0) < (month, day) { age -= 1 }
        return age
    }

    private func handleMovementEvent(_ event: WorldMovementEvent) {
        if event.isSelf {
            if event.corrected {
                engine?.reconcilePlayer(position: event.position, yaw: event.yaw)
            }
            return
        }
        guard !blockedPlayerIDs.contains(event.playerID) else { return }
        if remotePlayerNames[event.playerID] == nil {
            remotePlayerNames[event.playerID] = defaultPlayerLabel(event.playerID)
        }
        let previous = remotePlayers[event.playerID]
        remotePlayers[event.playerID] = RemotePlayerState(
            position: event.position,
            yaw: event.yaw,
            moving: event.moving,
            sprinting: event.sprinting,
            generation: event.generation == 0 ? previous?.generation ?? 0 : event.generation,
            motionSequence: event.motionSequence,
            appearance: previous?.appearance
        )
        remoteRosterDirty = true
    }

    private func showPresenceEvent(_ event: WorldPresenceEvent) {
        let label = event.username ?? defaultPlayerLabel(event.playerID)
        let action: String
        if event.type == "player_join" {
            action = "joined the world"
        } else if event.type == "player_name" {
            action = "is now in the lobby"
        } else {
            action = "left the world"
        }
        let notice = PresenceNotice(
            message: "\(label) \(action)",
            joined: event.type != "player_leave"
        )
        presenceNotice = notice

        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.presenceNotice?.id == notice.id else { return }
            self?.presenceNotice = nil
        }
    }

    private func handleUsernameEvent(_ event: WorldUsernameEvent) {
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

    private func handleExperienceEvent(_ event: WorldExperienceEvent) {
        if event.type == "experience_launch",
           event.playerIDs.contains(worldSocket.playerID),
           let sessionWorldID = event.sessionWorldID,
           let sessionIndex = runtimeWorldIDs.firstIndex(of: "real-game") {
            pendingSessionWorldID = sessionWorldID
            engine?.startWorld(sessionIndex)
            return
        }
        if event.type == "experience_state", event.kind == "lobby" {
            lobbyLaunchStartsAt = event.startsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            lobbyLaunchClockOffset = Date().timeIntervalSince1970 - Double(event.serverNow ?? Int64(Date().timeIntervalSince1970 * 1000)) / 1000
            return
        }
        guard event.type == "experience_state", event.kind == "build" else { return }
        buildPhase = event.phase ?? "build"
        buildPrompt = event.prompt ?? "Build together."
        buildBlockCount = event.blockCount ?? 0
        buildBlocks = event.blocks
        engine?.setBuildBlocks(event.blocks.map(engineBlock))
    }

    private func engineBlock(_ block: WorldBuildBlock) -> EngineBuildBlock {
        let size: SIMD3<Float> = switch block.shape {
        case "beam": SIMD3(3, 1, 1)
        case "slab": SIMD3(2, 0.5, 2)
        default: SIMD3(repeating: 1)
        }
        let colors: [String: UInt32] = ["coral": 0xed725b, "butter": 0xf2c764, "periwinkle": 0x7898dc, "ink": 0x264b4b, "paper": 0xf6f1e7]
        return EngineBuildBlock(
            position: SIMD3(block.x, block.y, block.z),
            size: size,
            color: colors[block.color] ?? colors["coral"]!,
            rotation: UInt8(block.rotation)
        )
    }

    func cycleBuildShape() {
        let shapes = ["cube", "beam", "slab"]
        buildShape = shapes[((shapes.firstIndex(of: buildShape) ?? 0) + 1) % shapes.count]
    }

    func cycleBuildColor() {
        let colors = ["coral", "butter", "periwinkle", "ink", "paper"]
        buildColor = colors[(colors.firstIndex(of: buildColor).map { ($0 + 1) % colors.count } ?? 0)]
    }

    func performBuildAction() {
        guard worldID == "real-game" else {
            gameLog.error("Build action ignored outside real-game; world=\(self.worldID, privacy: .public)")
            showBuildActionNotice("Building is unavailable here")
            return
        }
        guard let frame else {
            gameLog.error("Build action ignored because no engine frame is available")
            showBuildActionNotice("World is still loading")
            return
        }
        let shapes: [String: SIMD3<Float>] = ["cube": SIMD3(repeating: 1), "beam": SIMD3(3, 1, 1), "slab": SIMD3(2, 0.5, 2)]
        let size = shapes[buildShape] ?? SIMD3(repeating: 1)
        let target = SIMD3(
            round((frame.player.position.x + sin(frame.camera.x) * 4) * 2) / 2,
            size.y / 2,
            round((frame.player.position.z - cos(frame.camera.x) * 4) * 2) / 2
        )
        if buildTool == "place" {
            let result = worldSocket.sendExperience("build_action", payload: ["action": "place", "block": ["x": target.x, "y": target.y, "z": target.z, "shape": buildShape, "color": buildColor]])
            handleBuildSendResult(result, action: "place")
            return
        }
        guard let nearest = buildBlocks.min(by: { lhs, rhs in
            distance(SIMD3(lhs.x, lhs.y, lhs.z), target) < distance(SIMD3(rhs.x, rhs.y, rhs.z), target)
        }), distance(SIMD3(nearest.x, nearest.y, nearest.z), target) < 2.1 else {
            showBuildActionNotice("Look toward a nearby block")
            return
        }
        var payload: [String: Any] = ["action": buildTool, "id": nearest.id]
        if buildTool == "recolor" { payload["color"] = buildColor }
        let result = worldSocket.sendExperience("build_action", payload: payload)
        handleBuildSendResult(result, action: buildTool)
    }

    private func handleBuildSendResult(_ result: ExperienceSendResult, action: String) {
        switch result {
        case .sent:
            gameLog.debug("Build action sent: \(action, privacy: .public)")
        case .queued:
            gameLog.info("Build action queued while reconnecting: \(action, privacy: .public)")
            showBuildActionNotice("Reconnecting — action queued")
        case .unavailable:
            gameLog.error("Build action unavailable: \(action, privacy: .public)")
            showBuildActionNotice("Can’t reach the shared build")
        case .invalid:
            gameLog.error("Build action could not be encoded: \(action, privacy: .public)")
            showBuildActionNotice("Couldn’t send that action")
        }
    }

    private func showBuildActionNotice(_ message: String) {
        buildActionNotice = message
        buildActionNoticeTask?.cancel()
        buildActionNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, self?.buildActionNotice == message else { return }
            self?.buildActionNotice = nil
        }
    }

    func saveBuild() { worldSocket.sendExperience("build_save") }

    func returnToLobby() {
        pendingSessionWorldID = nil
        guard let index = runtimeWorldIDs.firstIndex(of: "lobby"), engine?.startWorld(index) == true else { return }
        worldID = "lobby"
        buildPhase = "build"
        buildPrompt = ""
        buildBlocks = []
        buildBlockCount = 0
        engine?.setBuildBlocks([])
        worldSocket.setHidden(false)
        connectWorld("lobby")
    }

    func lobbyLaunchStatus(for pad: LaunchPadDefinition, live: EnginePad?) -> String {
        guard pad.enabled else { return pad.availabilityLabel }
        guard let startsAt = lobbyLaunchStartsAt else { return status(for: live) }
        let remaining = startsAt.timeIntervalSince1970 - (Date().timeIntervalSince1970 - lobbyLaunchClockOffset)
        return remaining > 0 ? String(format: "%.1fs", remaining) : "LAUNCHING"
    }

    private func status(for pad: EnginePad?) -> String {
        guard let pad else { return "WAITING" }
        if pad.phase == 2 { return "LAUNCHING" }
        if pad.seconds > 0 { return String(format: "%.1fs · %d", pad.seconds, pad.occupants) }
        return pad.occupants == 0 ? "WAITING" : "ASSEMBLING"
    }

    private func updateSettingsRoomState(_ roomState: UInt8) {
        settingsRoomState = roomState
        if roomState == 0 { usernameEditorOpen = false }
    }

    private func connectWorld(_ visualWorldID: String) {
        let networkWorldID = visualWorldID == "settings"
            ? "lobby"
            : visualWorldID == "real-game" && pendingSessionWorldID != nil
                ? pendingSessionWorldID!
                : visualWorldID
        guard networkWorldID != connectedWorldID else { return }
        connectedWorldID = networkWorldID
        remotePlayers.removeAll()
        remotePlayerNames.removeAll()
        remoteSequence = 0
        remoteRosterDirty = true
        engine?.resetRemoteSession()
        worldSocket.connect(worldID: networkWorldID)
    }

    private func syncRemotePlayers() {
        guard remoteRosterDirty, let engine else { return }
        let players: [RemoteUpdatePlayer] = characterLabActive || worldID == "settings"
            ? []
            : remotePlayers
                .filter { !blockedPlayerIDs.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { playerID, player in
                    RemoteUpdatePlayer(
                        id: playerID,
                        generation: player.generation,
                        position: [player.position.x, player.position.y, player.position.z],
                        yaw: player.yaw,
                        moving: player.moving,
                        sprinting: player.sprinting,
                        motionSequence: player.motionSequence,
                        appearance: player.appearance
                    )
                }
        remoteSequence &+= 1
        let message = RemoteUpdateMessage(
            version: 1,
            sequence: remoteSequence,
            worldID: worldID == "settings" ? nil : worldID,
            players: players
        )
        guard let data = try? JSONEncoder().encode(message),
              engine.applyRemoteUpdate(data) != 0 else { return }
        remoteRosterDirty = false
    }

    private func persistBlockedPlayerIDs() {
        UserDefaults.standard.set(blockedPlayerIDs.sorted(), forKey: blockedPlayerIDsKey)
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

    func dismissAuthenticationNotice() {
        authenticationNotice = nil
    }

    private func defaultPlayerLabel(_ playerID: String) -> String {
        let platform = playerID.hasPrefix("ios-") ? "iOS" : playerID.hasPrefix("web-") ? "Web" : "Player"
        return "\(platform) Player \(String(playerID.suffix(4)).uppercased())"
    }

}

struct PresenceNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let joined: Bool
}

struct ModerationNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct RemotePlayerSummary: Identifiable, Equatable {
    let id: String
    let username: String
}

enum ReportReason: String, CaseIterable, Identifiable {
    case inappropriateName = "inappropriate_name"
    case harassment
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inappropriateName: return "Inappropriate name"
        case .harassment: return "Harassment or abuse"
        case .other: return "Other safety concern"
        }
    }
}
