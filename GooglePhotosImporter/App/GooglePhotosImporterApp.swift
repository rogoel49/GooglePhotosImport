import SwiftUI

@main
struct GooglePhotosImporterApp: App {
    @State private var auth: GooglePhotosAuth
    @State private var model: ImportViewModel

    init() {
        let auth = GooglePhotosAuth()
        _auth = State(initialValue: auth)
        _model = State(initialValue: ImportViewModel(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            ImportView(model: model)
                // Google's OAuth redirect (scheme = reversed client ID) lands here.
                .onOpenURL { url in
                    auth.handle(openURL: url)
                }
        }
    }
}
