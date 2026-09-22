import Foundation
import FileProvider

@main
enum PinRequestTests {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-pin-tests-\(UUID().uuidString)")
        setenv("CLOUDREVE_FP_STATE_ROOT", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let requests = temporary.appendingPathComponent("pin-requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let drive = DriveConfig(id: "test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(refresh_token: ""))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "Test")
        // Migration must never execute a historical destructive command.
        let migrationDB = try FileProviderStateDatabase(root: temporary)
        try migrationDB.put("fp-reset", "test.marker", Data("historical reset".utf8))
        try JSONEncoder().encode(["cloudreve://my/Preserved"]).write(to: temporary.appendingPathComponent("pinned-test.json"))
        let store = RemoteStore(drive: drive, domain: domain,
            stateDirectory: temporary, pinRequestDirectory: requests)
        precondition(store.isPinned(NSFileProviderItemIdentifier("cloudreve://my/Preserved")), "Import must preserve existing pins")
        let recovered = MaterializedStateRecovery.reconstruct([
            .init(identifier: "child", parent: "parent", name: "a b.pdf", explicitlyPinned: false),
            .init(identifier: "parent", parent: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Folder", explicitlyPinned: true),
        ], root: "cloudreve://my", existing: [:])
        precondition(recovered.identities["child"] == "cloudreve://my/Folder/a b.pdf")
        precondition(recovered.pins == ["parent"], "Inherited pins must not become explicit selections")
        let policyRecovery = MaterializedStateRecovery.reconstruct([
            .init(identifier: "child", parent: "parent", name: "a.pdf", explicitlyPinned: false, effectivelyPinned: true),
            .init(identifier: "parent", parent: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "Folder", explicitlyPinned: false, effectivelyPinned: true),
        ], root: "cloudreve://my", existing: [:])
        precondition(policyRecovery.pins == ["parent"], "Missing userInfo must recover policy roots, not every child")
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
        let database = try FileProviderStateDatabase(root: temporary)
        let consumed = try database.get("pin-requests", "request.json")
        precondition(consumed == nil)
        let persisted = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: temporary.appendingPathComponent("pinned-test.json")))
        precondition(!persisted.contains(folder.rawValue))
        precondition(persisted.contains(child.rawValue))
        // Exercise actual Finder replay, including folders never presented.
        try database.execute("INSERT INTO fp_event_heads VALUES('test',253,0,1)")
        try database.transaction {
            for index in 1...253 {
                let event = RemoteStore.FpEvent(ts: Int64(index), type: "create",
                    from: "/Unvisited/Deep/\(index).af", to: nil, localEcho: false)
                let payload = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
                try database.execute("INSERT INTO fp_events VALUES('test',?,?)", [String(index), payload])
            }
        }
        var anchor = Data("evt-0".utf8)
        var delivered: [Int64] = []
        var sizes: [Int] = []
        while true {
            let (events, next, more) = try store.changes(since: anchor, for: .workingSet)
            delivered += events.map(\.ts)
            sizes.append(events.count)
            anchor = next.rawValue
            if !more { break }
        }
        precondition(sizes == [100, 100, 53])
        precondition(delivered == Array(1...253).map(Int64.init))
        try database.execute("UPDATE fp_event_heads SET floor=100 WHERE drive='test'")
        do {
            _ = try store.changes(since: Data("evt-99".utf8), for: .workingSet)
            preconditionFailure("An expired anchor must trigger reconciliation")
        } catch let error as NSFileProviderError { precondition(error.code == .syncAnchorExpired) }
        try database.execute("DROP TABLE fp_events")
        do {
            _ = try store.changes(since: anchor, for: .workingSet)
            preconditionFailure("A database failure must not acknowledge unread events")
        } catch {}
        print("PinRequestTests: all tests passed")
    }
}
