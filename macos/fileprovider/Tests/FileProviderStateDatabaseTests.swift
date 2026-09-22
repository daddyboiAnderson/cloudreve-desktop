import Foundation

@main
enum FileProviderStateDatabaseTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-state-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("pin-requests")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("request.json"))
        let db = try FileProviderStateDatabase(root: root)
        let imported = try db.get("pin-requests", "request.json")
        precondition(imported == Data("old".utf8))
        try db.remove("pin-requests", "request.json")
        let reopened = try FileProviderStateDatabase(root: root)
        let absent = try reopened.get("pin-requests", "request.json")
        precondition(absent == nil, "Consumed legacy state must not reappear")
        enum Failure: Error { case simulated }
        do {
            try db.transaction {
                try db.execute("INSERT INTO fp_records VALUES('test','rollback','value')")
                throw Failure.simulated
            }
        } catch Failure.simulated {}
        let rolledBack = try db.rows("SELECT key FROM fp_records WHERE namespace='test'")
        precondition(rolledBack.isEmpty)

        try db.execute("INSERT INTO fp_event_heads VALUES('drive',300,100,1)")
        try db.execute("INSERT INTO fp_events VALUES('drive',200,'second'),('drive',300,'third')")
        let snapshot = try db.eventSnapshot(drive: "drive", since: 200)
        precondition(snapshot.latest == 300 && snapshot.floor == 100)
        precondition(snapshot.events == [Data("third".utf8)])
        do {
            _ = try db.eventSnapshot(drive: "missing", since: 0)
            preconditionFailure("An uninitialized journal must not look empty")
        } catch {}

        if let fixture = ProcessInfo.processInfo.environment["CLOUDREVE_FP_TEST_FIXTURE"] {
            let swiftCreated = try FileProviderStateDatabase(root: URL(fileURLWithPath: fixture).appendingPathComponent("swift-created"))
            try swiftCreated.put("interop", "swift", Data("Swift wrote this".utf8))
            let shared = try FileProviderStateDatabase(root: URL(fileURLWithPath: fixture))
            let text = try shared.get("interop", "rust")
            precondition(text == Data("Unicode: 你好; 'quotes'".utf8))
            let events = try shared.eventSnapshot(drive: "interop", since: 0)
            precondition(events.events.count == 1)
            let object = try JSONSerialization.jsonObject(with: events.events[0]) as! [String: Any]
            precondition(object["from"] as? String == "/Folder/你好 'quoted'.af")
            try shared.put("interop", "swift", Data("Swift wrote this".utf8))
        }
        print("FileProviderStateDatabaseTests: all tests passed")
    }
}
