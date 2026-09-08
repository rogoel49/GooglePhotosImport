import Foundation

/// A Google Photos shared album the user wants to import from.
///
/// Decision (scaffold): the MVP shows a single album, but the model is a list
/// so supporting several albums later is a UI change, not a data migration.
///
/// Note: the Picker API cannot deep-link the picker to a specific album. The
/// `shareURL` is only used for an "Open album in Google Photos" convenience
/// button so the user can find it quickly; selection still happens in Google's
/// picker UI.
struct SharedAlbum: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// The `https://photos.app.goo.gl/...` (or `photos.google.com/share/...`)
    /// link the album was shared with. Optional — purely a convenience.
    var shareURL: URL?
}

/// Persists the album list in `UserDefaults`. Tiny on purpose (see CLAUDE.md:
/// "Lightweight local persistence").
struct SharedAlbumStore {
    private let defaults: UserDefaults
    private let key = "sharedAlbums.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SharedAlbum] {
        guard let data = defaults.data(forKey: key),
              let albums = try? JSONDecoder().decode([SharedAlbum].self, from: data),
              !albums.isEmpty
        else {
            return [SharedAlbum(name: "Shared album", shareURL: nil)]
        }
        return albums
    }

    func save(_ albums: [SharedAlbum]) {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        defaults.set(data, forKey: key)
    }
}
