import Foundation
import simd

struct EngineUIEvent: Decodable {
    let nodeID: String
    let action: String
    let phase: String
    let value: Float?
    let x: Float?
    let y: Float?

    enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId"
        case action, phase, value, x, y
    }
}

struct RemotePlayerState {
    var username: String
    var position: SIMD3<Float>
    var yaw: Float
    var moving: Bool
    var sprinting: Bool
    var generation: UInt32
    var appearance: WorldAppearance?
}

struct RemoteUpdateMessage: Encodable {
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

struct RemoteUpdatePlayer: Encodable {
    let id: String
    let username: String
    let generation: UInt32
    let position: [Float]
    let yaw: Float
    let moving: Bool
    let sprinting: Bool
    let appearance: WorldAppearance?
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
