import Foundation

enum AppRuntimeBridgeError: Error {
    case creationFailed
    case invalidSnapshot
}

enum AppRuntimeFeedbackKind: String, Decodable {
    case success
    case error
}

struct AppRuntimeUsernameFeedback: Decodable, Equatable {
    let kind: AppRuntimeFeedbackKind
    let message: String
}

struct AppRuntimeProfileSnapshot: Decodable, Equatable {
    let username: String?
    let usernameDraft: String
    let usernameIsDirty: Bool
    let usernameCanSave: Bool
    let usernameIsSaving: Bool
    let usernameFeedback: AppRuntimeUsernameFeedback?

    static let empty = AppRuntimeProfileSnapshot(
        username: nil,
        usernameDraft: "",
        usernameIsDirty: false,
        usernameCanSave: false,
        usernameIsSaving: false,
        usernameFeedback: nil
    )
}

private struct AppRuntimeSnapshot: Decodable {
    let profile: AppRuntimeProfileSnapshot
}

struct AppRuntimeUsernameEffect: Equatable {
    let id: UInt32
    let username: String
}

final class AppRuntimeBridge {
    private let handle: OpaquePointer
    private let decoder: JSONDecoder

    init(username: String?) throws {
        let bytes = Array((username ?? "").utf8)
        let created = bytes.withUnsafeBytes { buffer in
            cubacadabra_app_create(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count)
            )
        }
        guard let created else { throw AppRuntimeBridgeError.creationFailed }
        handle = created
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    deinit {
        cubacadabra_app_destroy(handle)
    }

    func usernameChanged(_ value: String) {
        withUTF8(value) { pointer, length in
            _ = cubacadabra_app_username_changed(handle, pointer, length)
        }
    }

    func requestUsernameSave() {
        cubacadabra_app_save_username(handle)
    }

    func usernameSaved(effectID: UInt32, username: String) {
        withUTF8(username) { pointer, length in
            _ = cubacadabra_app_username_saved(handle, effectID, pointer, length)
        }
    }

    func usernameSaveFailed(effectID: UInt32, serverCode: String) {
        withUTF8(serverCode) { pointer, length in
            _ = cubacadabra_app_username_save_failed(handle, effectID, pointer, length)
        }
    }

    func snapshot() throws -> AppRuntimeProfileSnapshot {
        guard cubacadabra_app_snapshot_json(handle) != 0,
              let data = outputData() else {
            throw AppRuntimeBridgeError.invalidSnapshot
        }
        return try decoder.decode(AppRuntimeSnapshot.self, from: data).profile
    }

    func pollUsernameEffect() -> AppRuntimeUsernameEffect? {
        guard cubacadabra_app_poll_effect(handle) == CUBACADABRA_APP_EFFECT_SAVE_USERNAME,
              let username = outputString() else {
            return nil
        }
        return AppRuntimeUsernameEffect(
            id: cubacadabra_app_effect_id(handle),
            username: username
        )
    }

    private func outputData() -> Data? {
        let length = Int(cubacadabra_app_output_len(handle))
        guard length > 0, let pointer = cubacadabra_app_output_ptr(handle) else { return nil }
        return Data(bytes: pointer, count: length)
    }

    private func outputString() -> String? {
        guard let data = outputData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func withUTF8<Result>(
        _ value: String,
        _ body: (UnsafePointer<UInt8>?, UInt) -> Result
    ) -> Result {
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBytes { buffer in
            body(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
        }
    }
}
