import Foundation
import Security
import UIKit

extension Notification.Name {
    static let cubacadabraAuthCallback = Notification.Name("cubacadabra.auth.callback")
}

struct AppAuthUser: Codable, Equatable {
    let id: String
    let email: String?
    let name: String
    let dateOfBirth: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name
        case dateOfBirth = "dob"
        case username
    }
}

struct AppAuthResult: Equatable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresIn: Int
    let user: AppAuthUser
    let browserHandoffCode: String?
}

enum AppAuthError: LocalizedError, Equatable {
    case cancelled
    case invalidCallback
    case invalidResponse
    case server(Int)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign in was cancelled."
        case .invalidCallback, .invalidResponse:
            return "The sign-in response was invalid."
        case .server:
            return "The sign-in service returned an error."
        case .unavailable:
            return "Sign in is temporarily unavailable."
        }
    }
}

@MainActor
final class AppAuthenticationService: NSObject {
    private struct StoredTokens: Codable {
        let accessToken: String
        let refreshToken: String
    }

    private struct AuthResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let user: AppAuthUser
        let browserCode: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
            case browserCode = "browser_code"
        }
    }

    private struct BrowserHandoffResponse: Decodable {
        let browserCode: String

        enum CodingKeys: String, CodingKey {
            case browserCode = "browser_code"
        }
    }

    private let keychainService = "com.cubacadabra.app.auth"

    func restore() async -> AppAuthResult? {
        guard let storedTokens = loadTokens() else { return nil }

        do {
            return try await authenticatedResult(using: storedTokens)
        } catch {
            guard let refreshed = try? await refresh(storedTokens.refreshToken) else {
                clearTokens()
                return nil
            }
            return refreshed
        }
    }

    func signIn() async throws -> AppAuthResult {
        let state = randomString()
        var components = URLComponents(url: ClientConfiguration.loginURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "app_redirect_uri", value: ClientConfiguration.authCallbackURL.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        guard let loginURL = components?.url else { throw AppAuthError.unavailable }

        let callbackURL = try await startBrowserAuthentication(url: loginURL)
        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        guard callbackURL.scheme == ClientConfiguration.authCallbackURL.scheme,
              callbackURL.host == ClientConfiguration.authCallbackURL.host,
              callbackURL.path == ClientConfiguration.authCallbackURL.path,
              callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw AppAuthError.invalidCallback
        }

        let result = try await exchange(code: code)
        saveTokens(accessToken: result.accessToken, refreshToken: result.refreshToken)
        return result
    }

    func clearTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "tokens",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func authenticatedResult(using tokens: StoredTokens) async throws -> AppAuthResult {
        var request = URLRequest(url: ClientConfiguration.backendAPIURL.appendingPathComponent("auth/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw AppAuthError.server(response.statusCode)
        }
        let user = try decodeUser(from: data)
        return AppAuthResult(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accessTokenExpiresIn: 0,
            user: user,
            browserHandoffCode: nil
        )
    }

    func authenticateGoogle(credential: String) async throws -> AppAuthResult {
        let result = try await tokenRequest(path: "auth/app/google", body: ["credential": credential])
        saveTokens(accessToken: result.accessToken, refreshToken: result.refreshToken)
        return result
    }

    func createBrowserHandoffCode() async throws -> String {
        guard let tokens = loadTokens() else { throw AppAuthError.unavailable }
        var request = URLRequest(url: ClientConfiguration.backendAPIURL.appendingPathComponent("auth/browser/authorize"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw AppAuthError.server(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(BrowserHandoffResponse.self, from: data),
              !decoded.browserCode.isEmpty else {
            throw AppAuthError.invalidResponse
        }
        return decoded.browserCode
    }

    private func exchange(code: String) async throws -> AppAuthResult {
        try await tokenRequest(
            path: "auth/app/exchange",
            body: [
                "code": code,
                "redirect_uri": ClientConfiguration.authCallbackURL.absoluteString,
            ]
        )
    }

    private func refresh(_ refreshToken: String) async throws -> AppAuthResult {
        let result = try await tokenRequest(
            path: "auth/app/refresh",
            body: ["refresh_token": refreshToken]
        )
        saveTokens(accessToken: result.accessToken, refreshToken: result.refreshToken)
        return result
    }

    private func tokenRequest(path: String, body: [String: String]) async throws -> AppAuthResult {
        var request = URLRequest(url: ClientConfiguration.backendAPIURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw AppAuthError.server(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
            return AppAuthResult(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                accessTokenExpiresIn: decoded.expiresIn,
                user: decoded.user,
                browserHandoffCode: decoded.browserCode
            )
        } catch {
            throw AppAuthError.invalidResponse
        }
    }

    private func decodeUser(from data: Data) throws -> AppAuthUser {
        struct UserResponse: Decodable {
            let user: AppAuthUser
        }
        do {
            return try JSONDecoder().decode(UserResponse.self, from: data).user
        } catch {
            throw AppAuthError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppAuthError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as AppAuthError {
            throw error
        } catch {
            throw AppAuthError.unavailable
        }
    }

    private func startBrowserAuthentication(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .cubacadabraAuthCallback,
                object: nil,
                queue: .main
            ) { notification in
                guard let callbackURL = notification.object as? URL else { return }
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(returning: callbackURL)
            }

            UIApplication.shared.open(url, options: [:]) { opened in
                guard !opened else { return }
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(throwing: AppAuthError.unavailable)
            }
        }
    }

    private func loadTokens() -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    private func saveTokens(accessToken: String, refreshToken: String) {
        guard let data = try? JSONEncoder().encode(StoredTokens(accessToken: accessToken, refreshToken: refreshToken)) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "tokens",
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    private func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
