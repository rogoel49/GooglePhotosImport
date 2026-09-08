import XCTest
@testable import GooglePhotosImporter

/// Pure-logic tests for the dedup ledger. No Google or Photos access needed,
/// so these run in the Simulator without any credentials.
final class ImportedItemStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedItemStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("imported-items.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func item(_ id: String, filename: String? = nil, video: Bool = false) -> PickedMediaItem {
        PickedMediaItem(
            id: id,
            createTime: nil,
            type: video ? "VIDEO" : "PHOTO",
            mediaFile: MediaFile(baseUrl: "https://example.com/\(id)", mimeType: nil, filename: filename, mediaFileMetadata: nil)
        )
    }

    func testEmptyStoreContainsNothing() async {
        let store = ImportedItemStore(fileURL: fileURL)
        let contains = await store.contains("a")
        let count = await store.count
        XCTAssertFalse(contains)
        XCTAssertEqual(count, 0)
    }

    func testMarkImportedPersistsAcrossInstances() async throws {
        let store = ImportedItemStore(fileURL: fileURL)
        try await store.markImported(item("a", filename: "IMG_1.jpg"), localAssetIdentifier: "asset-1")

        let reloaded = ImportedItemStore(fileURL: fileURL)
        let contains = await reloaded.contains("a")
        let record = await reloaded.record(for: "a")
        XCTAssertTrue(contains)
        XCTAssertEqual(record?.filename, "IMG_1.jpg")
        XCTAssertEqual(record?.localAssetIdentifier, "asset-1")
    }

    func testPartitionSplitsNewFromDuplicatesPreservingOrder() async throws {
        let store = ImportedItemStore(fileURL: fileURL)
        try await store.markImported(item("b"), localAssetIdentifier: nil)

        let (new, duplicates) = await store.partition([item("a"), item("b"), item("c")])
        XCTAssertEqual(new.map(\.id), ["a", "c"])
        XCTAssertEqual(duplicates.map(\.id), ["b"])
    }

    func testRemoveAllClearsLedger() async throws {
        let store = ImportedItemStore(fileURL: fileURL)
        try await store.markImported(item("a"), localAssetIdentifier: nil)
        try await store.removeAll()
        let count = await ImportedItemStore(fileURL: fileURL).count
        XCTAssertEqual(count, 0)
    }

    func testDownloadURLSuffixes() {
        XCTAssertEqual(item("p").downloadURL?.absoluteString, "https://example.com/p=d")
        XCTAssertEqual(item("v", video: true).downloadURL?.absoluteString, "https://example.com/v=dv")
    }

    func testPollingConfigDurationParsing() {
        XCTAssertEqual(PollingConfig.seconds(from: "5s"), 5)
        XCTAssertEqual(PollingConfig.seconds(from: "1.500s"), 1.5)
        XCTAssertNil(PollingConfig.seconds(from: "5"))
        XCTAssertNil(PollingConfig.seconds(from: nil))
    }
}
