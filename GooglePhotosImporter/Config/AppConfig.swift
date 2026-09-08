import Foundation

/// Static app configuration.
///
/// Anything that depends on Google Cloud credentials is read from Info.plist,
/// which `xcodegen generate` fills in from `Config/Secrets.xcconfig` (see
/// `project.yml`). Nothing here should be edited to add a real client ID —
/// put it in the xcconfig instead.
enum AppConfig {

    // MARK: Google OAuth

    /// The iOS OAuth client ID (`GIDClientID` in Info.plist). Empty or a
    /// placeholder until `Config/Secrets.xcconfig` exists.
    static var googleClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String) ?? ""
    }

    /// True once a real-looking client ID is present. The UI uses this to show
    /// a setup checklist instead of a sign-in button.
    static var isGoogleConfigured: Bool {
        let id = googleClientID
        return !id.isEmpty
            && !id.contains("YOUR_IOS_CLIENT_ID")
            && id.hasSuffix(".apps.googleusercontent.com")
    }

    /// Least-privilege scope: read only the items the user explicitly picks.
    /// Do not add broader Photos Library scopes — see CLAUDE.md "Hard constraints".
    static let pickerScope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

    // MARK: Google Photos Picker API

    static let pickerAPIBaseURL = URL(string: "https://photospicker.googleapis.com/v1")!

    /// Fallback poll interval when the API's `pollingConfig` is missing.
    static let defaultPollInterval: TimeInterval = 5

    /// Fallback overall timeout for waiting on the user's selection.
    static let defaultPickerTimeout: TimeInterval = 30 * 60

    // MARK: iOS Photos

    /// Title of the dedicated album items are written into (never the main
    /// camera roll directly — spec MVP requirement).
    static let importedAlbumTitle = "Imported from Google Photos"
}
