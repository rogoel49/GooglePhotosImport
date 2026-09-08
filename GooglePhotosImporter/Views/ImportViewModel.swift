import Foundation
import Observation
import UIKit

/// Drives `ImportView`. Owns the one-shot import pipeline and exposes a single
/// `phase` the view renders. All networking/auth lives in the injected
/// collaborators — this class is glue only (CLAUDE.md → Conventions).
@MainActor
@Observable
final class ImportViewModel {

    enum Phase: Equatable {
        case idle
        case creatingSession
        /// Picker is open in the browser / Google Photos app; we're polling.
        case waitingForSelection(sessionID: String)
        case fetchingSelection
        case importing(ImportProgress)
        case finished(ImportProgress)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed: return false
            default: return true
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var importedCount = 0
    /// Edited directly by the view; persisted via `saveAlbums()`.
    var albums: [SharedAlbum]
    /// The album the single "Import" button acts on (MVP: first in the list).
    var selectedAlbum: SharedAlbum? { albums.first }

    /// Set when the picker URL should be opened; the view observes it and
    /// calls `UIApplication.shared.open`. Kept out of the model so it stays
    /// testable.
    var pendingPickerURL: URL?

    let auth: GooglePhotosAuth
    private let picker: PickerSessionManager
    private let importer: PhotoImporter
    private let store: ImportedItemStore
    private let albumStore: SharedAlbumStore
    private var importTask: Task<Void, Never>?

    init(
        auth: GooglePhotosAuth,
        store: ImportedItemStore = ImportedItemStore(),
        albumStore: SharedAlbumStore = SharedAlbumStore()
    ) {
        self.auth = auth
        self.store = store
        self.albumStore = albumStore
        self.albums = albumStore.load()
        self.picker = PickerSessionManager(tokenProvider: auth)
        self.importer = PhotoImporter(tokenProvider: auth, store: store)
    }

    // MARK: Lifecycle

    func onAppear() async {
        await auth.restorePreviousSignIn()
        importedCount = await store.count
    }

    func saveAlbums() {
        albumStore.save(albums)
    }

    // MARK: Auth

    func signIn() async {
        do {
            try await auth.signIn()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        cancelImport()
        auth.signOut()
        phase = .idle
    }

    // MARK: Import pipeline

    /// Runs the whole flow: session → picker → poll → list → dedup → save.
    func startImport() {
        guard !phase.isBusy else { return }
        importTask = Task { await runImport() }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        if phase.isBusy { phase = .idle }
    }

    func dismissResult() {
        phase = .idle
    }

    private func runImport() async {
        var sessionID: String?
        defer {
            if let sessionID {
                Task { await picker.deleteSession(id: sessionID) }
            }
        }

        do {
            guard auth.isSignedIn else { throw AuthError.notSignedIn }

            // Ask for Photos permission first so a denial fails fast, before
            // the user spends time picking.
            try await importer.requestPhotoLibraryAccess()

            phase = .creatingSession
            let session = try await picker.createSession()
            sessionID = session.id
            guard let pickerURL = session.pickerURL else { throw PickerError.invalidPickerURL }

            phase = .waitingForSelection(sessionID: session.id)
            pendingPickerURL = pickerURL
            let ready = try await picker.waitForSelection(session)

            phase = .fetchingSelection
            let picked = try await picker.listMediaItems(sessionID: ready.id)

            // Dedup against the local ledger BEFORE touching Photos.
            let (newItems, duplicates) = await store.partition(picked)
            for dup in duplicates {
                Log.importer.notice("Skipping already-imported \(dup.filename ?? dup.id, privacy: .public)")
            }

            phase = .importing(ImportProgress(total: newItems.count, skippedDuplicates: duplicates.count))
            let result = try await importer.importItems(newItems, skippedDuplicates: duplicates.count) { [weak self] progress in
                self?.phase = .importing(progress)
            }

            importedCount = await store.count
            phase = Task.isCancelled ? .idle : .finished(result)
        } catch is CancellationError {
            phase = .idle
        } catch PickerError.cancelled {
            phase = .idle
        } catch {
            Log.ui.error("Import failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Debug

    func resetDedupHistory() async {
        do {
            try await store.removeAll()
            importedCount = 0
        } catch {
            phase = .failed("Couldn't reset import history: \(error.localizedDescription)")
        }
    }
}
