import OSLog

/// Central loggers. View them in Console.app / Xcode's console filtered by the
/// subsystem. Skipped or failed items are always logged here so nothing quietly
/// disappears (CLAUDE.md → Conventions).
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "GooglePhotosImporter"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let picker = Logger(subsystem: subsystem, category: "picker")
    static let importer = Logger(subsystem: subsystem, category: "importer")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
