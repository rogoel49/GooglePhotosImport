import Foundation
import Observation
import UIKit
import GoogleSignIn

/// OAuth sign-in via the official GoogleSignIn-iOS SDK.
///
/// Requests only `photospicker.mediaitems.readonly` (CLAUDE.md hard constraint).
/// The SDK stores tokens in the keychain and refreshes them for us.
///
/// Setup this class depends on (all outside this file — see README):
///   - `GIDClientID` in Info.plist  ← `GOOGLE_CLIENT_ID` in Secrets.xcconfig
///   - A URL scheme equal to the reversed client ID, so Google's redirect
///     re-opens the app  ← `GOOGLE_REVERSED_CLIENT_ID` in Secrets.xcconfig
///   - The app calling `handle(openURL:)` from SwiftUI's `.onOpenURL`
@MainActor
@Observable
final class GooglePhotosAuth: AccessTokenProvider {

    /// Currently signed-in Google user, if any.
    private(set) var user: GIDGoogleUser?

    var isSignedIn: Bool { user != nil }
    var accountEmail: String? { user?.profile?.email }

    init() {
        configureSDKIfPossible()
    }

    private func configureSDKIfPossible() {
        guard AppConfig.isGoogleConfigured else {
            Log.auth.warning("GIDClientID missing or placeholder — sign-in disabled until Secrets.xcconfig is filled in.")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: AppConfig.googleClientID)
    }

    /// Silently restores a previous session on launch. Never throws — a failure
    /// just means the user has to tap Sign In.
    func restorePreviousSignIn() async {
        guard AppConfig.isGoogleConfigured else { return }
        do {
            let restored = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            guard hasPickerScope(restored) else {
                Log.auth.notice("Restored session lacks picker scope; forcing re-sign-in.")
                GIDSignIn.sharedInstance.signOut()
                return
            }
            user = restored
            Log.auth.info("Restored Google session for \(restored.profile?.email ?? "unknown", privacy: .private)")
        } catch {
            Log.auth.info("No previous Google session to restore: \(error.localizedDescription)")
        }
    }

    /// Interactive sign-in. Presents Google's sheet over the current top view
    /// controller and requests the picker scope in the same step.
    func signIn() async throws {
        guard AppConfig.isGoogleConfigured else { throw AuthError.notConfigured }
        guard let presenting = UIApplication.topViewController() else {
            throw AuthError.noPresentingViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenting,
            hint: nil,
            additionalScopes: [AppConfig.pickerScope]
        )

        guard hasPickerScope(result.user) else {
            GIDSignIn.sharedInstance.signOut()
            throw AuthError.scopeNotGranted
        }
        user = result.user
        Log.auth.info("Signed in as \(result.user.profile?.email ?? "unknown", privacy: .private)")
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
        Log.auth.info("Signed out.")
    }

    /// Forward the OAuth redirect URL from SwiftUI's `.onOpenURL`.
    /// Returns true if GoogleSignIn consumed it.
    @discardableResult
    func handle(openURL url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: AccessTokenProvider

    func freshAccessToken() async throws -> String {
        guard let user else { throw AuthError.notSignedIn }
        // Refreshes only if the current token is expired / about to expire.
        let refreshed = try await user.refreshTokensIfNeeded()
        return refreshed.accessToken.tokenString
    }

    // MARK: Helpers

    private func hasPickerScope(_ user: GIDGoogleUser) -> Bool {
        user.grantedScopes?.contains(AppConfig.pickerScope) ?? false
    }
}
