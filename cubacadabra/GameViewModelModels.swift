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
