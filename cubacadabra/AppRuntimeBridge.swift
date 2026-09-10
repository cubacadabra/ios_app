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
    // These names intentionally match JSONDecoder.convertFromSnakeCase:
    // cube_id -> cubeId and asset_base_url -> assetBaseUrl.
    let cubeId: String
    let version: String
    let displayName: String
    let packagePath: String
    let assetBaseUrl: String?

    var id: String { cubeId }
}

struct AppRuntimeCatalogFeedback: Decodable, Equatable {
    let kind: AppRuntimeFeedbackKind
    let code: String
    let message: String
}

struct AppRuntimeCatalogSnapshot: Decodable, Equatable {
    let entries: [AppRuntimeCatalogEntry]
    let isLoading: Bool
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
}

struct AppRuntimeHttpEffect: Decodable {
    let type: String
    let effectId: UInt32
    let accountId: String?
    let method: String
    let path: String
    let body: String
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
