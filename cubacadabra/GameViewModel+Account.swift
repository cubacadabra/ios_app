import Foundation
import OSLog

extension GameViewModel {
    func requestSettingsInteraction() {
        guard settingsRoomState == 2, !usernameEditorOpen else { return }
        requestMyCube()
    }

    func requestMyCube() {
        guard !isSigningIn else { return }
        if isAuthenticated {
            myCubeRequestID &+= 1
        } else {
            // Guest users should see the complete account flow so they can
            // choose email/password or Google before signing in.
            authenticationNotice = nil
            gameExitRequestID &+= 1
        }
    }

    /// Starts the account flow from the app's full-screen sign-in state.
    func signIn() { signInWithGoogle() }

    func signInWithGoogle() { beginSignIn() }

    func clearAuthenticationNotice() { authenticationNotice = nil }

    func signInWithEmail(email: String, password: String) {
        guard !isSigningIn else { return }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            authenticationNotice = "Enter your email and password."
            return
        }

        isSigningIn = true
        authenticationNotice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await authentication.authenticateEmail(email: normalizedEmail, password: password)
                applyAuthentication(result)
            } catch let error as AppAuthError where error == .server(401) {
                authenticationNotice = "That email or password is not correct."
            } catch {
                gameLog.error("Email sign-in failed: \(error.localizedDescription, privacy: .public)")
                authenticationNotice = "We couldn’t sign you in. Try again."
            }
            isSigningIn = false
        }
    }

    /// Ends the signed-in session and starts a new anonymous game session.
    /// The profile's birthday is server-owned and is never removed locally.
    func logOut() {
        authentication.clearTokens()
        googleSignIn.signOut()
        worldSocket.disconnect()
        worldSocket.resetForGuest()
        connectedWorldID = nil
        hasEnteredGame = false
        isAuthenticated = false
        authUser = nil
        authenticationNotice = nil
        username = worldSocket.username
        engine?.setUsername(username)
        engine?.setAuthenticated(false)
        worldSocket.setAccessToken(Optional<String>.none)
        requestGuestGame()
    }

    private func requestGuestGame() {
        guard selectedGameID != "first-game" else {
            guestGameRequestID &+= 1
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await selectGame(GameCatalogEntry.available[0])
                guestGameRequestID &+= 1
            } catch {
                gameLog.error("Could not return to first game after logout: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var profileAge: Int? {
        guard let dob = authUser?.dateOfBirth else { return nil }
        return Self.calculateAge(from: dob)
    }

    var needsBirthday: Bool { isAuthenticated && authUser?.dateOfBirth == nil }
    var isUnderThirteen: Bool { profileAge.map { $0 < 13 } ?? false }

    func storedParentEmail() -> String {
        guard let userID = authUser?.id else { return "" }
        return UserDefaults.standard.string(forKey: "cubacadabra.parent-email.\(userID)") ?? ""
    }

    func saveParentEmail(_ email: String) {
        guard let userID = authUser?.id else { return }
        UserDefaults.standard.set(email, forKey: "cubacadabra.parent-email.\(userID)")
    }

    private func beginSignIn(presentMyCube: Bool = false) {
        guard !isSigningIn else { return }
        isSigningIn = true
        authenticationNotice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await googleSignIn.signIn()
                let result = try await authentication.authenticateGoogle(credential: credential)
                applyAuthentication(result)
                if presentMyCube { myCubeRequestID &+= 1 }
            } catch let error as AppAuthError where error == .cancelled {
                // The user dismissed the Google sign-in flow.
            } catch {
                gameLog.error("Native sign-in failed: \(error.localizedDescription, privacy: .public)")
                authenticationNotice = "We couldn’t sign you in. Try again."
            }
            isSigningIn = false
        }
    }

    func cancelUsernameEdit() {
        usernameEditorOpen = false
        forward = 0
        strafe = 0
        jumpQueued = false
    }

    func saveUsername(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 24 else {
            usernameStatus = "Use 2–24 characters."
            return
        }
        usernameStatus = "Checking that name…"
        worldSocket.setUsername(trimmed)
    }

    func saveBirthday(_ dob: String) async throws -> AppProfileUpdateResult {
        let result = try await authentication.saveBirthday(dob)
        authUser = result.user
        return result
    }

    func saveProfileUsername(_ value: String) async throws -> AppProfileUpdateResult {
        let result = try await authentication.saveUsername(value)
        applyProfileUpdate(result)
        return result
    }

    func saveMorph(_ bodyID: String) async throws -> AppProfileUpdateResult {
        let result = try await authentication.saveAvatar(bodyID: bodyID)
        authUser = result.user
        return result
    }

    private func applyProfileUpdate(_ result: AppProfileUpdateResult) {
        authUser = result.user
        guard let nextUsername = result.user.username, !nextUsername.isEmpty else { return }
        username = nextUsername
        worldSocket.adoptUsername(nextUsername)
        engine?.setUsername(nextUsername)
    }

    internal func applyAuthentication(_ result: AppAuthResult) {
        isAuthenticated = true
        authUser = result.user
        authenticationNotice = nil
        engine?.setAuthenticated(true)
        worldSocket.setAccessToken(result.accessToken)
        if let serverUsername = result.user.username, !serverUsername.isEmpty {
            worldSocket.adoptUsername(serverUsername)
            username = serverUsername
            engine?.setUsername(serverUsername)
        }
    }

    internal func clearAuthentication() {
        isAuthenticated = false
        authUser = nil
        engine?.setAuthenticated(false)
        worldSocket.setAccessToken(Optional<String>.none)
    }

    private static func calculateAge(from dob: String) -> Int? {
        let values = dob.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3, let year = values[safe: 0], let month = values[safe: 1], let day = values[safe: 2] else { return nil }
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let currentYear = now.year else { return nil }
        var age = currentYear - year
        if (now.month ?? 0, now.day ?? 0) < (month, day) { age -= 1 }
        return age
    }
}
