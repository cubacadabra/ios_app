import Foundation

extension AppViewModel {
    var profileUsername: AppRuntimeProfileSnapshot { appSnapshot.profile }

    func beginProfileUsernameEdit() { dispatchApp(["type": "begin_username_edit"]) }
    func changeProfileUsername(_ value: String) { dispatchApp(["type": "username_changed", "value": value]) }
    func saveProfileUsername() { dispatchApp(["type": "save_username"]) }

    func replaceAppSession() {
        for task in appRequests.values { task.cancel() }
        appRequests.removeAll()
        dispatchApp([
            "type": "replace_session",
            "account_id": authUser?.id as Any? ?? NSNull(),
            "username": authUser?.username as Any? ?? NSNull(),
        ])
    }

    private func dispatchApp(_ action: [String: Any]) {
        profileRevision &+= 1
        appRuntime.dispatch(action)
        appSnapshot = appRuntime.snapshot()
        // Only accepted Rust state can change the host profile. Other profile
        // endpoints merge their own fields so they cannot roll this value back.
        if var user = authUser, user.id == appSnapshot.accountId,
           user.username != appSnapshot.profile.username {
            user.username = appSnapshot.profile.username
            authUser = user
            publishGameSession()
        }
        while let effect = appRuntime.pollEffect() {
            guard effect.accountId == authUser?.id else {
                dispatchApp(["type": "http_failed", "effect_id": effect.effectId])
                continue
            }
            let request: URLRequest
            do { request = try authentication.appRequest(effect) }
            catch {
                dispatchApp(["type": "http_completed", "effect_id": effect.effectId, "status": 401, "body": ""])
                continue
            }
            appRequests[effect.effectId] = Task { [weak self] in
                guard let self else { return }
                do {
                    let (status, body) = try await authentication.performAppRequest(request)
                    dispatchApp(["type": "http_completed", "effect_id": effect.effectId, "status": status, "body": body])
                } catch {
                    dispatchApp(["type": "http_failed", "effect_id": effect.effectId])
                }
                appRequests.removeValue(forKey: effect.effectId)
            }
        }
    }
}
