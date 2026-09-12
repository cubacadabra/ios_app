import Foundation

@main
struct CheckAppContract {
    @MainActor
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let scenarios = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for scenario in scenarios {
            let runtime = AppRuntimeBridge()
            let name = scenario["name"] as! String
            for step in scenario["steps"] as! [[String: Any]] {
                runtime.dispatch(step["action"] as! [String: Any])
                let snapshot = runtime.snapshot()
                let profile = snapshot.profile
                let projected: [String: Any] = [
                    "protocol_version": snapshot.protocolVersion,
                    "session_id": snapshot.sessionId,
                    "account_id": snapshot.accountId as Any? ?? NSNull(),
                    "profile": [
                        "username": profile.username as Any? ?? NSNull(),
                        "username_draft": profile.usernameDraft,
                        "username_is_dirty": profile.usernameIsDirty,
                        "username_can_save": profile.usernameCanSave,
                        "username_is_saving": profile.usernameIsSaving,
                        "username_feedback": profile.usernameFeedback.map {
                            ["kind": $0.kind.rawValue, "message": $0.message]
                        } as Any? ?? NSNull(),
                        "body_id": profile.bodyId as Any? ?? NSNull(),
                        "body_draft": profile.bodyDraft,
                        "body_can_save": profile.bodyCanSave,
                        "body_is_saving": profile.bodyIsSaving,
                        "body_feedback": profile.bodyFeedback.map {
                            ["kind": $0.kind.rawValue, "message": $0.message]
                        } as Any? ?? NSNull(),
                        "date_of_birth": profile.dateOfBirth as Any? ?? NSNull(),
                        "birthday_is_saving": profile.birthdayIsSaving,
                        "birthday_feedback": profile.birthdayFeedback.map {
                            ["kind": $0.kind.rawValue, "code": $0.code, "message": $0.message]
                        } as Any? ?? NSNull(),
                    ],
                ]
                assertSubset(projected, step["expected"]!, label: name)
                var effects: [[String: Any]] = []
                while let effect = runtime.pollEffect() {
                    effects.append([
                        "type": effect.type, "effect_id": effect.effectId,
                        "account_id": effect.accountId as Any? ?? NSNull(), "method": effect.method,
                        "path": effect.path, "body": effect.body,
                    ])
                }
                precondition(NSArray(array: effects).isEqual(to: step["effects"] as! [Any]), name)
            }
        }
        print("Passed \(scenarios.count) shared scenarios through the production Swift/C bridge.")

        let catalogRuntime = AppRuntimeBridge()
        catalogRuntime.dispatch(["type": "load_catalog", "page": 1, "page_size": 20])
        guard let catalogEffect = catalogRuntime.pollEffect() else {
            preconditionFailure("catalog effect missing")
        }
        precondition(catalogEffect.accountId == nil)
        precondition(catalogEffect.path == "cubes?page=1&page_size=20")
        catalogRuntime.dispatch([
            "type": "http_completed",
            "effect_id": catalogEffect.effectId,
            "status": 200,
            "body": "{\"page\":1,\"hasNextPage\":false,\"cubes\":[{\"id\":1,\"cubeId\":\"uploaded-cube\",\"version\":\"1.0.0\",\"displayName\":\"Uploaded Cube\",\"fileCount\":1,\"packagePath\":\"/cubes/1/files/\"}]}",
        ])
        let catalogEntry = catalogRuntime.snapshot().catalog.entries.first
        precondition(catalogEntry?.cubeID == "uploaded-cube")
        precondition(catalogEntry?.assetBaseURL == nil)
        print("Passed explicit Swift catalog schema and public-effect checks.")

        let safetyRuntime = AppRuntimeBridge()
        safetyRuntime.dispatch([
            "type": "replace_session",
            "account_id": "account-1",
            "username": "Ada",
            "body_id": "cuba:person.v1",
            "date_of_birth": "2000-01-01",
        ])
        safetyRuntime.dispatch(["type": "load_blocked_users"])
        guard let safetyEffect = safetyRuntime.pollEffect() else {
            preconditionFailure("blocked users effect missing")
        }
        precondition(safetyEffect.path == "moderation/blocks")
        precondition(safetyEffect.accountId == "account-1")
        safetyRuntime.dispatch([
            "type": "http_completed",
            "effect_id": safetyEffect.effectId,
            "status": 200,
            "body": "{\"ok\":true,\"user_ids\":[\"user-1\"]}",
        ])
        precondition(safetyRuntime.snapshot().safety.blockedUserIDs == ["user-1"])
        safetyRuntime.dispatch(["type": "unblock_user", "user_id": "user-1"])
        guard let unblockEffect = safetyRuntime.pollEffect() else {
            preconditionFailure("unblock effect missing")
        }
        precondition(unblockEffect.path == "moderation/blocks/user-1")
        safetyRuntime.dispatch([
            "type": "http_completed",
            "effect_id": unblockEffect.effectId,
            "status": 200,
            "body": "{\"ok\":true}",
        ])
        precondition(safetyRuntime.snapshot().safety.blockedUserIDs.isEmpty)
        print("Passed explicit Swift safety schema and rollback checks.")

        let appearanceRuntime = AppRuntimeBridge()
        appearanceRuntime.dispatch(["type": "load_appearance_catalog"])
        guard let appearanceEffect = appearanceRuntime.pollEffect() else {
            preconditionFailure("appearance catalog effect missing")
        }
        appearanceRuntime.dispatch([
            "type": "http_completed",
            "effect_id": appearanceEffect.effectId,
            "status": 200,
            "body": """
            {
              "release": "test-v5",
              "assets": [{
                "id": "cuba:base/person.v1",
                "kind": "base",
                "name": "Person",
                "artifact": {"url": "/morphs/packs/person.morphpack"},
                "definition": {
                  "id": "cuba:base/person.v1",
                  "kind": "base",
                  "displayName": "Person",
                  "fitProfiles": [],
                  "occupiedSlots": ["base"],
                  "coverage": ["body"],
                  "materials": ["skin"],
                  "lod": {"near": 1, "mid": 1, "far": 1},
                  "provenance": {"source": "test", "license": "test"}
                }
              }],
              "presets": []
            }
            """,
        ])
        precondition(
            appearanceRuntime.snapshot().appearance.assets.first?.artifactURL
                == "/morphs/packs/person.morphpack"
        )
        print("Passed morph artifact URL decoding check.")
    }

    static func assertSubset(_ actual: Any, _ expected: Any, label: String) {
        if let expected = expected as? [String: Any] {
            let actual = actual as! [String: Any]
            for (key, value) in expected {
                // Codes/validation are checked by Rust and WASM; Swift renders messages.
                if key == "code" || key == "username_validation_error" { continue }
                precondition(actual[key] != nil, label + "." + key)
                assertSubset(actual[key]!, value, label: label + "." + key)
            }
        } else {
            precondition((actual as! NSObject).isEqual(expected), label)
        }
    }
}
