import Combine
import Foundation

/// The game's read-only projection, not another owner of account state.
struct AppGameSession: Equatable {
    var sessionID: UInt32 = 0
    var accountID: String?
    var accessToken: String?
    var username: String?
    var bodyID: String?
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var authUser: AppAuthUser?
    @Published var appSnapshot: AppRuntimeSnapshot
    @Published var isRestoring = true
    @Published var isSigningIn = false
    @Published var authenticationNotice: String?
    @Published private(set) var gameSession = AppGameSession()
    @Published private(set) var logoutRequestID = 0

    let appRuntime = AppRuntimeBridge()
    let authentication: AppAuthenticationService
    let googleSignIn: NativeGoogleSignInService
    var appRequests: [UInt32: Task<Void, Never>] = [:]
    var profileRevision: UInt64 = 0
    private var authenticationTask: Task<Void, Never>?
    private var authenticationGeneration: UInt64 = 0
    private var started = false
    private var accessToken: String?

    init(authentication: AppAuthenticationService? = nil,
         googleSignIn: NativeGoogleSignInService? = nil,
         defaults: UserDefaults = .standard) {
        self.authentication = authentication ?? AppAuthenticationService()
        self.googleSignIn = googleSignIn ?? NativeGoogleSignInService()
        appSnapshot = appRuntime.snapshot()
        // Keychain survives reinstall; the installation marker does not.
        let marker = "cubacadabra.installation-marker"
        if defaults.string(forKey: marker) == nil {
            defaults.set(UUID().uuidString, forKey: marker)
            if defaults.string(forKey: "cubacadabra.player-id") == nil {
                self.authentication.clearTokens()
                self.googleSignIn.signOut()
            }
        }
    }

    var isAuthenticated: Bool { authUser != nil }

    func start() async {
        if !started {
            started = true
            refreshAuthentication()
        }
        await authenticationTask?.value
    }

    func refreshAuthentication() {
        guard authenticationTask == nil, !isSigningIn else { return }
        let generation = authenticationGeneration
        let revision = profileRevision
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            let result = await authentication.restore()
            guard !Task.isCancelled, generation == authenticationGeneration else { return }
            if var result {
                // A refresh that raced an edit/save must not roll back that work.
                if result.user.id == authUser?.id,
                   revision != profileRevision || profileUsername.usernameIsSaving,
                   let user = authUser {
                    result = AppAuthResult(accessToken: result.accessToken,
                        refreshToken: result.refreshToken, accessTokenExpiresIn: result.accessTokenExpiresIn,
                        user: user)
                }
                applyAuthentication(result, replaceSession: false)
            } else {
                clearSession()
            }
            isRestoring = false
            authenticationTask = nil
        }
    }

    func gameSessionRejected(_ sessionID: UInt32) {
        guard gameSession.sessionID == sessionID, isAuthenticated else { return }
        // A guest websocket response is not authority to log out the app.
        refreshAuthentication()
    }

    func signInWithGoogle() { beginSignIn { try await self.authentication.authenticateGoogle(credential: self.googleSignIn.signIn()) } }

    func signInWithEmail(email: String, password: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            authenticationNotice = "Enter your email and password."
            return
        }
        beginSignIn { try await self.authentication.authenticateEmail(email: email, password: password) }
    }

    private func beginSignIn(_ operation: @escaping @MainActor () async throws -> AppAuthResult) {
        guard !isSigningIn else { return }
        authenticationGeneration &+= 1
        authenticationTask?.cancel()
        let generation = authenticationGeneration
        isSigningIn = true
        authenticationNotice = nil
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == authenticationGeneration {
                    isSigningIn = false
                    isRestoring = false
                    authenticationTask = nil
                }
            }
            do {
                let result = try await operation()
                guard !Task.isCancelled, generation == authenticationGeneration else { return }
                applyAuthentication(result)
            } catch {
                guard !Task.isCancelled, generation == authenticationGeneration else { return }
                if let error = error as? AppAuthError, error == .cancelled { return }
                authenticationNotice = (error as? AppAuthError) == .server(401)
                    ? "That email or password is not correct." : "We couldn’t sign you in. Try again."
            }
        }
    }

    func clearAuthenticationNotice() { authenticationNotice = nil }

    func logOut() {
        authenticationGeneration &+= 1
        authenticationTask?.cancel()
        authenticationTask = nil
        authentication.clearTokens()
        googleSignIn.signOut()
        isSigningIn = false
        isRestoring = false
        authenticationNotice = nil
        clearSession()
        logoutRequestID &+= 1
    }

    func applyAuthentication(_ result: AppAuthResult, replaceSession: Bool = true) {
        let needsReplacement = replaceSession || authUser?.id != result.user.id
            || authUser?.username != result.user.username
        accessToken = result.accessToken
        authUser = result.user
        if needsReplacement { replaceAppSession() }
        authenticationNotice = nil
        publishGameSession()
    }

    private func clearSession() {
        accessToken = nil
        authUser = nil
        replaceAppSession()
        gameSession = AppGameSession(sessionID: appSnapshot.sessionId)
    }

    func publishGameSession() {
        gameSession = AppGameSession(sessionID: appSnapshot.sessionId, accountID: authUser?.id,
            accessToken: accessToken,
            username: authUser?.username, bodyID: authUser?.bodyID)
    }
}
