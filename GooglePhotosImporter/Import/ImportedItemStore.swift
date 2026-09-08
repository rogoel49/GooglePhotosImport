import Foundation

/// One line of the dedup ledger.
struct ImportedItemRecord: Codable, Equatable {
    let mediaItemID: String
    let filename: String?
    let importedAt: Date
    /// `PHAsset.localIdentifier` of the saved asset, when known. Lets a future
    /// "show in Photos" feature find it.
    let localAssetIdentifier: String?
}

/// Persistent set of Google media-item IDs that have already been saved to the
/// iOS Photos library. Checked on every import run before writing anything,
/// so re-picking an album never creates duplicate camera-roll entries
/// (CLAUDE.md → Conventions; PROJECT_SPEC → Flow step 6).
///
/// Storage: a single JSON file in Application Support. An actor so concurrent
/// download tasks can't interleave writes.
actor ImportedItemStore {

    private let fileURL: URL
    private var records: [String: ImportedItemRecord] = [:]
    private var loaded = false

    /// Default location: `<Application Support>/imported-items.json`.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support.appendingPathComponent("imported-items.json")
        }
    }

    // MARK: Queries

    func contains(_ mediaItemID: String) -> Bool {
        loadIfNeeded()
        return records[mediaItemID] != nil
    }

    func record(for mediaItemID: String) -> ImportedItemRecord? {
        loadIfNeeded()
        return records[mediaItemID]
    }

    var count: Int {
        loadIfNeeded()
        return records.count
    }

    /// Splits `items` into (new, alreadyImported) preserving order.
    func partition(_ items: [PickedMediaItem]) -> (new: [PickedMediaItem], duplicates: [PickedMediaItem]) {
        loadIfNeeded()
        var new: [PickedMediaItem] = []
        var duplicates: [PickedMediaItem] = []
        for item in items {
            if records[item.id] != nil { duplicates.append(item) } else { new.append(item) }
        }
        return (new, duplicates)
    }

    // MARK: Mutations

    func markImported(_ item: PickedMediaItem, localAssetIdentifier: String?) throws {
        loadIfNeeded()
        records[item.id] = ImportedItemRecord(
            mediaItemID: item.id,
            filename: item.filename,
            importedAt: Date(),
            localAssetIdentifier: localAssetIdentifier
        )
        try persist()
    }

    /// Wipes the ledger. Only exposed for a "Reset dedup history" debug action.
    func removeAll() throws {
        records = [:]
        loaded = true
        try persist()
    }

    // MARK: Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let list = try Self.decoder.decode([ImportedItemRecord].self, from: data)
            records = Dictionary(uniqueKeysWithValues: list.map { ($0.mediaItemID, $0) })
        } catch {
            // A corrupt ledger must not silently become "everything is new":
            // log loudly and keep going with an empty set.
            Log.importer.error("Dedup ledger at \(self.fileURL.path, privacy: .public) is unreadable: \(error.localizedDescription). Starting empty.")
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let list = records.values.sorted { $0.importedAt < $1.importedAt }
        let data = try Self.encoder.encode(list)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
