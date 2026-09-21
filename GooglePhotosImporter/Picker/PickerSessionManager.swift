import Foundation

enum PickerError: LocalizedError {
    case http(status: Int, body: String)
    case invalidPickerURL
    case selectionTimedOut
    case cancelled
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            return "Google Photos Picker API returned HTTP \(status). \(body.prefix(300))"
        case .invalidPickerURL:
            return "The picker session didn't include a usable picker URL."
        case .selectionTimedOut:
            return "Timed out waiting for you to finish picking photos. Tap Import to start again."
        case .cancelled:
            return "Import cancelled."
        case let .decoding(error):
            return "Couldn't read the Picker API response: \(error.localizedDescription)"
        case let .transport(error):
            return "Network error talking to Google Photos: \(error.localizedDescription)"
        }
    }
}

/// Creates and polls Google Photos Picker API sessions.
///
/// Flow (see PROJECT_SPEC.md → Flow, steps 2–4):
///   1. `createSession()`   → POST /v1/sessions
///   2. app opens `session.pickerURL` in the browser / Google Photos app
///   3. `waitForSelection()` → GET /v1/sessions/{id} until `mediaItemsSet`
///   4. `listMediaItems()`  → GET /v1/mediaItems?sessionId=… (paginated)
///   5. `deleteSession()`   → DELETE /v1/sessions/{id} (tidy-up, best effort)
///
/// This type is UI-agnostic: it only needs an `AccessTokenProvider` and a
/// `URLSession`. Inject a stub session in tests.
///
/// TODO (needs real credentials): none of these calls have been exercised
/// against Google yet — the sandbox that wrote this file has no OAuth client.
/// The first on-device run should confirm the JSON shapes in PickerModels.swift
/// match what the API actually returns.
final class PickerSessionManager {

    private let tokenProvider: AccessTokenProvider
    private let urlSession: URLSession
    private let baseURL: URL
    private let sleep: (TimeInterval) async throws -> Void
    private let decoder = JSONDecoder()

    /// `sleep` is the wait between polls; tests inject a no-op so they don't
    /// spend real seconds. It must throw `CancellationError` when cancelled.
    init(
        tokenProvider: AccessTokenProvider,
        urlSession: URLSession = .shared,
        baseURL: URL = AppConfig.pickerAPIBaseURL,
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
        self.baseURL = baseURL
        self.sleep = sleep
    }

    // MARK: Sessions

    /// Starts a new picker session. The returned `pickerUri` is what the user
    /// must open to make their selection.
    func createSession() async throws -> PickerSession {
        // An empty JSON body is valid; `pickingConfig` (e.g. maxItemCount)
        // could be added here later.
        let session: PickerSession = try await request(method: "POST", path: "sessions", body: Data("{}".utf8))
        Log.picker.info("Created picker session \(session.id, privacy: .public)")
        return session
    }

    func getSession(id: String) async throws -> PickerSession {
        try await request(method: "GET", path: "sessions/\(id)")
    }

    /// Best-effort cleanup once items are downloaded. Failures are logged, not thrown.
    func deleteSession(id: String) async {
        do {
            let _: EmptyResponse = try await request(method: "DELETE", path: "sessions/\(id)")
            Log.picker.info("Deleted picker session \(id, privacy: .public)")
        } catch {
            Log.picker.warning("Couldn't delete picker session \(id, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Polls the session until the user confirms a selection.
    ///
    /// Respects the server's `pollingConfig` (interval + overall timeout) and
    /// falls back to `AppConfig` defaults if absent. Cooperatively cancellable:
    /// cancelling the surrounding `Task` throws `PickerError.cancelled`.
    ///
    /// Note on backgrounding: while the user is in the picker, this app is in
    /// the background and iOS may suspend it. The loop simply resumes when the
    /// app comes back to the foreground, so the first poll after returning is
    /// what usually observes `mediaItemsSet == true`.
    func waitForSelection(
        _ initial: PickerSession,
        onPoll: ((PickerSession) -> Void)? = nil
    ) async throws -> PickerSession {
        let interval = initial.pollingConfig?.pollIntervalSeconds ?? AppConfig.defaultPollInterval
        let timeout = initial.pollingConfig?.timeoutSeconds ?? AppConfig.defaultPickerTimeout
        let deadline = Date().addingTimeInterval(timeout)

        var current = initial
        while !current.hasSelection {
            if Task.isCancelled { throw PickerError.cancelled }
            if Date() >= deadline { throw PickerError.selectionTimedOut }

            try await sleep(max(1, interval))
            current = try await getSession(id: initial.id)
            onPoll?(current)
            Log.picker.debug("Polled session \(current.id, privacy: .public): mediaItemsSet=\(current.hasSelection)")
        }
        return current
    }

    // MARK: Media items

    /// Fetches every selected item, following `nextPageToken` until exhausted.
    func listMediaItems(sessionID: String, pageSize: Int = 100) async throws -> [PickedMediaItem] {
        var items: [PickedMediaItem] = []
        var pageToken: String?

        repeat {
            var query = [
                URLQueryItem(name: "sessionId", value: sessionID),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
            ]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: PickedMediaItemsPage = try await request(method: "GET", path: "mediaItems", query: query)
            items.append(contentsOf: page.mediaItems ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil

        Log.picker.info("Session \(sessionID, privacy: .public) has \(items.count) selected item(s)")
        return items
    }

    // MARK: Plumbing

    private struct EmptyResponse: Decodable {}

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token = try await tokenProvider.freshAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // A cancelled Task surfaces here as URLError.cancelled; report it
            // as a cancellation, not a network failure.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw PickerError.cancelled
            }
            throw PickerError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            Log.picker.error("\(method, privacy: .public) \(path, privacy: .public) → HTTP \(status): \(bodyText, privacy: .public)")
            throw PickerError.http(status: status, body: bodyText)
        }

        // DELETE returns an empty body; decode `{}` in that case.
        let payload = data.isEmpty ? Data("{}".utf8) : data
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw PickerError.decoding(error)
        }
    }
}
