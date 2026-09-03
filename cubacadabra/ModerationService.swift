import Foundation

struct ModerationService {
    let playerID: String

    func fetchBlockedPlayerIDs() async throws -> [String] {
        let response: ModerationBlocksResponse = try await request(
            path: "moderation/blocks",
            method: "GET"
        )
        return response.playerIDs
    }

    func blockPlayer(_ playerID: String) async throws {
        let _: ModerationSuccessResponse = try await request(
            path: "moderation/blocks",
            method: "POST",
            body: ["player_id": playerID]
        )
    }

    func unblockPlayer(_ playerID: String) async throws {
        let _: ModerationSuccessResponse = try await request(
            path: "moderation/blocks/\(playerID)",
            method: "DELETE"
        )
    }

    func reportPlayer(
        playerID: String,
        username: String,
        reason: String,
        details: String,
        worldID: String
    ) async throws {
        let _: ModerationSuccessResponse = try await request(
            path: "moderation/reports",
            method: "POST",
            body: [
                "player_id": playerID,
                "username": username,
                "reason": reason,
                "details": String(details.prefix(1_000)),
                "world_id": worldID,
            ]
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: [String: String]? = nil
    ) async throws -> Response {
        var request = URLRequest(url: endpoint(path: path))
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue(playerID, forHTTPHeaderField: "X-Cubacadabra-Player-ID")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body as Any)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModerationServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(ModerationErrorResponse.self, from: data)
            throw ModerationServiceError.server(serverError?.error ?? "request_failed")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ModerationServiceError.invalidResponse
        }
    }

    private func endpoint(path: String) -> URL {
        var components = URLComponents(url: ClientConfiguration.backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "wss" ? "https" : "http"
        return components.url!.appendingPathComponent(path, isDirectory: false)
    }
}

private struct ModerationBlocksResponse: Decodable {
    let playerIDs: [String]

    enum CodingKeys: String, CodingKey {
        case playerIDs = "player_ids"
    }
}

private struct ModerationSuccessResponse: Decodable {
    let ok: Bool
}

private struct ModerationErrorResponse: Decodable {
    let error: String
}

enum ModerationServiceError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The safety service returned an invalid response."
        case .server(let error):
            return error
        }
    }
}
