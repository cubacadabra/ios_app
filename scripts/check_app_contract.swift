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
                        "account_id": effect.accountId, "method": effect.method,
                        "path": effect.path, "body": effect.body,
                    ])
                }
                precondition(NSArray(array: effects).isEqual(to: step["effects"] as! [Any]), name)
            }
        }
        print("Passed \(scenarios.count) shared scenarios through the production Swift/C bridge.")
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
