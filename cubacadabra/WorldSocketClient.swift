import Foundation

enum WorldConnectionState: Equatable {
    case connecting
    case connected
    case reconnecting
    case disconnected

    var label: String {
        switch self {
        case .connecting: return "CONNECTING"
        case .connected: return "CLOUD LIVE"
        case .reconnecting: return "RECONNECTING"
        case .disconnected: return "OFFLINE"
        }
    }
}

struct WorldPresenceEvent {
    let type: String
    let playerID: String
}

struct WorldMovementEvent {
    let playerID: String
    let position: SIMD3<Float>
    let yaw: Float
    let moving: Bool
    let sprinting: Bool
}

@MainActor
final class WorldSocketClient {
    let playerID: String

    private let baseURL = URL(string: "wss://cubacadabra.andrew-f97.workers.dev")!
    private let onStateChange: (WorldConnectionState) -> Void
    private let onEvent: (WorldPresenceEvent) -> Void
    private let onMove: (WorldMovementEvent) -> Void
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var worldID: String?
    private var generation = 0
    private var reconnectAttempt = 0
    private var stopped = true
    private var lastMoveSentAt = Date.distantPast.timeIntervalSinceReferenceDate

    init(
        onStateChange: @escaping (WorldConnectionState) -> Void,
        onEvent: @escaping (WorldPresenceEvent) -> Void,
        onMove: @escaping (WorldMovementEvent) -> Void
    ) {
        playerID = Self.loadPlayerID()
        self.onStateChange = onStateChange
        self.onEvent = onEvent
        self.onMove = onMove
    }

    func connect(worldID nextWorldID: String) {
        let normalizedWorldID = nextWorldID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorldID.isEmpty else { return }
        if normalizedWorldID == worldID, socketTask != nil { return }

        generation += 1
        closeCurrentSocket()
        worldID = normalizedWorldID
        reconnectAttempt = 0
        lastMoveSentAt = Date.distantPast.timeIntervalSinceReferenceDate
        stopped = false
        openSocket(generation: generation)
    }

    func disconnect() {
        guard !stopped || socketTask != nil else { return }
        stopped = true
        generation += 1
        worldID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        closeCurrentSocket()
        onStateChange(.disconnected)
    }

    private func openSocket(generation expectedGeneration: Int) {
        guard !stopped,
              expectedGeneration == generation,
              let worldID else { return }

        onStateChange(reconnectAttempt > 0 ? .reconnecting : .connecting)

        let worldURL = baseURL
            .appendingPathComponent("world", isDirectory: true)
            .appendingPathComponent(worldID)
        guard var components = URLComponents(url: worldURL, resolvingAgainstBaseURL: false) else {
            scheduleReconnect(generation: expectedGeneration)
            return
        }
        components.queryItems = [URLQueryItem(name: "player_id", value: playerID)]
        guard let url = components.url else {
            scheduleReconnect(generation: expectedGeneration)
            return
        }

        let nextSocket = URLSession.shared.webSocketTask(with: url)
        socketTask = nextSocket
        nextSocket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: nextSocket, generation: expectedGeneration)
        }
    }

    private func receiveMessages(
        from task: URLSessionWebSocketTask,
        generation expectedGeneration: Int
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                guard isCurrent(task, generation: expectedGeneration) else { return }
                reconnectAttempt = 0
                onStateChange(.connected)
                handle(message)
            }
        } catch {
            guard !Task.isCancelled,
                  isCurrent(task, generation: expectedGeneration) else { return }
            socketTask = nil
            scheduleReconnect(generation: expectedGeneration)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let encoded = text.data(using: .utf8) else { return }
            data = encoded
        case .data(let receivedData):
            data = receivedData
        @unknown default:
            return
        }

        guard let event = try? JSONDecoder().decode(WorldEventEnvelope.self, from: data) else { return }
        if event.type == "move" {
            guard let eventPlayerID = event.id,
                  eventPlayerID != playerID,
                  let x = event.x,
                  let y = event.y,
                  let z = event.z,
                  let yaw = event.yaw else { return }
            onMove(WorldMovementEvent(
                playerID: eventPlayerID,
                position: SIMD3(x, y, z),
                yaw: yaw,
                moving: event.moving ?? false,
                sprinting: event.sprinting ?? false
            ))
            return
        }
        guard event.type == "player_join" || event.type == "player_leave",
              let eventPlayerID = event.id,
              eventPlayerID != playerID else { return }
        onEvent(WorldPresenceEvent(type: event.type, playerID: eventPlayerID))
    }

    func sendMove(
        position: SIMD3<Float>,
        yaw: Float,
        moving: Bool,
        sprinting: Bool
    ) {
        guard !stopped,
              let socketTask,
              socketTask.state == .running else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastMoveSentAt >= 0.05 else { return }
        let message = WorldMoveMessage(
            x: position.x,
            y: position.y,
            z: position.z,
            yaw: yaw,
            moving: moving,
            sprinting: sprinting
        )
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        socketTask.send(.string(text)) { _ in }
        lastMoveSentAt = now
    }

    private func scheduleReconnect(generation expectedGeneration: Int) {
        guard !stopped, expectedGeneration == generation else { return }
        reconnectAttempt += 1
        onStateChange(.reconnecting)
        let exponent = min(reconnectAttempt - 1, 4)
        let delay = min(0.75 * pow(2.0, Double(exponent)), 8.0)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openSocket(generation: expectedGeneration)
        }
    }

    private func isCurrent(_ task: URLSessionWebSocketTask, generation expectedGeneration: Int) -> Bool {
        socketTask === task && expectedGeneration == generation && !stopped
    }

    private func closeCurrentSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    private static func loadPlayerID() -> String {
        let key = "cubacadabra.player-id"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }

        let playerID = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(playerID, forKey: key)
        return playerID
    }
}

private struct WorldEventEnvelope: Decodable {
    let type: String
    let id: String?
    let x: Float?
    let y: Float?
    let z: Float?
    let yaw: Float?
    let moving: Bool?
    let sprinting: Bool?
}

private struct WorldMoveMessage: Encodable {
    let type = "move"
    let x: Float
    let y: Float
    let z: Float
    let yaw: Float
    let moving: Bool
    let sprinting: Bool
}
