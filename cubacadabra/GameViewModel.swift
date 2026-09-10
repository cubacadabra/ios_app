import Foundation
import Combine
import SwiftUI
import OSLog
import UIKit

let gameLog = Logger(subsystem: "com.cubacadabra.app", category: "game")

@MainActor
final class GameViewModel: ObservableObject {
    @Published var package: GamePackage?
    @Published var worldID = "lobby"
    @Published var frame: EngineFrame?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var connectionState = WorldConnectionState.disconnected
    @Published var presenceNotice: PresenceNotice?
    @Published var username = ""
    @Published var usernameStatus = "Choose a name other players can find you by."
    var accountSession = AppGameSession()
    var serverAppearance: WorldAppearance?
    var onAccountRequested: (() -> Void)?
    var onSessionRejected: ((UInt32) -> Void)?
    @Published var settingsRoomState: UInt8 = 0
    @Published var usernameEditorOpen = false
    @Published var safetyRequestID = 0
    @Published var remotePlayerNames: [String: String] = [:]
    @Published var blockedPlayerIDs: Set<String>
    @Published var moderationNotice: ModerationNotice?
    @Published var gameExitRequestID = 0
    @Published var buildPrompt = ""
    @Published var buildPhase = "build"
    @Published var buildBlockCount = 0
    @Published var buildBlocks: [WorldBuildBlock] = []
    @Published var lobbyLaunchStartsAt: Date?
    var lobbyLaunchClockOffset: TimeInterval = 0
    @Published var buildTool = "place"
    @Published var buildShape = "cube"
    @Published var buildColor = "coral"
    @Published var buildActionNotice: String?
    @Published var hasEnteredGame = false
    @Published var selectedGameID = "first-game"
    @Published var selectedGame = GameCatalogEntry.available[0]
    @Published var isSelectingGame = false
    @Published var sprinting = false
    @Published var climbing = false

    let loader = GamePackageLoader()
    let gameAudio = GameAudio()
    var engine: EngineBridge?
    var lastTick: Date?
    var runtimeWorldIDs: [String] = []
    var lobbyEnabled = true
    var forward: Float = 0
    var strafe: Float = 0
    var jumpQueued = false
    var lookX: Float = 0
    var lookY: Float = 0
    var zoomDelta: Float = 0
    var noticeTask: Task<Void, Never>?
    var moderationNoticeTask: Task<Void, Never>?
    var buildActionNoticeTask: Task<Void, Never>?
    var gamePaused = false
    var gameLoadGeneration: UInt64 = 0

    init() {
        blockedPlayerIDs = []
    }

    lazy var worldSocket = WorldSocketClient(
        onStateChange: { [weak self] state in
            guard let self else { return }
            let previous = self.connectionState
            self.connectionState = state
            if state == .connected, previous != .connected {
                self.engine?.transportConnected()
            } else if previous == .connected, state != .connected {
                self.engine?.transportDisconnected()
            }
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
        },
        onRawMessage: { [weak self] data in
            self?.engine?.receiveTransportMessage(data)
        },
        onGameMessage: { _ in }
    )

