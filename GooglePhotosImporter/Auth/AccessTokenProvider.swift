import Foundation

// MARK: - Token provider abstraction

/// The only thing the Picker/Importer layers need from auth: a valid bearer
/// token. Keeping this as a protocol lets previews and unit tests inject a fake
/// without touching GoogleSignIn.
protocol AccessTokenProvider: AnyObject {
    /// Returns a non-expired access token, refreshing it first if necessary.
    func freshAccessToken() async throws -> String
}

enum AuthError: LocalizedError {
    case notConfigured
    case noPresentingViewController
    case notSignedIn
    case scopeNotGranted

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google sign-in isn't configured yet. Add your iOS OAuth client ID to Config/Secrets.xcconfig and regenerate the project (see README)."
        case .noPresentingViewController:
            return "Couldn't find a window to present Google sign-in from."
        case .notSignedIn:
            return "You're not signed in to Google."
        case .scopeNotGranted:
            return "Google Photos Picker access was not granted. Sign in again and allow access to the photos you pick."
        }
    }
}

// MARK: - Stub for previews & tests

/// A token provider that never talks to Google. Returns a fixed string so
/// network code paths can be exercised against a mock `URLSession`, or fails
/// with `AuthError.notSignedIn` to test error handling.
final class StubAccessTokenProvider: AccessTokenProvider {
    var token: String?

    init(token: String? = "stub-access-token") {
        self.token = token
    }

    func freshAccessToken() async throws -> String {
        guard let token else { throw AuthError.notSignedIn }
        return token
    }
}
