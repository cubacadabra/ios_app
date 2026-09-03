import Foundation
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var model = GameViewModel()
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if model.isLoading {
                LoadingView()
            } else if let message = model.errorMessage {
                ErrorView(message: message, retry: model.retry)
            } else {
                GameSurface(model: model)
            }
        }
        .task { await model.load() }
        .onReceive(tick) { date in model.tick(at: date) }
        .onDisappear { model.disconnect() }
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
    @Published private(set) var settingsRoomState: UInt8 = 0
    @Published private(set) var usernameEditorOpen = false
    @Published private(set) var remotePlayerNames: [String: String] = [:]
    @Published private(set) var blockedPlayerIDs: Set<String>
    @Published private(set) var moderationNotice: ModerationNotice?
    @Published var safetyCenterOpen = false
    @Published var sprinting = false

    private let loader = GamePackageLoader()
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
    private var lastMagnification: CGFloat = 1
    private var noticeTask: Task<Void, Never>?
    private var moderationNoticeTask: Task<Void, Never>?
    private var remotePlayers: [String: EngineRemotePlayer] = [:]
    private var connectedWorldID: String?

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
        onMove: { [weak self] event in
            self?.handleMovementEvent(event)
        },
        onUsername: { [weak self] event in
            self?.handleUsernameEvent(event)
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
            connectWorld(worldID)
            Task { [weak self] in
                await loader.refreshManifest()
                await self?.refreshBlockedPlayers()
            }
        } catch {
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
        Task { await load() }
    }

    func tick(at date: Date) {
        guard let engine, frame != nil else { return }
        guard let lastTick else {
            self.lastTick = date
            return
        }
        let delta = Float(min(max(date.timeIntervalSince(lastTick), 0), 0.05))
        self.lastTick = date
        engine.setRemotePlayers(worldID == "settings"
            ? []
            : remotePlayers.keys.sorted().compactMap { remotePlayers[$0] })
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

    func zoomChanged(to magnification: CGFloat) {
        guard !usernameEditorOpen else { return }
        let change = magnification - lastMagnification
        zoomDelta -= Float(change * 8)
        lastMagnification = magnification
    }

    func zoomEnded() { lastMagnification = 1 }

    func toggleSprinting() {
        guard !usernameEditorOpen else { return }
        sprinting.toggle()
    }

    func world() -> WorldDefinition? {
        package?.worldDefinition(named: worldID)
    }

    var renderEngine: EngineBridge? { engine }

    func requestUsernameEdit() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        usernameStatus = "Choose a unique name using 2–24 characters."
        usernameEditorOpen = true
        forward = 0
        strafe = 0
        jumpQueued = false
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
        remotePlayers.removeValue(forKey: player.id)
        remotePlayerNames.removeValue(forKey: player.id)
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
        ModerationService(playerID: worldSocket.playerID)
    }

    private func refreshBlockedPlayers() async {
        guard let serverIDs = try? await moderationService.fetchBlockedPlayerIDs() else { return }
        blockedPlayerIDs.formUnion(serverIDs)
        persistBlockedPlayerIDs()
        remotePlayers = remotePlayers.filter { !blockedPlayerIDs.contains($0.key) }
        remotePlayerNames = remotePlayerNames.filter { !blockedPlayerIDs.contains($0.key) }
    }

    private func handlePresenceEvent(_ event: WorldPresenceEvent) {
        guard !blockedPlayerIDs.contains(event.playerID) else { return }
        if event.type == "player_leave" {
            remotePlayers.removeValue(forKey: event.playerID)
            remotePlayerNames.removeValue(forKey: event.playerID)
        } else if event.type == "player_join" || event.type == "player_name" {
            remotePlayerNames[event.playerID] = event.username ?? defaultPlayerLabel(event.playerID)
        }
        showPresenceEvent(event)
    }

    private func handleMovementEvent(_ event: WorldMovementEvent) {
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
            default: "That name could not be saved. Try again."
            }
        }
    }

    private func updateSettingsRoomState(_ roomState: UInt8) {
        settingsRoomState = roomState
        if roomState == 0 { usernameEditorOpen = false }
    }

    private func connectWorld(_ visualWorldID: String) {
        let networkWorldID = visualWorldID == "settings" ? "lobby" : visualWorldID
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

struct RemotePlayerSummary: Identifiable, Hashable {
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

struct GameSurface: View {
    @ObservedObject var model: GameViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let engine = model.renderEngine {
                RustGameSurface(engine: engine, isActive: true)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in model.lookChanged(to: value.translation) }
                            .onEnded { _ in model.lookEnded() }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in model.zoomChanged(to: value) }
                            .onEnded { _ in model.zoomEnded() }
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded { model.requestUsernameEdit() }
                    )
            }
            if model.worldID != "settings" {
                GameAtmosphere(isSession: model.worldID != "lobby")
            }
            VStack(alignment: .leading, spacing: 0) {
                if model.worldID != "settings" {
                    GameHeader(model: model)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    if let notice = model.presenceNotice {
                        PresenceNoticeView(notice: notice)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let notice = model.moderationNotice {
                        ModerationNoticeView(notice: notice) {
                            model.dismissModerationNotice()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
                GameControls(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.easeOut(duration: 0.22), value: model.presenceNotice)
            if model.usernameEditorOpen {
                UsernameEditorView(model: model)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .background(Color.black)
        .sheet(isPresented: $model.safetyCenterOpen) {
            SafetyCenterView(model: model)
        }
    }
}

private struct UsernameEditorView: View {
    @ObservedObject var model: GameViewModel
    @State private var draftUsername = ""
    @FocusState private var usernameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 15) {
                Text("PLAYER IDENTITY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text("Edit username")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                TextField("Player name", text: $draftUsername)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($usernameFocused)
                    .onSubmit { model.saveUsername(draftUsername) }
                Text(model.usernameStatus)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("CANCEL") { model.cancelUsernameEdit() }
                    Spacer()
                    Button("SAVE NAME") { model.saveUsername(draftUsername) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(maxWidth: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.primary.opacity(0.12), lineWidth: 1))
            .shadow(radius: 24)
            .padding(18)
        }
        .onAppear {
            draftUsername = model.username
            usernameFocused = true
        }
    }
}

private struct GameAtmosphere: View {
    let isSession: Bool

    private var topTint: Color {
        isSession
            ? Color(red: 8 / 255, green: 24 / 255, blue: 36 / 255)
            : Color(red: 15 / 255, green: 53 / 255, blue: 63 / 255)
    }

    private var bottomTint: Color {
        isSession
            ? Color(red: 5 / 255, green: 24 / 255, blue: 29 / 255)
            : Color(red: 14 / 255, green: 39 / 255, blue: 40 / 255)
    }

    private var vignetteTint: Color {
        isSession
            ? Color(red: 8 / 255, green: 27 / 255, blue: 35 / 255)
            : Color(red: 32 / 255, green: 57 / 255, blue: 55 / 255)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        topTint.opacity(isSession ? 0.32 : 0.18),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: isSession ? 0.24 : 0.20)
                )
                LinearGradient(
                    colors: [
                        bottomTint.opacity(isSession ? 0.30 : 0.22),
                        .clear,
                    ],
                    startPoint: .bottom,
                    endPoint: UnitPoint(x: 0.5, y: isSession ? 0.34 : 0.30)
                )
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.23),
                        .init(
                            color: vignetteTint.opacity(isSession ? 0.18 : 0.10),
                            location: 1
                        ),
                    ],
                    center: UnitPoint(x: 0.53, y: 0.39),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
            }
            .compositingGroup()
            .blendMode(.multiply)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct GameHeader: View {
    @ObservedObject var model: GameViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.world()?.scene.eyebrow.uppercased() ?? "CUBACADABRA")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.64))
                    Text(model.world()?.scene.title ?? "First Game")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(model.world()?.scene.description ?? "")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        model.safetyCenterOpen = true
                    } label: {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .accessibilityLabel("Players and safety")
                    Text(model.worldID == "lobby" ? "LOBBY" : "SESSION")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.64))
                    Text("\((model.frame?.agents.count ?? 0) + 1) PLAYERS")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 7, height: 7)
                        Text(model.connectionState.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Cloud connection \(model.connectionState.label.lowercased())")
                }
            }
            if model.worldID == "lobby" {
                HStack(spacing: 8) {
                    ForEach(Array((model.world()?.launchPads ?? []).enumerated()), id: \.element.id) { index, pad in
                        let live = model.frame?.pads[safe: index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pad.code)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(0.8)
                            Text(status(for: live))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func status(for pad: EnginePad?) -> String {
        guard let pad else { return "WAITING" }
        if pad.phase == 2 { return "LAUNCHING" }
        if pad.seconds > 0 { return String(format: "%.1fs · %d", pad.seconds, pad.occupants) }
        return pad.occupants == 0 ? "WAITING" : "ASSEMBLING"
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return Color(red: 0.39, green: 0.68, blue: 0.45)
        case .connecting, .reconnecting: return Color(red: 0.88, green: 0.72, blue: 0.29)
        case .disconnected: return Color(red: 0.76, green: 0.37, blue: 0.34)
        }
    }
}

private struct PresenceNoticeView: View {
    let notice: PresenceNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.joined ? "person.badge.plus" : "person.badge.minus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.joined ? Color.green : Color.orange)
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 390)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(notice.message)
    }
}

