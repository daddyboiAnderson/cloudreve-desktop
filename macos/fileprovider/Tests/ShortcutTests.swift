import Foundation

private final class MockProtocol: URLProtocol {
    static var requests: [(String, String)] = []
    static var denyShare = false
    static var bodies: [[String: Any]] = []
    static var contentVersion = "target-version-1"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let endpoint = url.path.replacingOccurrences(of: "/api/v4", with: "")
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        Self.bodies.append(body)
        let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems?.first { $0.name == "uri" }?.value ?? body["uri"] as? String ?? ""
        Self.requests.append((endpoint, uri))
        let name = uri.components(separatedBy: "/").last ?? ""
        var file: [String: Any] = [
            "type": 1, "id": "same-remote-id", "name": name,
            "path": uri, "size": 0,
        ]
        if uri == "cloudreve://my/Test Delt Mappe" || uri == "cloudreve://my/Second" {
            file["metadata"] = ["sys:shared_redirect": "cloudreve://share-id@shared_with_me/"]
        }
        if uri == "cloudreve://my/file-shortcut.txt" {
            file["type"] = 0
            file["id"] = "shortcut-id"
            file["primary_entity"] = "shortcut-version"
            file["metadata"] = ["sys:shared_redirect": "cloudreve://file-share@shared_with_me/"]
        }
        if uri == "cloudreve://file-share@shared_with_me" {
            file["type"] = 0
            file["id"] = "target-id"
            file["size"] = 123
            file["primary_entity"] = Self.contentVersion
        }
        let payload: [String: Any]
        if Self.denyShare && uri.contains("@shared_with_me") {
            payload = ["code": 403, "msg": "Access denied"]
        } else if endpoint == "/file" {
            file["name"] = "child.txt"
            file["path"] = "cloudreve://share-id@shared_with_me/child.txt"
            file["type"] = 0
            payload = ["code": 0, "data": ["files": [file], "pagination": ["next_token": "page2"]]]
        } else {
            payload = ["code": 0, "data": file]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ShortcutTests {
    static func main() async throws {
        let receivedMetadata = Data("""
            {"type":1,"id":"shortcut","name":"Test Delt Mappe","path":"cloudreve://my/Test Delt Mappe",
             "size":0,"owned":true,"metadata":{"sys:shared_owner":"other-user","sys:shared_redirect":"cloudreve://share@shared_with_me/"}}
            """.utf8)
        let receivedFile = try JSONDecoder().decode(RemoteFile.self, from: receivedMetadata)
        precondition(receivedFile.isSharedWithMe(currentUserID: "me"))
        precondition(!receivedFile.isSharedWithMe(currentUserID: "other-user"))
        let descendant = RemoteFile(type: 0, id: "child", name: "file.txt",
            path: "cloudreve://share@shared_with_me/file.txt", size: 1,
            created_at: nil, updated_at: nil, metadata: nil, shared: false,
            owned: false, primary_entity: nil)
            .presented(at: "cloudreve://my/Test Delt Mappe/file.txt")
        precondition(descendant.isSharedWithMe(currentUserID: "me"))
        let shortcut = "cloudreve://my/Test Delt Mappe"
        let target = "cloudreve://share-id@shared_with_me"
        let links = [shortcut: target + "/", target + "/nested": "cloudreve://other@shared_with_me/"]
        func resolve(_ uri: String, _ follow: Bool) async throws -> String {
            try await ShortcutResolver.resolve(uri, followLeaf: follow) { links[$0] }
        }
        let folder = try await resolve(shortcut, true)
        precondition(folder == target)
        let child = try await resolve(shortcut + "/sub/file.txt", false)
        precondition(child == target + "/sub/file.txt")
        let nested = try await resolve(shortcut + "/nested/file.txt", true)
        precondition(nested == "cloudreve://other@shared_with_me/file.txt")
        let shortcutMutation = try await resolve(shortcut, false)
        precondition(shortcutMutation == shortcut)
        let sibling = try await resolve(shortcut + " extra/file.txt", false)
        precondition(sibling == shortcut + " extra/file.txt")
        let ordinary = try await resolve("cloudreve://my/ordinary/file.txt", true)
        precondition(ordinary == "cloudreve://my/ordinary/file.txt")
        do {
            _ = try await ShortcutResolver.resolve(shortcut, followLeaf: true) { _ in shortcut }
            preconditionFailure("Cycle must fail")
        } catch CloudreveError.badResponse { }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = CloudreveClient(drive: DriveConfig(
            id: "test", name: "test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test",
                access_expires: "2099-01-01T00:00:00Z")), session: URLSession(configuration: config))
        let result = try await client.listDirectory(uri: shortcut, page: "t:page1")
        let individual = try await client.fileInfoWithShareState(uri: "cloudreve://my/file-shortcut.txt")
        precondition(individual.id == "shortcut-id")
        precondition(individual.path == "cloudreve://my/file-shortcut.txt")
        precondition(individual.name == "file-shortcut.txt")
        precondition(individual.size == 123)
        precondition(individual.primary_entity == "target-version-1")
        MockProtocol.contentVersion = "target-version-2"
        let restored = try await client.fileInfoWithShareState(uri: individual.path)
        precondition(restored.primary_entity == "target-version-2")
        precondition(restored.id == individual.id)
        precondition(result.nextPage == "t:page2")
        precondition(result.files[0].path == shortcut + "/child.txt")
        precondition(result.files[0].presentationIdentity == shortcut + "/child.txt")
        precondition(MockProtocol.requests.contains { $0 == "/file" && $1 == target })
        let second = try await client.listDirectory(uri: "cloudreve://my/Second", page: nil)
        precondition(second.files[0].id == result.files[0].id)
        precondition(second.files[0].presentationIdentity != result.files[0].presentationIdentity)
        let refreshed = try await client.fileInfoWithShareState(uri: shortcut + "/child.txt")
        precondition(refreshed.path == shortcut + "/child.txt")
        precondition(refreshed.presentationIdentity == result.files[0].presentationIdentity)
        _ = try await client.createFileOrFolder(uri: shortcut + "/new folder", isFolder: true)
        precondition(MockProtocol.bodies.last?["uri"] as? String == target + "/new folder")
        precondition(!MockProtocol.requests.contains { $0 == "/file/info" && $1.hasSuffix("/new folder") })
        let renamed = try await client.renameFile(uri: shortcut + "/child.txt", to: "renamed.txt")
        precondition(MockProtocol.bodies.last?["uri"] as? String == target + "/child.txt")
        precondition(renamed.path == shortcut + "/renamed.txt")
        try await client.deleteFile(uri: shortcut)
        precondition(MockProtocol.bodies.last?["uris"] as? [String] == [shortcut])
        try await client.deleteFile(uri: shortcut + "/child.txt")
        precondition(MockProtocol.bodies.last?["uris"] as? [String] == [target + "/child.txt"])
        try await client.moveFile(uri: "cloudreve://my/ordinary.txt", toDirectory: shortcut)
        precondition(MockProtocol.bodies.last?["dst"] as? String == target)
        MockProtocol.denyShare = true
        do {
            _ = try await client.listDirectory(uri: shortcut, page: nil)
            preconditionFailure("Permission failure must propagate")
        } catch CloudreveError.api(let code, _) { precondition(code == 403) }
        print("ShortcutTests: all tests passed")
    }
}
