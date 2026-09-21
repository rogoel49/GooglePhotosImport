import XCTest
@testable import GooglePhotosImporter

/// Exercises `PickerSessionManager` against canned Picker API responses.
/// No network or credentials: requests are intercepted by `StubURLProtocol`.
final class PickerSessionManagerTests: XCTestCase {

    private let baseURL = URL(string: "https://picker.test/v1")!
    private var sleeps: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        sleeps = []
    }

    private func makeManager(token: String? = "test-token") -> PickerSessionManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PickerSessionManager(
            tokenProvider: StubAccessTokenProvider(token: token),
            urlSession: URLSession(configuration: configuration),
            baseURL: baseURL,
            sleep: { [unowned self] seconds in self.sleeps.append(seconds) }
        )
    }

    private func sessionJSON(mediaItemsSet: Bool, timeoutIn: String = "1800s") -> String {
        """
        {
          "id": "session-1",
          "pickerUri": "https://photos.google.com/picker/session-1",
          "pollingConfig": { "pollInterval": "5s", "timeoutIn": "\(timeoutIn)" },
          "expireTime": "2026-01-01T00:00:00Z",
          "mediaItemsSet": \(mediaItemsSet)
        }
        """
    }

    private func mediaItemJSON(id: String, type: String = "PHOTO") -> String {
        """
        {
          "id": "\(id)",
          "createTime": "2025-06-01T12:00:00Z",
          "type": "\(type)",
          "mediaFile": {
            "baseUrl": "https://lh3.googleusercontent.com/\(id)",
            "mimeType": "\(type == "VIDEO" ? "video/mp4" : "image/heic")",
            "filename": "\(id).\(type == "VIDEO" ? "mp4" : "heic")",
            "mediaFileMetadata": {
              "width": 4032,
              "height": 3024,
              "cameraMake": "Apple",
              "cameraModel": "iPhone 15",
              "photoMetadata": { "focalLength": 5.1, "isoEquivalent": 64 }
            }
          }
        }
        """
    }

    // MARK: Sessions

    func testCreateSessionPostsWithBearerTokenAndDecodes() async throws {
        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: false))

        let session = try await makeManager().createSession()

        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.pickerURL?.absoluteString, "https://photos.google.com/picker/session-1")
        XCTAssertEqual(session.pollingConfig?.pollIntervalSeconds, 5)
        XCTAssertEqual(session.pollingConfig?.timeoutSeconds, 1800)
        XCTAssertFalse(session.hasSelection)

        let request = StubURLProtocol.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://picker.test/v1/sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testWaitForSelectionPollsUntilMediaItemsSet() async throws {
        let manager = makeManager()
        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: false))
        let initial = try await manager.createSession()

        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: false))
        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: true))
        var polled = 0
        let ready = try await manager.waitForSelection(initial) { _ in polled += 1 }

        XCTAssertTrue(ready.hasSelection)
        XCTAssertEqual(polled, 2)
        XCTAssertEqual(sleeps, [5, 5])
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(StubURLProtocol.requests[2].httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.requests[2].url?.absoluteString, "https://picker.test/v1/sessions/session-1")
    }

    func testWaitForSelectionReturnsImmediatelyWhenAlreadySet() async throws {
        let manager = makeManager()
        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: true))
        let initial = try await manager.createSession()

        let ready = try await manager.waitForSelection(initial)

        XCTAssertTrue(ready.hasSelection)
        XCTAssertEqual(sleeps, [])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testWaitForSelectionTimesOut() async throws {
        let manager = makeManager()
        StubURLProtocol.enqueue(status: 200, body: sessionJSON(mediaItemsSet: false, timeoutIn: "0s"))
        let initial = try await manager.createSession()

        do {
            _ = try await manager.waitForSelection(initial)
            XCTFail("Expected selectionTimedOut")
        } catch PickerError.selectionTimedOut {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteSessionToleratesEmptyBody() async {
        StubURLProtocol.enqueue(status: 200, body: "")

        await makeManager().deleteSession(id: "session-1")

        XCTAssertEqual(StubURLProtocol.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests[0].url?.absoluteString, "https://picker.test/v1/sessions/session-1")
    }

    // MARK: Media items

    func testListMediaItemsFollowsPagination() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        { "mediaItems": [\(mediaItemJSON(id: "a")), \(mediaItemJSON(id: "b", type: "VIDEO"))], "nextPageToken": "page-2" }
        """)
        StubURLProtocol.enqueue(status: 200, body: """
        { "mediaItems": [\(mediaItemJSON(id: "c"))] }
        """)

        let items = try await makeManager().listMediaItems(sessionID: "session-1")

        XCTAssertEqual(items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(items[0].mimeType, "image/heic")
        XCTAssertEqual(items[0].filename, "a.heic")
        XCTAssertEqual(items[0].mediaFile.mediaFileMetadata?.width, 4032)
        XCTAssertEqual(items[0].downloadURL?.absoluteString, "https://lh3.googleusercontent.com/a=d")
        XCTAssertTrue(items[1].isVideo)
        XCTAssertEqual(items[1].downloadURL?.absoluteString, "https://lh3.googleusercontent.com/b=dv")

        let first = URLComponents(url: StubURLProtocol.requests[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(first.path, "/v1/mediaItems")
        XCTAssertEqual(first.queryItems?.first { $0.name == "sessionId" }?.value, "session-1")
        XCTAssertNil(first.queryItems?.first { $0.name == "pageToken" })
        let second = URLComponents(url: StubURLProtocol.requests[1].url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(second.queryItems?.first { $0.name == "pageToken" }?.value, "page-2")
    }

    func testListMediaItemsHandlesEmptySelection() async throws {
        StubURLProtocol.enqueue(status: 200, body: "{}")

        let items = try await makeManager().listMediaItems(sessionID: "session-1")

        XCTAssertEqual(items.count, 0)
    }

    // MARK: Errors

    func testHTTPErrorCarriesStatusAndBody() async {
        StubURLProtocol.enqueue(status: 403, body: #"{"error":{"status":"PERMISSION_DENIED"}}"#)

        do {
            _ = try await makeManager().createSession()
            XCTFail("Expected an HTTP error")
        } catch let PickerError.http(status, body) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.contains("PERMISSION_DENIED"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedResponseIsADecodingError() async {
        StubURLProtocol.enqueue(status: 200, body: #"{"unexpected":true}"#)

        do {
            _ = try await makeManager().createSession()
            XCTFail("Expected a decoding error")
        } catch PickerError.decoding {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSignedOutFailsBeforeAnyRequest() async {
        do {
            _ = try await makeManager(token: nil).createSession()
            XCTFail("Expected notSignedIn")
        } catch AuthError.notSignedIn {
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

/// Serves queued responses in order and records every request it sees.
final class StubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var queue: [(status: Int, body: Data)] = []
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        recorded = []
    }

    static func enqueue(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append((status, Data(body.utf8)))
    }

    private static func next(for request: URLRequest) -> (status: Int, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.next(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
