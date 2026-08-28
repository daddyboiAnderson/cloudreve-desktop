import FileProvider
import OSLog
import UniformTypeIdentifiers

/// Maps a File Provider domain to its drive and serves items from the
/// Cloudreve API. One instance per domain, owned by FileProviderExtension.
final class RemoteStore {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "store")

    let drive: DriveConfig
    let client: CloudreveClient
    private let domain: NSFileProviderDomain

    /// itemIdentifier.rawValue -> item, filled during enumeration/info calls.
    /// The system asks for previously enumerated items by identifier; the cache
    /// answers those without extra API round-trips.
    private var cache: [String: FileProviderItem] = [:]
    /// Stable Finder identity -> current Cloudreve URI. Paths can change on
    /// rename, but NSFileProvider item identifiers must not.
    private var uriByIdentifier: [String: String] = [:]
    private var identifierByURI: [String: String] = [:]
    private let cacheLock = NSLock()

    // MARK: - Change feed (shared event log)

    /// One remote event, as recorded by the main app (JSON lines).
    /// The extension can't run a long-lived SSE listener itself (XPC services
    /// get suspended when idle), so the app writes events here and signals the
    /// working set; we replay from the file in enumerateChanges.
    struct FpEvent: Decodable {
        let ts: Int64  // unix epoch milliseconds
        let type: String  // create | modify | rename | delete
        let from: String  // path relative to drive root, leading slash
        let to: String?
    }

    private var eventsFileURL: URL {
        DriveStore.drivesURL
            .deletingLastPathComponent()
            .appendingPathComponent("fp-events/\(drive.id).jsonl")
    }

    init(drive: DriveConfig, domain: NSFileProviderDomain) {
        self.drive = drive
        self.domain = domain
        self.client = CloudreveClient(drive: drive)
        if let data = try? Data(contentsOf: identityFileURL),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            uriByIdentifier = saved
            identifierByURI = Dictionary(
                uniqueKeysWithValues: saved.map { ($0.value, $0.key) })
        }
    }

    private var identityFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CloudreveFileProvider", isDirectory: true)
            .appendingPathComponent("identities-\(drive.id).json")
    }

    func identifier(forURI uri: String) -> NSFileProviderItemIdentifier {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return NSFileProviderItemIdentifier(identifierByURI[uri] ?? uri)
    }

    private func recordIdentity(_ identifier: NSFileProviderItemIdentifier, uri: String) {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        if let previousURI = uriByIdentifier[identifier.rawValue] {
            identifierByURI.removeValue(forKey: previousURI)
        }
        uriByIdentifier[identifier.rawValue] = uri
        identifierByURI[uri] = identifier.rawValue
        let snapshot = uriByIdentifier
        cacheLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: identityFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: identityFileURL, options: .atomic)
        } catch {
            logger.error("failed to persist item identities: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readEvents() -> [FpEvent] {
        guard let data = try? Data(contentsOf: eventsFileURL),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(FpEvent.self, from: Data($0.utf8))
        }
    }

    // MARK: Anchors and change replay

    /// Anchor format: "evt-<millis>" — the timestamp of the last event known
    /// to have been delivered to the system.
    func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        let lastTs = readEvents().last?.ts ?? 0
        return NSFileProviderSyncAnchor(Data("evt-\(lastTs)".utf8))
    }

    /// Events recorded after the anchor. Throws `.syncAnchorExpired` for
    /// foreign anchors (e.g. from older builds); the system then does a full
    /// re-scan — documented as expensive but always correct.
    func changes(since anchorData: Data, for container: NSFileProviderItemIdentifier)
        throws -> ([FpEvent], NSFileProviderSyncAnchor)
    {
        guard let text = String(data: anchorData, encoding: .utf8),
            text.hasPrefix("evt-"), let since = Int64(text.dropFirst(4))
        else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let events = readEvents()
        // A rescan marker means the app lost its event stream and can't
        // vouch for the log's completeness past this anchor — force a full
        // rescan instead of replaying.
        if events.contains(where: { $0.type == "rescan" && $0.ts > since }) {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let relevant = events.filter { $0.ts > since }
        let filtered = relevant.filter { changeTouchesContainer($0, container: container) }
        let newAnchor = NSFileProviderSyncAnchor(Data("evt-\(events.last?.ts ?? since)".utf8))
        return (filtered, newAnchor)
    }

    /// Full URI for an event path (paths are relative to the drive root URI).
    func uri(forEventPath path: String) -> String {
        Self.canonicalURI(drive.remote_path + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func changeTouchesContainer(
        _ change: FpEvent, container: NSFileProviderItemIdentifier
    ) -> Bool {
        let fromURI = uri(forEventPath: change.from)
        let toURI = change.to.map { uri(forEventPath: $0) }
        // The working set gets every change; a container gets changes to
        // itself or to a direct child.
        if container == .workingSet { return true }
        if fromURI == container.rawValue || toURI == container.rawValue { return true }
        let parentOf = { (uri: String) -> NSFileProviderItemIdentifier in
            var u = uri
            if u.hasSuffix("/") { u.removeLast() }
            guard let idx = u.lastIndex(of: "/") else { return .rootContainer }
            let parent = String(u[..<idx])
            if parent == self.drive.remote_path || parent == "cloudreve://my" || parent.isEmpty {
                return .rootContainer
            }
            return NSFileProviderItemIdentifier(parent)
        }
        return parentOf(fromURI) == container || (toURI.map { parentOf($0) } == container)
    }

    /// The API URI for a container identifier.
    func uri(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return drive.remote_path
        }
        cacheLock.lock()
        let mapped = uriByIdentifier[identifier.rawValue]
        cacheLock.unlock()
        return mapped ?? Self.uri(fromPath: identifier.rawValue)
    }

    /// Files that exist locally but are never uploaded (Finder metadata).
    static func isIgnored(filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._")
    }

    /// Item identifiers are full logical paths as returned by the API.
    /// The API accepts URIs in the form "cloudreve://my<path>".
    static func uri(fromPath path: String) -> String {
        let uri =
            path.hasPrefix("cloudreve://")
            ? path
            : "cloudreve://my" + (path.hasPrefix("/") ? path : "/" + path)
        return canonicalURI(uri)
    }

    /// Cloudreve's REST responses may percent-encode paths while SSE events
    /// contain literal characters. Finder identities must use one canonical
    /// representation or the same file appears as multiple placeholders.
    static func canonicalURI(_ uri: String) -> String {
        uri.removingPercentEncoding ?? uri
    }

    /// Logical path of the drive root. The API returns `RemoteFile.path` as a
    /// full URI ("cloudreve://my/h/file.txt"), matching `remote_path` format.
    private var rootPath: String {
        Self.canonicalURI(drive.remote_path)
    }

    private func parentPath(of path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return rootPath }
        let parent = String(p[..<idx])
        // "cloudreve://my" is above the drive root; treat as root.
        return parent.isEmpty || parent == "cloudreve:" || parent == "cloudreve://my"
            ? rootPath : parent
    }

    // MARK: - Item construction

    /// Capabilities for writable items (both files and folders). Trashing is
    /// intentionally omitted: the domain has no local trash, so deletions map
    /// straight to deleteItem → server-side trash.
    private static let writableCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
        .allowsDeleting,
    ]

    func makeItem(
        _ file: RemoteFile,
        preservingIdentifier preserved: NSFileProviderItemIdentifier? = nil
    ) -> FileProviderItem {
        let filePath = Self.canonicalURI(file.path)
        let identifier = preserved ?? identifier(forURI: filePath)
        let parentPath = parentPath(of: filePath)
        let parent: NSFileProviderItemIdentifier =
            (parentPath == rootPath || filePath == rootPath)
            ? .rootContainer
            : self.identifier(forURI: parentPath)

        // Prefer a content hash from metadata for change detection;
        // fall back to modification time + size.
        let versionBasis =
            file.metadata?["etag"] ?? file.metadata?["hash"]
            ?? "\(file.updated_at ?? "")#\(file.size)"
        let version = versionBasis.data(using: .utf8) ?? Data()
        // Finder caches provider thumbnails until contentVersion changes. Keep
        // a schema marker here so installing the first thumbnail-capable build
        // invalidates generic icons cached by older providers exactly once.
        let thumbnailVersion = "\(versionBasis)#thumbnail-v1".data(using: .utf8) ?? version

        let item = FileProviderItem(
            identifier: identifier,
            parentIdentifier: parent,
            filename: file.name,
            contentType: file.isFolder
                ? .folder
                : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data),
            documentSize: file.isFolder ? nil : Int(file.size),
            childItemCount: nil,
            capabilities: file.isFolder
                ? Self.writableCapabilities.union(.allowsContentEnumerating)
                : Self.writableCapabilities,
            contentVersion: file.isFolder ? version : thumbnailVersion,
            metadataVersion: version,
            creationDate: CloudreveClient.parseDate(file.created_at),
            contentModificationDate: CloudreveClient.parseDate(file.updated_at)
        )
        cacheLock.lock()
        cache[identifier.rawValue] = item
        cacheLock.unlock()
        recordIdentity(identifier, uri: filePath)
        return item
    }

    /// All items served this session (for working-set enumeration).
    func cachedItems() -> [FileProviderItem] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Array(cache.values)
    }

    func rootItem(displayName: String) -> FileProviderItem {        FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: displayName,
            contentType: .folder,
            documentSize: nil,
            childItemCount: nil,
            capabilities: [.allowsReading, .allowsContentEnumerating, .allowsWriting],
            contentVersion: Data("root".utf8),
            metadataVersion: Data("root".utf8),
            creationDate: nil,
            contentModificationDate: nil
        )
    }

    // MARK: - Queries

    func item(
        for identifier: NSFileProviderItemIdentifier, displayName: String
    ) async throws -> FileProviderItem {
        if identifier == .rootContainer {
            return rootItem(displayName: displayName)
        }
        if identifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        cacheLock.lock()
        let cached = cache[identifier.rawValue]
        cacheLock.unlock()
        if let cached { return cached }

        // Not seen during enumeration: ask the server (e.g. after extension restart).
        let file = try await client.fileInfo(uri: Self.uri(fromPath: identifier.rawValue))
        return makeItem(file)
    }

    func children(
        of identifier: NSFileProviderItemIdentifier, page: String?
    ) async throws -> (items: [FileProviderItem], nextPage: String?) {
        let result = try await client.listDirectory(uri: uri(for: identifier), page: page)
        let visible = result.files.filter { !Self.isIgnored(filename: $0.name) }
        logger.info(
            "listed \(identifier.rawValue, privacy: .public): \(visible.count) items, next: \(result.nextPage ?? "nil", privacy: .public)")
        return (visible.map { makeItem($0) }, result.nextPage)
    }
}