    func load() async {
        guard engine == nil else {
            connectWorld(worldID)
            return
        }
        gameLoadGeneration &+= 1
        let generation = gameLoadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let firstGame = GameCatalogEntry.available[0]
            let loaded = try await loader.load(gameID: firstGame.id, packageBaseURL: firstGame.packageBaseURL)
            guard generation == gameLoadGeneration, !Task.isCancelled else { return }
            let loadedPackage = loaded.package
            guard loadedPackage.worldDefinition(named: loadedPackage.initialWorld) != nil else {
                throw GamePackageError.missingWorld(loadedPackage.initialWorld)
            }
            let loadedEngine = try makeEngine(from: loaded)
            gameAudio.configure(with: loaded.audioAssets)
            runtimeWorldIDs = loadedPackage.runtimeWorldEntries().map(\.id)
            worldSocket.setWorldConfigs(Dictionary(uniqueKeysWithValues: loadedPackage.runtimeWorldEntries().map { ($0.id, $0.definition.server) }.compactMap { id, server in server.map { (id, $0) } }))
            package = loadedPackage
            selectedGameID = firstGame.id
            selectedGame = firstGame
            username = worldSocket.username
            loadedEngine.setUsername(accountSession.username ?? username)
            engine = loadedEngine
            let initialFrame = loadedEngine.frame()
            worldID = runtimeWorldIDs[safe: initialFrame.activeWorldIndex] ?? loadedPackage.initialWorld
            lobbyEnabled = loadedPackage.lobbyEnabled && worldID == "lobby"
            worldSocket.setHidden(worldID == "settings")
            frame = initialFrame
            lastTick = nil
            isLoading = false
            Task { [weak self] in
                await self?.loader.refreshPackage(gameID: "first-game")
            }
        } catch {
            guard generation == gameLoadGeneration, !Task.isCancelled else { return }
            gameLog.error("Game load failed: \(error.localizedDescription, privacy: .public)")
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func retry() {
        worldSocket.disconnect()
        engine = nil
        gameAudio.configure(with: [:])
        package = nil
        frame = nil
        hasEnteredGame = false
        Task { await load() }
    }

    func tick(at date: Date) {
        guard let engine, frame != nil, !gamePaused else { return }
        guard let lastTick else {
            self.lastTick = date
            return
        }
        let delta = Float(min(max(date.timeIntervalSince(lastTick), 0), 0.05))
        self.lastTick = date
        dispatchClientActions()
        engine.setInput(
            forward: usernameEditorOpen ? 0 : forward,
            strafe: usernameEditorOpen ? 0 : strafe,
            sprint: usernameEditorOpen ? false : sprinting,
            jump: usernameEditorOpen ? false : jumpQueued,
            climb: usernameEditorOpen ? false : climbing,
            lookX: usernameEditorOpen ? 0 : lookX,
            lookY: usernameEditorOpen ? 0 : lookY,
            zoomDelta: usernameEditorOpen ? 0 : zoomDelta
        )
        jumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        engine.step(delta)
        dispatchClientActions()
        flushAudioMessages()
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
                sprinting: nextFrame.player.sprinting,
                respawnEventID: nextFrame.playerRespawnEventID
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
            case "player.climb" where event.phase == "activate":
                climbing.toggle()
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

    func selectGame(_ game: GameCatalogEntry) async throws {
        guard game.packageBaseURL != nil || GameCatalogEntry.available.contains(where: { $0.id == game.id }) else {
            throw GamePackageError.invalidGameID
        }
        guard selectedGame.catalogID != game.catalogID || package == nil else { return }

        gameLoadGeneration &+= 1
        let generation = gameLoadGeneration
        isLoading = false
        isSelectingGame = true
        defer { if generation == gameLoadGeneration { isSelectingGame = false } }

        let loaded = try await loader.load(gameID: game.id, packageBaseURL: game.packageBaseURL)
        guard generation == gameLoadGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        let nextEngine = try makeEngine(from: loaded)
        let nextPackage = loaded.package

        worldSocket.disconnect()
        worldSocket.setGameID(game.id)
        remotePlayerNames.removeAll()
        gameAudio.configure(with: loaded.audioAssets)
        engine = nextEngine
        package = nextPackage
        errorMessage = nil
        selectedGameID = game.id
        selectedGame = game
        runtimeWorldIDs = nextPackage.runtimeWorldEntries().map(\.id)
        worldSocket.setWorldConfigs(Dictionary(uniqueKeysWithValues: nextPackage.runtimeWorldEntries().map { ($0.id, $0.definition.server) }.compactMap { id, server in server.map { (id, $0) } }))
        frame = nextEngine.frame()
        worldID = runtimeWorldIDs[safe: frame?.activeWorldIndex ?? -1] ?? nextPackage.initialWorld
        lobbyEnabled = nextPackage.lobbyEnabled && worldID == "lobby"
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

    func disconnect() {
        engine?.transportDisconnected()
        worldSocket.disconnect()
    }

    func enterGame() {
        guard engine != nil else { return }
        hasEnteredGame = true
        gamePaused = false
        lastTick = nil
        engine?.requestTransport()
        connectWorld(worldID)
    }

    func pauseGame() {
        gamePaused = true
        gameAudio.stopAll()
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

    internal func dispatchClientActions() {
        guard let engine else { return }
        engine.setIgnoredPlayerIDs(blockedPlayerIDs)
        for action in engine.pollClientActions() {
            switch action {
            case .setWorld(let worldID):
                worldSocket.connect(worldID: worldID)
            case .sendText(let source):
                worldSocket.sendRawText(source)
            }
        }
    }

    private func flushAudioMessages() {
        guard let engine else { return }
        while let data = engine.pollAudioMessage() {
            do {
                let command = try JSONDecoder().decode(EngineAudioCommand.self, from: data)
                gameAudio.play(command)
            } catch {
                gameLog.error("Discarding malformed Rust audio command: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeEngine(from loaded: LoadedGamePackage) throws -> EngineBridge {
        let loadedEngine = try EngineBridge(manifest: loaded.manifest, script: loaded.script)
        let imageAtlas = try GameImageAtlasBuilder.make(from: loaded.imageAssets)
        NSLog(
            "Cubacadabra image atlas: imageCount=%ld atlas=%@",
            loaded.imageAssets.count,
            imageAtlas.map { "\($0.width)x\($0.height)" } ?? "<none>"
        )
        loadedEngine.setPackageImageAtlas(imageAtlas)
        loadedEngine.setIgnoredPlayerIDs(blockedPlayerIDs)
        loadedEngine.setAuthenticated(accountSession.accountID != nil)
        applyAccountAppearance(to: loadedEngine)
        loadedEngine.setUsername(accountSession.username ?? username)
        gameLog.info("Rust package and script loaded; UI nodes: \(loadedEngine.uiNodeCount, privacy: .public)")
        return loadedEngine
    }

    private func updateSettingsRoomState(_ roomState: UInt8) {
        settingsRoomState = roomState
        if roomState == 0 { usernameEditorOpen = false }
    }

}
