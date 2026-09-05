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
    @Published private(set) var settingsRoomState: UInt8 = 0
    @Published private(set) var usernameEditorOpen = false
    @Published private(set) var safetyRequestID = 0
    @Published private(set) var remotePlayerNames: [String: String] = [:]
    @Published private(set) var blockedPlayerIDs: Set<String>
    @Published private(set) var moderationNotice: ModerationNotice?
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
    @Published var sprinting = false

    private let loader = GamePackageLoader()
    private let authentication = AppAuthenticationService()
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
    private var lastLookTranslation = CGSize.zero
    private var noticeTask: Task<Void, Never>?
    private var moderationNoticeTask: Task<Void, Never>?
    private var buildActionNoticeTask: Task<Void, Never>?
    private var remotePlayers: [String: EngineRemotePlayer] = [:]
    private var connectedWorldID: String?
    private var pendingSessionWorldID: String?
    private var gamePaused = false

    init() {
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
            let loaded = try await loader.load()
            let loadedPackage = loaded.package
            guard loadedPackage.worldDefinition(named: loadedPackage.startWorld) != nil else {
                throw GamePackageError.missingWorld(loadedPackage.startWorld)
            }
            let loadedEngine = try EngineBridge()
            try loadedEngine.loadPackage(loaded.manifest)
            try loadedEngine.loadScript(loaded.script)
            gameLog.info("Rust package and script loaded; UI nodes: \(loadedEngine.uiNodeCount, privacy: .public)")
            runtimeWorldIDs = loadedPackage.runtimeWorldEntries().map(\.id)
            package = loadedPackage
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
                await loader.refreshPackage()
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

    func tick(at date: Date) {
        guard let engine, frame != nil, !gamePaused else { return }
        guard let lastTick else {
            self.lastTick = date
            return
        }
        let delta = Float(min(max(date.timeIntervalSince(lastTick), 0), 0.05))
        self.lastTick = date
        let visibleRemotePlayerIDs = remotePlayers.keys
            .filter { !blockedPlayerIDs.contains($0) }
            .sorted()
        engine.setRemotePlayers(worldID == "settings"
            ? []
            : visibleRemotePlayerIDs.compactMap { remotePlayers[$0] })
        engine.setInput(
            forward: usernameEditorOpen ? 0 : forward,
            strafe: usernameEditorOpen ? 0 : strafe,
            sprint: usernameEditorOpen ? false : sprinting,
            jump: usernameEditorOpen ? false : jumpQueued,
            lookX: usernameEditorOpen ? 0 : lookX,
            lookY: usernameEditorOpen ? 0 : lookY,
            zoomDelta: usernameEditorOpen ? 0 : zoomDelta
        )
        jumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        engine.step(delta)
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
            if activeWorldID == "settings" {
                engine.setRemotePlayers([])
            }
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
        lookX += Float(translation.width - lastLookTranslation.width)
        lookY += Float(translation.height - lastLookTranslation.height)
        lastLookTranslation = translation
    }

    func lookEnded() { lastLookTranslation = .zero }

    func zoomChangedBy(delta: CGFloat) {
        guard !usernameEditorOpen else { return }
        zoomDelta -= Float(delta * 8)
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
        guard isAuthenticated else {
            beginSignIn()
            return
        }
        requestUsernameEdit()
    }

    private func requestUsernameEdit() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        usernameStatus = "Choose a unique name using 2–24 characters."
        usernameEditorOpen = true
        forward = 0
        strafe = 0
        jumpQueued = false
    }

    private func beginSignIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        authenticationNotice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await authentication.signIn()
                applyAuthentication(result)
                if settingsRoomState == 2 {
                    requestUsernameEdit()
                }
            } catch let error as AppAuthError where error == .cancelled {
                // The user dismissed the web sign-in sheet.
            } catch {
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
        Task { [weak self] in
            do {
                try await service.reportPlayer(
                    playerID: player.id,
                    username: player.username,
                    reason: reason.rawValue,
                    details: details,
                    worldID: worldID
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
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        } else {
            guard !blockedPlayerIDs.contains(event.playerID) else { return }
        }
        if event.type == "player_join" || event.type == "player_name" {
            remotePlayerNames[event.playerID] = event.username ?? defaultPlayerLabel(event.playerID)
        }
        showPresenceEvent(event)
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
    }

    private func applyAuthentication(_ result: AppAuthResult) {
        isAuthenticated = true
        authUser = result.user
        authenticationNotice = nil
        worldSocket.setAccessToken(result.accessToken)
        if let serverUsername = result.user.username, !serverUsername.isEmpty {
            worldSocket.adoptUsername(serverUsername)
            username = serverUsername
            engine?.setUsername(serverUsername)
        }
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
        remotePlayers[event.playerID] = EngineRemotePlayer(
            position: event.position,
            yaw: event.yaw,
            moving: event.moving,
            sprinting: event.sprinting
        )
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
        engine?.setRemotePlayers([])
        worldSocket.connect(worldID: networkWorldID)
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