private struct ModerationNoticeView: View {
    let notice: ModerationNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss safety message")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct SafetyCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: GameViewModel
    @State private var reportTarget: RemotePlayerSummary?
    @State private var blockTarget: RemotePlayerSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Use Players & Safety to report a concern, block another player, or manage people you have blocked. Reports are reviewed by the Cubacadabra team.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Community safety")
                }

                Section("Players here") {
                    if model.activeRemotePlayers.isEmpty {
                        Text("No other players are visible right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.activeRemotePlayers) { player in
                            PlayerSafetyRow(player: player) {
                                reportTarget = player
                            } block: {
                                blockTarget = player
                            }
                        }
                    }
                }

                Section("Blocked on this device") {
                    if model.blockedPlayerIDs.isEmpty {
                        Text("No blocked players.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.blockedPlayerIDs.sorted(), id: \.self) { playerID in
                            HStack(spacing: 12) {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                Text("Player \(String(playerID.suffix(4)).uppercased())")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                Spacer()
                                Button("Unblock") {
                                    model.unblockPlayer(playerID)
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                Section("Legal and support") {
                    Link(destination: AppLinks.privacy) {
                        Label("Privacy Policy", systemImage: "lock.shield.fill")
                    }
                    Link(destination: AppLinks.terms) {
                        Label("Terms of Use", systemImage: "doc.text.fill")
                    }
                    Link(destination: AppLinks.support) {
                        Label("Contact support", systemImage: "envelope.fill")
                    }
                }
            }
            .navigationTitle("Players & Safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } }
            )
        ) {
            if let player = reportTarget {
                ReportPlayerView(player: player) { reason, details in
                    model.reportPlayer(player, reason: reason, details: details)
                }
            }
        }
        .confirmationDialog(
            "Block \(blockTarget?.username ?? "this player")?",
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let blockTarget {
                    model.blockPlayer(blockTarget)
                }
                blockTarget = nil
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: {
            Text("You will no longer see this player or their presence. You can unblock them later.")
        }
    }
}

private struct PlayerSafetyRow: View {
    let player: RemotePlayerSummary
    let report: () -> Void
    let block: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.username)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text("In this world")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Report player", systemImage: "exclamationmark.bubble") { report() }
                Button("Block player", systemImage: "hand.raised.fill", role: .destructive) { block() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(player.username)")
        }
        .frame(minHeight: 52)
    }
}

