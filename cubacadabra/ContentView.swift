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
        .preferredColorScheme(.dark)
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
    @Published var sprinting = false

    private let loader = GamePackageLoader()
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
    private var remotePlayers: [String: EngineRemotePlayer] = [:]
    private lazy var worldSocket = WorldSocketClient(
        onStateChange: { [weak self] state in
            self?.connectionState = state
        },
        onEvent: { [weak self] event in
            self?.handlePresenceEvent(event)
        },
        onMove: { [weak self] event in
            self?.handleMovementEvent(event)
        }
    )

    func load() async {
        guard engine == nil else {
            worldSocket.connect(worldID: worldID)
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
            worldID = loadedPackage.startWorld
            engine = loadedEngine
            let initialFrame = loadedEngine.frame()
            frame = initialFrame
            lastTick = nil
            isLoading = false
            worldSocket.connect(worldID: worldID)
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func retry() {
        worldSocket.disconnect()
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
        engine.setRemotePlayers(remotePlayers.keys.sorted().compactMap { remotePlayers[$0] })
        engine.setInput(
            forward: forward,
            strafe: strafe,
            sprint: sprinting,
            jump: jumpQueued,
            lookX: lookX,
            lookY: lookY,
            zoomDelta: zoomDelta
        )
        jumpQueued = false
        lookX = 0
        lookY = 0
        zoomDelta = 0
        engine.step(delta)
        let nextFrame = engine.frame()
        if let activeWorldID = runtimeWorldIDs[safe: nextFrame.activeWorldIndex],
           activeWorldID != worldID {
            worldID = activeWorldID
            forward = 0
            strafe = 0
            sprinting = false
            remotePlayers.removeAll()
            engine.setRemotePlayers([])
            worldSocket.connect(worldID: activeWorldID)
        }
        frame = nextFrame
        worldSocket.sendMove(
            position: nextFrame.player.position,
            yaw: nextFrame.player.yaw,
            moving: nextFrame.player.moving,
            sprinting: nextFrame.player.sprinting
        )
    }

    func setMove(strafe: Float, forward: Float) {
        self.strafe = strafe
        self.forward = forward
    }

    func jump() { jumpQueued = true }

    func lookChanged(to translation: CGSize) {
        lookX += Float(translation.width - lastLookTranslation.width)
        lookY += Float(translation.height - lastLookTranslation.height)
        lastLookTranslation = translation
    }

    func lookEnded() { lastLookTranslation = .zero }

    func zoomChanged(to magnification: CGFloat) {
        let change = magnification - lastMagnification
        zoomDelta -= Float(change * 8)
        lastMagnification = magnification
    }

    func zoomEnded() { lastMagnification = 1 }

    func world() -> WorldDefinition? {
        package?.worldDefinition(named: worldID)
    }

    var renderEngine: EngineBridge? { engine }

    func disconnect() {
        worldSocket.disconnect()
    }

    private func handlePresenceEvent(_ event: WorldPresenceEvent) {
        if event.type == "player_leave" {
            remotePlayers.removeValue(forKey: event.playerID)
        }
        showPresenceEvent(event)
    }

    private func handleMovementEvent(_ event: WorldMovementEvent) {
        remotePlayers[event.playerID] = EngineRemotePlayer(
            position: event.position,
            yaw: event.yaw,
            moving: event.moving,
            sprinting: event.sprinting
        )
    }

    private func showPresenceEvent(_ event: WorldPresenceEvent) {
        let platform: String
        if event.playerID.hasPrefix("ios-") {
            platform = "iOS"
        } else if event.playerID.hasPrefix("web-") {
            platform = "Web"
        } else {
            platform = "Player"
        }
        let shortID = String(event.playerID.suffix(4)).uppercased()
        let action = event.type == "player_join" ? "joined the world" : "left the world"
        let notice = PresenceNotice(
            message: "\(platform) player \(shortID) \(action)",
            joined: event.type == "player_join"
        )
        presenceNotice = notice

        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.presenceNotice?.id == notice.id else { return }
            self?.presenceNotice = nil
        }
    }

}

struct PresenceNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let joined: Bool
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
            }
            GameAtmosphere(isSession: model.worldID != "lobby")
            VStack(alignment: .leading, spacing: 0) {
                GameHeader(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                if let notice = model.presenceNotice {
                    PresenceNoticeView(notice: notice)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                GameControls(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.easeOut(duration: 0.22), value: model.presenceNotice)
        }
        .background(Color.black)
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
                Button(model.sprinting ? "RUNNING" : "RUN") { model.sprinting.toggle() }
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
