import Foundation

/// The T-20's settings as saved on this Mac. The mouse keeps none of them, so they are sent again after each
/// plug-in.
public struct T20Store: Sendable {
    public static var standardFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ZelotesMac/t20.json")
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Returns `nil` when nothing has been saved yet, and also when the saved file cannot be used.
    public func load() -> T20Settings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(T20Settings.self, from: data)
    }

    public func save(_ settings: T20Settings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(settings).write(to: fileURL, options: .atomic)
    }
}
