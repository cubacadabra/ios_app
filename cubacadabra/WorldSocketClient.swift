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
    let username: String?
}

struct WorldUsernameEvent {
    let type: String
    let username: String?
    let code: String?
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
    fileprivate static let moveSendInterval: TimeInterval = 1.0 / 12.0
    fileprivate static let movePositionEpsilon: Float = 0.01
    fileprivate static let moveYawEpsilon: Float = 0.01

    let playerID: String
    private(set) var username: String

    private let baseURL = ClientConfiguration.backendURL
    private let onStateChange: (WorldConnectionState) -> Void
    private let onEvent: (WorldPresenceEvent) -> Void
    private let onMove: (WorldMovementEvent) -> Void
    private let onUsername: (WorldUsernameEvent) -> Void
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var worldID: String?
    private var generation = 0
    private var reconnectAttempt = 0
    private var stopped = true
    private var lastMoveSentAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastSentMove: SentMove?
    private var pendingUsername: String
    private var hidden = false

    init(
        onStateChange: @escaping (WorldConnectionState) -> Void,
        onEvent: @escaping (WorldPresenceEvent) -> Void,
        onMove: @escaping (WorldMovementEvent) -> Void,
        onUsername: @escaping (WorldUsernameEvent) -> Void
    ) {
        playerID = Self.loadPlayerID()
        username = Self.loadUsername(for: playerID)
        pendingUsername = username
        self.onStateChange = onStateChange
        self.onEvent = onEvent
        self.onMove = onMove
        self.onUsername = onUsername
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
        lastSentMove = nil
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
        lastMoveSentAt = Date.distantPast.timeIntervalSinceReferenceDate
        lastSentMove = nil
        nextSocket.resume()
        sendUsername(pendingUsername, on: nextSocket)
        sendVisibility(on: nextSocket)
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
        if event.type == "username_updated" || event.type == "username_error" {
            if event.type == "username_updated", let nextUsername = event.username {
                username = nextUsername
                pendingUsername = nextUsername
                UserDefaults.standard.set(nextUsername, forKey: "cubacadabra.username")
            } else if event.type == "username_error" {
                pendingUsername = username
            }
            onUsername(WorldUsernameEvent(type: event.type, username: event.username, code: event.code))
            return
        }
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
        guard event.type == "player_join" || event.type == "player_leave" || event.type == "player_name",
              let eventPlayerID = event.id,
              eventPlayerID != playerID else { return }
        onEvent(WorldPresenceEvent(type: event.type, playerID: eventPlayerID, username: event.username))
    }

    func setUsername(_ nextUsername: String) {
        let trimmed = nextUsername
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard trimmed.count >= 2, trimmed.count <= 24 else {
            onUsername(WorldUsernameEvent(type: "username_error", username: nil, code: "invalid_username"))
            return
        }
        guard trimmed.range(of: "^[A-Za-z0-9 _-]+$", options: .regularExpression) != nil else {
            onUsername(WorldUsernameEvent(type: "username_error", username: nil, code: "invalid_username"))
            return
        }
        pendingUsername = trimmed
        sendUsername(trimmed, on: socketTask)
    }

    private func sendUsername(_ value: String, on task: URLSessionWebSocketTask?) {
        guard !stopped, let task, task.state == .running else { return }
        let message = WorldUsernameMessage(username: value)
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func setHidden(_ nextHidden: Bool) {
        guard hidden != nextHidden else { return }
        hidden = nextHidden
        sendVisibility(on: socketTask)
    }

    private func sendVisibility(on task: URLSessionWebSocketTask?) {
        guard !stopped, let task, task.state == .running else { return }
        let message = WorldVisibilityMessage(hidden: hidden)
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
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

        let move = SentMove(
            position: position,
            yaw: yaw,
            moving: moving,
            sprinting: sprinting
        )
        if let lastSentMove,
           !move.isMeaningfullyDifferent(from: lastSentMove) {
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastMoveSentAt >= Self.moveSendInterval else { return }
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
        lastSentMove = move
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

    private static func loadUsername(for playerID: String) -> String {
        let fallback = "iOS Player \(String(playerID.suffix(4)).uppercased())"
        let key = "cubacadabra.username"
        guard let stored = UserDefaults.standard.string(forKey: key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return stored
    }
}

private struct SentMove {
    let position: SIMD3<Float>
    let yaw: Float
    let moving: Bool
    let sprinting: Bool

    func isMeaningfullyDifferent(from previous: SentMove) -> Bool {
        moving != previous.moving
            || sprinting != previous.sprinting
            || abs(position.x - previous.position.x) > WorldSocketClient.movePositionEpsilon
            || abs(position.y - previous.position.y) > WorldSocketClient.movePositionEpsilon
            || abs(position.z - previous.position.z) > WorldSocketClient.movePositionEpsilon
            || abs(yaw - previous.yaw) > WorldSocketClient.moveYawEpsilon
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
    let username: String?
    let code: String?
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

private struct WorldUsernameMessage: Encodable {
    let type = "set_username"
    let username: String
}

private struct WorldVisibilityMessage: Encodable {
    let type = "set_hidden"
    let hidden: Bool
}
