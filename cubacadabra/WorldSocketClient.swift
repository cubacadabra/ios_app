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

enum ExperienceSendResult: Equatable {
    case sent
    case queued
    case unavailable
    case invalid
}

struct WorldPresenceEvent {
    let type: String
    let playerID: String
    let username: String?
}

struct WorldSessionEvent {
    let playerID: String
    let username: String?
    let hasUsername: Bool
    let loggedIn: Bool
    let authenticated: Bool
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
    let isSelf: Bool
    let corrected: Bool
}

struct WorldExperienceEvent {
    let type: String
    let kind: String?
    let phase: String?
    let prompt: String?
    let sessionWorldID: String?
    let playerIDs: [String]
    let startsAt: Int64?
    let serverNow: Int64?
    let blockCount: Int?
    let blocks: [WorldBuildBlock]
}

struct WorldBuildBlock: Decodable, Identifiable {
    let id: String
    let x: Float
    let y: Float
    let z: Float
    let rotation: Int
    let shape: String
    let color: String
}

@MainActor
final class WorldSocketClient {
    fileprivate static let moveSendInterval: TimeInterval = 1.0 / 12.0
    fileprivate static let movePositionEpsilon: Float = 0.01
    fileprivate static let moveYawEpsilon: Float = 0.01

    let playerID: String
    private(set) var username: String
    private(set) var accessToken: String?

    private let baseURL = ClientConfiguration.backendURL
    private let onStateChange: (WorldConnectionState) -> Void
    private let onEvent: (WorldPresenceEvent) -> Void
    private let onSession: (WorldSessionEvent) -> Void
    private let onMove: (WorldMovementEvent) -> Void
    private let onUsername: (WorldUsernameEvent) -> Void
    private let onExperience: (WorldExperienceEvent) -> Void
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
    private var pendingExperienceMessages: [String] = []

    init(
        onStateChange: @escaping (WorldConnectionState) -> Void,
        onEvent: @escaping (WorldPresenceEvent) -> Void,
        onSession: @escaping (WorldSessionEvent) -> Void,
        onMove: @escaping (WorldMovementEvent) -> Void,
        onUsername: @escaping (WorldUsernameEvent) -> Void,
        onExperience: @escaping (WorldExperienceEvent) -> Void
    ) {
        playerID = Self.loadPlayerID()
        username = Self.loadUsername(for: playerID)
        accessToken = nil
        pendingUsername = username
        self.onStateChange = onStateChange
        self.onEvent = onEvent
        self.onSession = onSession
        self.onMove = onMove
        self.onUsername = onUsername
        self.onExperience = onExperience
    }

    func connect(worldID nextWorldID: String) {
        let normalizedWorldID = nextWorldID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorldID.isEmpty else { return }
        if normalizedWorldID == worldID, socketTask != nil { return }

        generation += 1
        closeCurrentSocket()
        pendingExperienceMessages.removeAll()
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
        pendingExperienceMessages.removeAll()
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

        var request = URLRequest(url: url)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let nextSocket = URLSession.shared.webSocketTask(with: request)
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
                flushPendingExperienceMessages(on: task)
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
        if event.type == "session_identity" {
            guard let eventPlayerID = event.id else { return }
            onSession(WorldSessionEvent(
                playerID: eventPlayerID,
                username: event.username,
                hasUsername: event.hasUsername ?? false,
                loggedIn: event.loggedIn ?? event.authenticated ?? false,
                authenticated: event.authenticated ?? false
            ))
            return
        }
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
                  let x = event.x,
                  let y = event.y,
                  let z = event.z,
                  let yaw = event.yaw else { return }
            onMove(WorldMovementEvent(
                playerID: eventPlayerID,
                position: SIMD3(x, y, z),
                yaw: yaw,
                moving: event.moving ?? false,
                sprinting: event.sprinting ?? false,
                isSelf: eventPlayerID == playerID,
                corrected: event.corrected ?? false
            ))
            return
        }
        if event.type == "experience_state" || event.type == "experience_launch" {
            onExperience(WorldExperienceEvent(
                type: event.type,
                kind: event.kind,
                phase: event.phase,
                prompt: event.prompt,
                sessionWorldID: event.sessionWorldID,
                playerIDs: event.playerIDs ?? [],
                startsAt: event.startsAt ?? event.launch?.startsAt,
                serverNow: event.serverNow,
                blockCount: event.blocks?.count,
                blocks: event.blocks ?? []
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

    func setAccessToken(_ nextAccessToken: String?) {
        guard accessToken != nextAccessToken else { return }
        accessToken = nextAccessToken
        guard worldID != nil else { return }
        reconnect()
    }

    func adoptUsername(_ nextUsername: String) {
        let trimmed = nextUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        username = trimmed
        pendingUsername = trimmed
        UserDefaults.standard.set(trimmed, forKey: "cubacadabra.username")
    }

    func reconnect() {
        guard worldID != nil else { return }
        generation += 1
        closeCurrentSocket()
        reconnectAttempt = 0
        stopped = false
        openSocket(generation: generation)
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

    @discardableResult
    func sendExperience(_ type: String, payload: [String: Any] = [:]) -> ExperienceSendResult {
        var message: [String: Any] = ["type": type]
        payload.forEach { message[$0.key] = $0.value }
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return .invalid }
        guard !stopped, worldID != nil else { return .unavailable }
        guard let socketTask, socketTask.state == .running else {
            enqueueExperienceMessage(text)
            return .queued
        }
        socketTask.send(.string(text)) { [weak self, weak socketTask] error in
            guard error != nil, let self, let socketTask else { return }
            Task { @MainActor in
                guard self.isCurrent(socketTask, generation: self.generation) else { return }
                self.enqueueExperienceMessage(text)
            }
        }
        return .sent
    }

    private func enqueueExperienceMessage(_ text: String) {
        let maximumPendingMessages = 64
        if pendingExperienceMessages.count >= maximumPendingMessages {
            pendingExperienceMessages.removeFirst()
        }
        pendingExperienceMessages.append(text)
    }

    private func flushPendingExperienceMessages(on task: URLSessionWebSocketTask) {
        guard task.state == .running, !pendingExperienceMessages.isEmpty else { return }
        let messages = pendingExperienceMessages
        pendingExperienceMessages.removeAll(keepingCapacity: true)
        for message in messages {
            task.send(.string(message)) { [weak self, weak task] error in
                guard error != nil, let self, let task else { return }
                Task { @MainActor in
                    guard self.isCurrent(task, generation: self.generation) else { return }
                    self.enqueueExperienceMessage(message)
                }
            }
        }
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
    let corrected: Bool?
    let username: String?
    let hasUsername: Bool?
    let loggedIn: Bool?
    let authenticated: Bool?
    let code: String?
    let kind: String?
    let phase: String?
    let prompt: String?
    let sessionWorldID: String?
    let playerIDs: [String]?
    let startsAt: Int64?
    let serverNow: Int64?
    let blocks: [WorldBuildBlock]?
    let launch: WorldLaunchEnvelope?

    enum CodingKeys: String, CodingKey {
        case type, id, x, y, z, yaw, moving, sprinting, corrected, username, hasUsername, loggedIn, authenticated, code, kind, phase, prompt
        case sessionWorldID = "sessionWorldId"
        case playerIDs = "playerIds"
        case startsAt, serverNow, blocks, launch
    }
}

private struct WorldLaunchEnvelope: Decodable {
    let startsAt: Int64?
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
