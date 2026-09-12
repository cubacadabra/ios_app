import Foundation

// Compile the production AppViewModel and Rust bridge without UIKit, a game
// engine, or network access. Only native authentication/HTTP services are fakes.
@MainActor
final class Deferred<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    var waiting: Bool { continuation != nil }
    func value() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Value) {
        precondition(continuation != nil)
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
final class AppAuthenticationService {
    var restoreResult: AppAuthResult?
    var pendingRestore: Deferred<AppAuthResult?>?
    var pendingHTTP = Deferred<(Int, String)>()
    var restoreCount = 0
    var requestAccounts: [String?] = []
    func clearTokens() {}
    func restore() async -> AppAuthResult? {
        restoreCount += 1
        if let pendingRestore { return await pendingRestore.value() }
        return restoreResult
    }
    func authenticateGoogle(credential: String) async throws -> AppAuthResult { throw AppAuthError.cancelled }
    func authenticateEmail(email: String, password: String) async throws -> AppAuthResult {
        guard let restoreResult else { throw AppAuthError.unavailable }
        return restoreResult
    }
    func appRequest(_ effect: AppRuntimeHttpEffect) throws -> URLRequest {
        requestAccounts.append(effect.accountId)
        return URLRequest(url: URL(string: "https://example.invalid/" + effect.path)!)
    }
    func performAppRequest(_ request: URLRequest) async throws -> (Int, String) {
        // This lifecycle test is intentionally independent of the morph
        // catalog contract. Let the automatic startup catalog request fail
        // immediately so the single deferred response remains available for
        // the profile race being exercised below.
        if request.url?.path.hasSuffix("/morphs/catalog") == true {
            return (503, "")
        }
        // Deliberately ignores task cancellation, exercising Rust's stale fence.
        return await pendingHTTP.value()
    }
}

@MainActor
final class NativeGoogleSignInService {
    func signOut() {}
    func signIn() async throws -> String { throw AppAuthError.cancelled }
}

@main
struct CheckAppLifecycle {
    @MainActor
    static func eventually(_ label: String, _ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure(label)
    }

    static func result(_ id: String, _ username: String, body: String = "cuba:person.v1") -> AppAuthResult {
        AppAuthResult(accessToken: "token-" + id, refreshToken: "refresh-" + id,
            accessTokenExpiresIn: 3600,
            user: AppAuthUser(id: id, email: nil, name: id, dateOfBirth: "2000-01-01",
                username: username, bodyID: body))
    }

    @MainActor
    static func main() async throws {
        let suite = "cubacadabra.lifecycle-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AppAuthenticationService()
        let ada = result("a", "Ada")
        auth.restoreResult = ada
        let app = AppViewModel(authentication: auth, defaults: defaults)
        await app.start()
        precondition(app.authUser?.id == ada.user.id && app.authUser?.username == ada.user.username
            && app.authUser?.bodyID == "cuba:person.v1" && !app.isRestoring)
        precondition(app.gameSession.accountID == "a" && app.gameSession.accessToken == "token-a")
        let initialSession = app.appSnapshot.sessionId
        await app.start()
        precondition(auth.restoreCount == 1 && app.appSnapshot.sessionId == initialSession)

        // Refreshing an unchanged account preserves an idle draft.
        app.changeProfileUsername("Grace")
        app.refreshAuthentication()
        await app.start()
        precondition(app.profileUsername.usernameDraft == "Grace")
        precondition(app.appSnapshot.sessionId == initialSession)

        // A same-account refresh during a save must not cancel pending work.
        app.saveProfileUsername()
        await eventually("HTTP started") { auth.pendingHTTP.waiting }
        precondition(auth.requestAccounts.compactMap { $0 } == ["a"])
        app.refreshAuthentication()
        await app.start()
        precondition(app.profileUsername.usernameIsSaving)
        precondition(app.appSnapshot.sessionId == initialSession)

        // Even a refresh response captured before the save completed cannot
        // roll back its accepted username or overwrite accepted account state.
        let refresh = Deferred<AppAuthResult?>()
        auth.pendingRestore = refresh
        app.refreshAuthentication()
        await eventually("Refresh started") { refresh.waiting }
        auth.pendingHTTP.finish((200, #"{"user":{"id":"a","username":"Grace","body_id":"old"}}"#))
        await eventually("Save finished") { !app.profileUsername.usernameIsSaving }
        refresh.finish(ada)
        await app.start()
        precondition(app.authUser?.username == "Grace" && app.gameSession.bodyID == "cuba:person.v1")
        precondition(app.gameSession.username == "Grace")

        // A new game/renderer never participates in any of the work above.
        // Logout + replacement must reject a late username completion.
        app.changeProfileUsername("NewName")
        app.saveProfileUsername()
        await eventually("Second save started") { auth.pendingHTTP.waiting }
        let oldSave = app.appRequests.values.first!
        app.logOut()
        precondition(!app.isAuthenticated && app.gameSession.accessToken == nil)
        let lin = result("b", "Lin")
        auth.restoreResult = lin
        app.signInWithEmail(email: "lin@example.invalid", password: "unused")
        await app.start()
        auth.pendingHTTP.finish((200, #"{"user":{"id":"a","username":"NewName"}}"#))
        await oldSave.value
        precondition(app.authUser?.id == "b" && app.authUser?.username == "Lin" && app.profileUsername.username == "Lin")
        precondition(app.gameSession.accountID == "b" && app.gameSession.accessToken == "token-b")

        // A birthday response racing logout is fenced by the same session identity.
        let birthday = Task { try await app.saveBirthday("2001-02-03") }
        await eventually("Birthday started") { auth.pendingHTTP.waiting }
        app.logOut()
        auth.pendingHTTP.finish((200, #"{"user":{"id":"b","dob":"2001-02-03"},"age":25}"#))
        do {
            _ = try await birthday.value
            preconditionFailure("Stale birthday accepted")
        } catch AppProfileError.unauthorized {}
        precondition(app.authUser == nil)

        // A canceled restore cannot resurrect an account after sign-out.
        let lateRestore = Deferred<AppAuthResult?>()
        auth.pendingRestore = lateRestore
        app.refreshAuthentication()
        await eventually("Late restore started") { lateRestore.waiting }
        var waiterStarted = false
        let waiter = Task {
            waiterStarted = true
            await app.start()
        }
        await eventually("Restore waiter started") { waiterStarted }
        app.logOut()
        let signedOutSession = app.appSnapshot.sessionId
        lateRestore.finish(lin)
        await waiter.value
        precondition(!app.isAuthenticated && app.appSnapshot.sessionId == signedOutSession)
        print("Passed app-only startup, refresh/save races, profile merging, replacement and stale-response lifecycle checks.")
    }
}
