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
    let generation: UInt32
    let motionSequence: UInt64
    let appearance: WorldAppearance?
}

struct WorldAppearance: Codable, Equatable {
    let version: UInt16?
    let base: String?
    let parts: [String]?
    let parameters: [String: String]?
    let body: String?
    let face: String?
    let outfit: String?
    let equipment: [String: String]?
    let colors: [String: String]?
    let revision: UInt32?
}

struct WorldSessionEvent {
    let playerID: String
    let username: String?
    let hasUsername: Bool
    let loggedIn: Bool
    let authenticated: Bool
    let appearance: WorldAppearance?
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
    let generation: UInt32
    let motionSequence: UInt64
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
