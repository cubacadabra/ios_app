import Foundation

extension Notification.Name {
    static let cubacadabraAuthCallback = Notification.Name("cubacadabra.auth.callback")
}

struct AppAuthUser: Codable, Equatable {
    let id: String
    let email: String?
    let name: String
    var dateOfBirth: String?
    var username: String?
    var bodyID: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name
        case dateOfBirth = "dob"
        case username
        case bodyID = "body_id"
    }
}

struct AppAuthResult: Equatable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresIn: Int
    let user: AppAuthUser
}

struct AppProfileUpdateResult: Equatable {
    let user: AppAuthUser
    let age: Int?
}

enum AppAuthError: LocalizedError, Equatable {
    case cancelled
    case invalidCallback
    case invalidResponse
    case server(Int)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign in was cancelled."
        case .invalidCallback, .invalidResponse: return "The sign-in response was invalid."
        case .server: return "The sign-in service returned an error."
        case .unavailable: return "Sign in is temporarily unavailable."
        }
    }
}

enum AppProfileError: LocalizedError, Equatable {
    case unauthorized
    case unavailable
    case server(code: String?, status: Int)

    var errorCode: String? {
        guard case let .server(code, _) = self else { return nil }
        return code
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your sign-in has expired. Please sign in again."
        case .unavailable: return "The player profile is temporarily unavailable."
        case .server: return "The player profile could not be updated."
        }
    }
}
