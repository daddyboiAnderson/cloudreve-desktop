import Foundation

@main
struct ReimportContentTests {
    static func main() async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-reimport-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("original".utf8).write(to: local)
        var downloaded: URL?
        let identical = try await ReimportContent.matches(local: local, remoteSize: 8) { destination in
            downloaded = destination
            try Data("original".utf8).write(to: destination)
        }
        precondition(identical)
        precondition(!FileManager.default.fileExists(atPath: downloaded!.path))

        let changed = try await ReimportContent.matches(local: local, remoteSize: 8) { destination in
            try Data("modified".utf8).write(to: destination)
        }
        precondition(!changed)
        let preserved = try Data(contentsOf: local)
        precondition(preserved == Data("original".utf8))

        let wrongSize = try await ReimportContent.matches(local: local, remoteSize: 9) { _ in
            preconditionFailure("Different sizes should not require a download")
        }
        precondition(!wrongSize)

        do {
            _ = try await ReimportContent.matches(local: local, remoteSize: 8) { destination in
                downloaded = destination
                try Data("partial".utf8).write(to: destination)
                throw CocoaError(.fileReadNoPermission)
            }
            preconditionFailure("Failed comparisons must not acknowledge the reimport")
        } catch let error as CocoaError {
            precondition(error.code == .fileReadNoPermission)
            precondition(!FileManager.default.fileExists(atPath: downloaded!.path))
        }
        print("ReimportContentTests: all tests passed")
    }
}
