import Foundation

// Wire models for the Google Photos Picker API (v1).
// Reference: https://developers.google.com/photos/picker/reference/rest
//
// Only the fields this app reads are declared; `JSONDecoder` ignores the rest.
// Field names match the JSON exactly so no CodingKeys are needed.

/// `photospicker.googleapis.com/v1/sessions` resource.
struct PickerSession: Decodable, Equatable {
    let id: String
    /// URL to send the user to so they can pick items in Google's UI.
    let pickerUri: String
    let pollingConfig: PollingConfig?
    /// RFC 3339 timestamp after which the session (and its media items) is gone.
    let expireTime: String?
    /// Becomes `true` once the user has confirmed a selection in the picker.
    let mediaItemsSet: Bool?

    var pickerURL: URL? { URL(string: pickerUri) }
    var hasSelection: Bool { mediaItemsSet ?? false }
}

/// Server-recommended polling cadence. Both values are protobuf `Duration`
/// strings such as `"5s"` or `"1.500s"`.
struct PollingConfig: Decodable, Equatable {
    let pollInterval: String?
    let timeoutIn: String?

    var pollIntervalSeconds: TimeInterval? { Self.seconds(from: pollInterval) }
    var timeoutSeconds: TimeInterval? { Self.seconds(from: timeoutIn) }

    /// Parses `"5s"` / `"1.5s"` → seconds. Returns nil for anything else.
    static func seconds(from duration: String?) -> TimeInterval? {
        guard var text = duration, text.hasSuffix("s") else { return nil }
        text.removeLast()
        return TimeInterval(text)
    }
}

/// One page of `GET /v1/mediaItems?sessionId=…`.
struct PickedMediaItemsPage: Decodable {
    let mediaItems: [PickedMediaItem]?
    let nextPageToken: String?
}

/// A media item the user selected in the picker.
struct PickedMediaItem: Decodable, Identifiable, Equatable {
    let id: String
    let createTime: String?
    /// `"PHOTO"`, `"VIDEO"`, or `"TYPE_UNSPECIFIED"`.
    let type: String?
    let mediaFile: MediaFile

    var isVideo: Bool { type == "VIDEO" }
    var filename: String? { mediaFile.filename }
    var mimeType: String? { mediaFile.mimeType }

    /// Full-resolution download URL.
    ///
    /// Per the Picker docs, `baseUrl` must be suffixed with size parameters:
    ///   - `=d`  → original photo bytes (keeps EXIF)
    ///   - `=dv` → original video bytes
    /// Requests to this URL need the same `Authorization: Bearer` header as
    /// the API. Base URLs expire (~60 min), so download soon after listing.
    var downloadURL: URL? {
        URL(string: mediaFile.baseUrl + (isVideo ? "=dv" : "=d"))
    }
}

struct MediaFile: Decodable, Equatable {
    let baseUrl: String
    let mimeType: String?
    let filename: String?
    let mediaFileMetadata: MediaFileMetadata?
}

struct MediaFileMetadata: Decodable, Equatable {
    let width: Int?
    let height: Int?
    let cameraMake: String?
    let cameraModel: String?
}
