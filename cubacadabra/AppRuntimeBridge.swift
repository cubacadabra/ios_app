import Foundation

enum AppRuntimeFeedbackKind: String, Decodable { case success, error }

struct AppRuntimeUsernameFeedback: Decodable, Equatable {
    let kind: AppRuntimeFeedbackKind
    let message: String
}

struct AppRuntimeBirthdayFeedback: Decodable, Equatable {
    let kind: AppRuntimeFeedbackKind
    let code: String
    let message: String
}

struct AppRuntimeCatalogEntry: Decodable, Equatable, Identifiable {
    let cubeID: String
    let version: String
    let displayName: String
    let packagePath: String
    let assetBaseURL: String?

    private enum CodingKeys: String, CodingKey {
        case cubeID = "cubeId"
        case version
        case displayName
        case packagePath
        case assetBaseURL = "assetBaseUrl"
    }

    var id: String { cubeID }
}

struct AppRuntimeCatalogFeedback: Decodable, Equatable {
    let kind: AppRuntimeFeedbackKind
    let code: String
    let message: String
}

enum AppRuntimeSafetyPendingAction: String, Decodable, Equatable {
    case load
    case block
    case unblock
}

struct AppRuntimeSafetySnapshot: Decodable, Equatable {
    let blockedUserIDs: [String]
    let isLoading: Bool
    let pendingAction: AppRuntimeSafetyPendingAction?
    let pendingUserID: String?
    let feedback: AppRuntimeCatalogFeedback?

    private enum CodingKeys: String, CodingKey {
        case blockedUserIDs = "blockedUserIds"
        case isLoading
        case pendingAction
        case pendingUserID = "pendingUserId"
        case feedback
    }
}

struct AppRuntimeCatalogSnapshot: Decodable, Equatable {
    let entries: [AppRuntimeCatalogEntry]
    let page: Int
    let hasNextPage: Bool
    let isLoading: Bool
    let feedback: AppRuntimeCatalogFeedback?

    private enum CodingKeys: String, CodingKey {
        case entries
        case page
        case hasNextPage
        case isLoading
        case feedback
    }
}

struct AppRuntimeMorphAsset: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let displayName: String
    let thumbnail: String?
    let artifactURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, thumbnail
        case artifactURL = "artifact_url"
    }

    var identity: String { id }
}

struct AppRuntimeMorphPreset: Decodable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let base: String
    let parts: [String]
    let face: String?
    let thumbnail: String?
    var identity: String { id }
}

struct AppRuntimeAppearanceSnapshot: Decodable, Equatable {
    let release: String?
    let assets: [AppRuntimeMorphAsset]
    let presets: [AppRuntimeMorphPreset]
    let selectedBase: String?
    let selectedParts: [String]
    let selectedFace: String?
    let draftBase: String?
    let draftParts: [String]
    let draftFace: String?
    let draftPresetId: String?
    let selectedRenderJson: String?
    let draftRenderJson: String?
    let draftCanSave: Bool
    let isLoading: Bool
    let isSaving: Bool
    let feedback: AppRuntimeCatalogFeedback?
}

struct AppRuntimeProfileSnapshot: Decodable, Equatable {
    let username: String?
    let usernameDraft: String
    let usernameIsDirty: Bool
    let usernameCanSave: Bool
    let usernameIsSaving: Bool
    let usernameFeedback: AppRuntimeUsernameFeedback?
    let bodyId: String?
    let bodyDraft: String
    let bodyCanSave: Bool
    let bodyIsSaving: Bool
    let bodyFeedback: AppRuntimeUsernameFeedback?
    let dateOfBirth: String?
    let birthdayIsSaving: Bool
    let birthdayFeedback: AppRuntimeBirthdayFeedback?
}

struct AppRuntimeSnapshot: Decodable {
    let protocolVersion: Int
    let sessionId: UInt32
    let accountId: String?
    let profile: AppRuntimeProfileSnapshot
    let catalog: AppRuntimeCatalogSnapshot
    let safety: AppRuntimeSafetySnapshot
    let appearance: AppRuntimeAppearanceSnapshot

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case sessionId
        case accountId
        case profile
        case catalog
        case safety
        case appearance
    }
}

struct AppRuntimeHttpEffect: Decodable {
    let type: String
    let effectId: UInt32
    let accountId: String?
    let method: String
    let path: String
    let body: String

    private enum CodingKeys: String, CodingKey {
        case type
        case effectId
        case accountId
        case method
        case path
        case body
    }
}

/// The ABI is deliberately feature-independent. A protocol mismatch is a build
/// error, never a silent fallback to a second implementation of account rules.
@MainActor
final class AppRuntimeBridge {
    private let handle: OpaquePointer
    private let decoder: JSONDecoder

    init() {
        guard let handle = cubacadabra_app_create() else { preconditionFailure("Could not create app runtime") }
        self.handle = handle
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    deinit { cubacadabra_app_destroy(handle) }

    func dispatch(_ action: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: action)
            let accepted = data.withUnsafeBytes { buffer in
                cubacadabra_app_dispatch_json(handle, buffer.bindMemory(to: UInt8.self).baseAddress, UInt(data.count))
            }
            precondition(accepted == 1, "Invalid app action")
        } catch { preconditionFailure("Could not encode app action: \(error)") }
    }

    func snapshot() -> AppRuntimeSnapshot {
        precondition(cubacadabra_app_snapshot_json(handle) == 1)
        let snapshot: AppRuntimeSnapshot = decodeOutput()
        precondition(snapshot.protocolVersion == 1, "Unsupported app protocol")
        return snapshot
    }

    func pollEffect() -> AppRuntimeHttpEffect? {
        guard cubacadabra_app_poll_effect_json(handle) == 1 else { return nil }
        let effect: AppRuntimeHttpEffect = decodeOutput()
        precondition(effect.type == "http_request", "Unsupported app effect")
        return effect
    }

    private func decodeOutput<Value: Decodable>() -> Value {
        guard let pointer = cubacadabra_app_output_ptr(handle) else { preconditionFailure("Missing app output") }
        let data = Data(bytes: pointer, count: Int(cubacadabra_app_output_len(handle)))
        do { return try decoder.decode(Value.self, from: data) }
        catch { preconditionFailure("Invalid app output: \(error)") }
    }
}
