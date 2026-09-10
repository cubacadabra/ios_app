import Foundation

extension AppViewModel {
    var profileUsername: AppRuntimeProfileSnapshot { appSnapshot.profile }
    var catalogSnapshot: AppRuntimeCatalogSnapshot { appSnapshot.catalog }

    func beginProfileUsernameEdit() { dispatchApp(["type": "begin_username_edit"]) }
    func changeProfileUsername(_ value: String) { dispatchApp(["type": "username_changed", "value": value]) }
    func saveProfileUsername() { dispatchApp(["type": "save_username"]) }

    func beginMorphEdit() { dispatchApp(["type": "begin_body_edit"]) }
    func changeMorph(_ bodyID: String) { dispatchApp(["type": "body_changed", "body_id": bodyID]) }
    func saveMorph() { dispatchApp(["type": "save_body"]) }
    func loadCatalog(pageSize: Int = 20) {
        dispatchApp(["type": "load_catalog", "page_size": pageSize])
    }

    func saveBirthday(_ dateOfBirth: String) async throws -> AppProfileUpdateResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppProfileUpdateResult, Error>) in
            birthdayWaiter = continuation
            dispatchApp(["type": "save_birthday", "date_of_birth": dateOfBirth])
            if !appSnapshot.profile.birthdayIsSaving {
                if appSnapshot.profile.dateOfBirth == dateOfBirth, let user = authUser {
                    birthdayWaiter = nil
                    continuation.resume(returning: AppProfileUpdateResult(user: user, age: Self.calculateAge(from: dateOfBirth)))
                } else if let feedback = appSnapshot.profile.birthdayFeedback, feedback.kind == .error {
                    birthdayWaiter = nil
                    continuation.resume(throwing: AppProfileError.server(code: feedback.code, status: 400))
                }
            }
        }
    }

    func replaceAppSession() {
        for task in appRequests.values { task.cancel() }
        appRequests.removeAll()
        let bodyID: Any = authUser?.bodyID ?? NSNull()
        dispatchApp([
            "type": "replace_session",
            "account_id": authUser?.id as Any? ?? NSNull(),
            "username": authUser?.username as Any? ?? NSNull(),
            "body_id": bodyID,
            "date_of_birth": authUser?.dateOfBirth as Any? ?? NSNull(),
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
        if var user = authUser, user.id == appSnapshot.accountId,
           user.bodyID != appSnapshot.profile.bodyId {
            user.bodyID = appSnapshot.profile.bodyId
            authUser = user
            publishGameSession()
        }
        if var user = authUser, user.id == appSnapshot.accountId,
           user.dateOfBirth != appSnapshot.profile.dateOfBirth {
            user.dateOfBirth = appSnapshot.profile.dateOfBirth
            authUser = user
        }
        finishBirthdayWaiterIfReady()
        while let effect = appRuntime.pollEffect() {
            if birthdayWaiter != nil, birthdayEffectID == nil, appSnapshot.profile.birthdayIsSaving {
                birthdayEffectID = effect.effectId
            }
            guard effect.accountId == nil || effect.accountId == authUser?.id else {
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

    private func finishBirthdayWaiterIfReady() {
        guard let waiter = birthdayWaiter,
              birthdayEffectID != nil,
              !appSnapshot.profile.birthdayIsSaving else { return }
        birthdayWaiter = nil
        birthdayEffectID = nil
        if let feedback = appSnapshot.profile.birthdayFeedback, feedback.kind == .success,
           let user = authUser, user.dateOfBirth == appSnapshot.profile.dateOfBirth,
           let dateOfBirth = appSnapshot.profile.dateOfBirth {
            waiter.resume(returning: AppProfileUpdateResult(user: user, age: Self.calculateAge(from: dateOfBirth)))
        } else {
            let code = appSnapshot.profile.birthdayFeedback?.code
            waiter.resume(throwing: AppProfileError.server(code: code, status: 400))
        }
    }
}
