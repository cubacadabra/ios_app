import Foundation

extension AppViewModel {
    var profileUsername: AppRuntimeProfileSnapshot { appSnapshot.profile }
    var catalogSnapshot: AppRuntimeCatalogSnapshot { appSnapshot.catalog }
    var safetySnapshot: AppRuntimeSafetySnapshot { appSnapshot.safety }
    var appearanceSnapshot: AppRuntimeAppearanceSnapshot { appSnapshot.appearance }

    func loadAppearanceCatalog() { dispatchApp(["type": "load_appearance_catalog"]) }
    func beginProfileUsernameEdit() { dispatchApp(["type": "begin_username_edit"]) }
    func changeProfileUsername(_ value: String) { dispatchApp(["type": "username_changed", "value": value]) }
    func saveProfileUsername() { dispatchApp(["type": "save_username"]) }

    func beginMorphEdit() { dispatchApp(["type": "begin_appearance_edit"]) }
    func chooseMorphPreset(_ presetID: String) { dispatchApp(["type": "select_morph_preset", "preset_id": presetID]) }
    func setMorphPart(_ assetID: String) { dispatchApp(["type": "set_morph_part", "asset_id": assetID]) }
    func clearMorphPart(_ assetID: String) { dispatchApp(["type": "clear_morph_part", "asset_id": assetID]) }
    func saveMorph() { dispatchApp(["type": "save_appearance"]) }
    func loadCatalog(page: Int = 1, pageSize: Int = 20) {
        dispatchApp(["type": "load_catalog", "page": page, "page_size": pageSize])
    }
    func loadBlockedUsers() {
        dispatchApp(["type": "load_blocked_users"])
    }
    func blockUser(_ userID: String) {
        dispatchApp(["type": "block_user", "user_id": userID])
    }
    func unblockUser(_ userID: String) {
        dispatchApp(["type": "unblock_user", "user_id": userID])
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
        dispatchApp(["type": "load_appearance_catalog"])
    }

    func appearanceWireJSON() -> String? {
        appSnapshot.appearance.selectedLoadoutJson
    }

    private func dispatchApp(_ action: [String: Any]) {
        let previousBlockedUserIDs = appSnapshot.safety.blockedUserIDs
        let previousAppearanceJSON = appearanceWireJSON()
        let previousMorphArtifactURLs = morphArtifactURLs()
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
        if previousBlockedUserIDs != appSnapshot.safety.blockedUserIDs {
            publishGameSession()
        }
        if previousAppearanceJSON != appearanceWireJSON() {
            publishGameSession()
        }
        if previousMorphArtifactURLs != morphArtifactURLs() {
            publishGameSession()
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
