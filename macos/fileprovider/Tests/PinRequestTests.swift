import Foundation
import FileProvider

@main
enum PinRequestTests {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-pin-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let requests = temporary.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let drive = DriveConfig(id: "test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(refresh_token: ""))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "Test")
        let store = RemoteStore(drive: drive, domain: domain,
            stateDirectory: temporary, pinRequestDirectory: requests)
        let folder = NSFileProviderItemIdentifier("cloudreve://my/Test Folder")
        let child = NSFileProviderItemIdentifier("cloudreve://my/Test Folder/child.txt")
        store.setPinned(true, for: folder)
        store.setPinned(true, for: child)
        let request = requests.appendingPathComponent("request.json")
        try Data(#"{"drive_id":"test","uri":"cloudreve://my/Test%20Folder"}"#.utf8).write(to: request)

        // Simulate enumeration while a Finder action is awaiting its result.
        await store.withActionLock { store.applyPinRequests() }
        precondition(!store.isPinned(folder))
        precondition(store.isPinned(child))
        precondition(!FileManager.default.fileExists(atPath: request.path))
        let persisted = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: temporary.appendingPathComponent("pinned-test.json")))
        precondition(!persisted.contains(folder.rawValue))
        precondition(persisted.contains(child.rawValue))
        print("PinRequestTests: all tests passed")
    }
}
