import Foundation
import Photos
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case photoLibraryAccessDenied(PHAuthorizationStatus)
    case invalidDownloadURL(itemID: String)
    case downloadFailed(itemID: String, status: Int)
    case albumCreationFailed
    case saveFailed(itemID: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .photoLibraryAccessDenied(status):
            return "Photos access is \(Self.describe(status)). Allow access in Settings → Privacy → Photos."
        case let .invalidDownloadURL(itemID):
            return "Item \(itemID) has no usable download URL."
        case let .downloadFailed(itemID, status):
            return "Download of item \(itemID) failed with HTTP \(status)."
        case .albumCreationFailed:
            return "Couldn't create the \"\(AppConfig.importedAlbumTitle)\" album."
        case let .saveFailed(itemID, underlying):
            return "Saving item \(itemID) to Photos failed: \(underlying.localizedDescription)"
        }
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .limited: return "limited to selected photos"
        case .notDetermined: return "not yet granted"
        case .authorized: return "granted"
        @unknown default: return "in an unknown state"
        }
    }
}

/// A single item that could not be imported. Surfaced in the UI (never
/// silently dropped) and logged.
struct ImportFailure: Identifiable, Equatable {
    let id: String            // media item ID
    let filename: String?
    let message: String
}

/// Live progress for the UI ("12 of 40 saved").
struct ImportProgress: Equatable {
    var total = 0
    var saved = 0
    var skippedDuplicates = 0
    var failures: [ImportFailure] = []

    var processed: Int { saved + failures.count }
    var isFinished: Bool { total > 0 && processed == total }
}

/// Downloads picked items and writes them into the iOS Photos library.
///
/// Responsibilities (PROJECT_SPEC → Flow, steps 4–6):
///   - download full-resolution bytes from `PickedMediaItem.downloadURL`
///   - save via `PHPhotoLibrary.performChanges` into a dedicated album
///   - record each success in `ImportedItemStore` so it's never re-imported
///
/// The dedup *check* (`partition`) is the caller's job, done up-front so the
/// progress total reflects only new items. See `ImportViewModel`.
///
/// TODO (needs a device + real credentials): untested end-to-end. Things to
/// verify on the first real run:
///   - `=d` / `=dv` suffixes return original bytes with the bearer header
///   - Live Photos / motion photos: the Picker API exposes them as a single
///     photo + (maybe) video; this scaffold saves whatever the item's `type`
///     says and does not attempt to pair them.
///   - HEIC items keep their type through `uniformTypeIdentifier`.
final class PhotoImporter {

    private let tokenProvider: AccessTokenProvider
    private let store: ImportedItemStore
    private let library: PHPhotoLibrary
    private let urlSession: URLSession
    private let albumTitle: String

    init(
        tokenProvider: AccessTokenProvider,
        store: ImportedItemStore,
        library: PHPhotoLibrary = .shared(),
        urlSession: URLSession = .shared,
        albumTitle: String = AppConfig.importedAlbumTitle
    ) {
        self.tokenProvider = tokenProvider
        self.store = store
        self.library = library
        self.urlSession = urlSession
        self.albumTitle = albumTitle
    }

    // MARK: Authorization

    /// Requests read/write Photos access (needed to create + add to an album;
    /// add-only access can't create albums). Throws if not granted.
    func requestPhotoLibraryAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ImportError.photoLibraryAccessDenied(status)
        }
    }

    // MARK: Import

    /// Imports `items` sequentially, reporting progress after each one.
    ///
    /// Per-item failures are collected into `ImportProgress.failures` and the
    /// run continues; only setup failures (no Photos access, no album) throw.
    /// Cancelling the surrounding `Task` stops after the in-flight item.
    func importItems(
        _ items: [PickedMediaItem],
        skippedDuplicates: Int = 0,
        progress: @escaping @MainActor (ImportProgress) -> Void
    ) async throws -> ImportProgress {
        try await requestPhotoLibraryAccess()
        let album = try await ensureAlbum()

        var state = ImportProgress(total: items.count, skippedDuplicates: skippedDuplicates)
        await progress(state)

        for item in items {
            if Task.isCancelled { break }
            do {
                let fileURL = try await download(item)
                defer { try? FileManager.default.removeItem(at: fileURL) }

                let localID = try await save(fileURL: fileURL, item: item, into: album)
                try await store.markImported(item, localAssetIdentifier: localID)
                state.saved += 1
                Log.importer.info("Saved \(item.filename ?? item.id, privacy: .public) → \(localID ?? "?", privacy: .public)")
            } catch {
                let failure = ImportFailure(id: item.id, filename: item.filename, message: error.localizedDescription)
                state.failures.append(failure)
                Log.importer.error("FAILED \(item.filename ?? item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await progress(state)
        }
        return state
    }

    // MARK: Download

    /// Downloads one item to a temp file whose extension matches its MIME type.
    private func download(_ item: PickedMediaItem) async throws -> URL {
        guard let url = item.downloadURL else {
            throw ImportError.invalidDownloadURL(itemID: item.id)
        }
        let token = try await tokenProvider.freshAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await urlSession.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImportError.downloadFailed(itemID: item.id, status: status)
        }

        // Give the file a sensible name/extension: PhotoKit and the user both
        // benefit from "IMG_1234.heic" over a UUID with no extension.
        let ext = Self.fileExtension(for: item)
        let name = (item.filename.map { ($0 as NSString).deletingPathExtension } ?? item.id) + "." + ext
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpi-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func fileExtension(for item: PickedMediaItem) -> String {
        if let mime = item.mimeType, let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        if let filename = item.filename {
            let ext = (filename as NSString).pathExtension
            if !ext.isEmpty { return ext }
        }
        return item.isVideo ? "mp4" : "jpg"
    }

    // MARK: Photos library

    /// Saves the file as a new asset and adds it to `album` in one change block.
    /// Returns the new asset's local identifier.
    private func save(fileURL: URL, item: PickedMediaItem, into album: PHAssetCollection) async throws -> String? {
        let resourceType: PHAssetResourceType = item.isVideo ? .video : .photo
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = true          // avoids a second copy of large videos
        options.originalFilename = item.filename
        if let mime = item.mimeType, let type = UTType(mimeType: mime) {
            options.uniformTypeIdentifier = type.identifier
        }

        var placeholderID: String?
        do {
            try await library.performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: resourceType, fileURL: fileURL, options: options)
                if let placeholder = creation.placeholderForCreatedAsset {
                    placeholderID = placeholder.localIdentifier
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw ImportError.saveFailed(itemID: item.id, underlying: error)
        }
        return placeholderID
    }

    /// Finds or creates the dedicated destination album.
    private func ensureAlbum() async throws -> PHAssetCollection {
        if let existing = fetchAlbum() { return existing }

        var placeholderID: String?
        try await library.performChanges { [albumTitle = self.albumTitle] in
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }

        if let placeholderID,
           let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject {
            Log.importer.info("Created album \"\(self.albumTitle, privacy: .public)\"")
            return created
        }
        if let existing = fetchAlbum() { return existing }
        throw ImportError.albumCreationFailed
    }

    private func fetchAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }
}