private struct ReportPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let player: RemotePlayerSummary
    let report: (ReportReason, String) -> Void
    @State private var reason: ReportReason = .inappropriateName
    @State private var details = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Report \(player.username)")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text("Tell us what happened. Do not include private information.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                }

                Section("Details (optional)") {
                    TextEditor(text: $details)
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if details.isEmpty {
                                Text("What should we review?")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Button("Send Report") {
                        report(reason, details)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Report Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct GameControls: View {
    @ObservedObject var model: GameViewModel
    @State private var joystick = CGSize.zero

    var body: some View {
        HStack(alignment: .bottom) {
            ZStack {
                Circle().fill(.black.opacity(0.3)).frame(width: 108, height: 108)
                    .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 1))
                Circle().fill(.white.opacity(0.84)).frame(width: 48, height: 48)
                    .offset(x: joystick.width, y: joystick.height)
            }
            .frame(width: 120, height: 120)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                joystick = value.translation
                let limit: CGFloat = 38
                model.setMove(
                    strafe: Float(max(-limit, min(limit, value.translation.width)) / limit),
                    forward: Float(-max(-limit, min(limit, value.translation.height)) / limit)
                )
            }.onEnded { _ in
                joystick = .zero
                model.setMove(strafe: 0, forward: 0)
            })
            .accessibilityLabel("Movement joystick")
            Spacer()
            VStack(spacing: 10) {
                Button("JUMP") { model.jump() }.buttonStyle(GameButtonStyle())
                Button(model.sprinting ? "RUNNING" : "RUN") { model.toggleSprinting() }
                    .buttonStyle(GameButtonStyle(active: model.sprinting))
            }
        }
    }
}

struct GameButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.white)
            .frame(minWidth: 86, minHeight: 44)
            .background(.white.opacity(active ? 0.42 : 0.2), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.18, blue: 0.21).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("LOADING FIRST GAME")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.18, blue: 0.21).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("GAME UNAVAILABLE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.62))
                Text("Couldn’t load the first game.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Button("TRY AGAIN", action: retry).buttonStyle(GameButtonStyle())
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(28)
        }
    }
}

#Preview {
    ContentView()
}
