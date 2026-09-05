import GoogleSignIn
import UIKit

@MainActor
final class NativeGoogleSignInService {
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    func signIn() async throws -> String {
        guard let presentingViewController = UIApplication.shared.activeRootViewController else {
            throw AppAuthError.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController) { result, error in
                if let result, let idToken = result.user.idToken?.tokenString {
                    continuation.resume(returning: idToken)
                    return
                }
                continuation.resume(throwing: error ?? AppAuthError.invalidResponse)
            }
        }
    }
}

extension UIApplication {
    var activeRootViewController: UIViewController? {
        let windowScene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return windowScene?.windows.first(where: \.isKeyWindow)?.rootViewController
    }
}
