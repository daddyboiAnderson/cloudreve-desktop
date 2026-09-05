import Foundation

enum ReimportContent {
    /// Compare supplied content before reconnecting a reimported file.
    static func matches(
        local: URL, remoteSize: Int64,
        download: (URL) async throws -> Void
    ) async throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == remoteSize else { return false }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-reimport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await download(temporary)
        try Task.checkCancellation()
        return FileManager.default.contentsEqual(atPath: local.path, andPath: temporary.path)
    }
}
