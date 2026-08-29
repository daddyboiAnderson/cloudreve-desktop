import FileProvider
import OSLog
import UniformTypeIdentifiers

/// Maps a File Provider domain to a Cloudreve drive.
final class RemoteStore {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "store")

    let drive: DriveConfig
    let client: CloudreveClient
    private let domain: NSFileProviderDomain

    /// itemIdentifier.rawValue -> item.
    private var cache: [String: FileProviderItem] = [:]
    /// Stable Finder identity -> current Cloudreve URI.
    private var uriByIdentifier: [String: String] = [:]
    private var identifierByURI: [String: String] = [:]
    /// Explicitly pinned identifiers, persisted per drive.
    private var pinnedIdentifiers: Set<String> = []
    /// Version marker used to force a working-set refresh after policy changes.
    private static let policyMetadataVersion = "keep-downloaded-policy-v3"
    private var policyRescanPending = false
    private let cacheLock = NSLock()

    // MARK: - Change feed (shared event log)

    /// Remote event recorded by the main app as JSON lines.
    struct FpEvent: Codable {
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
            uriByIdentifier = saved.mapValues(Self.canonicalURI)
            // Keep one stable identity per canonical URI.
            identifierByURI = saved.reduce(into: [:]) { result, entry in
                let identifier = entry.key
                let uri = Self.canonicalURI(entry.value)
                if let existing = result[uri], existing != identifier {
                    logger.error(
                        "duplicate item identity for \(uri, privacy: .public): keeping \(existing, privacy: .public), ignoring \(identifier, privacy: .public)"
                    )
                    return
                }
                result[uri] = identifier
            }
        }
        if let data = try? Data(contentsOf: pinnedFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            pinnedIdentifiers = Set(saved)
        }
        let currentPolicyVersion = Data(Self.policyMetadataVersion.utf8)
        let hasCurrentPolicyVersion =
            (try? Data(contentsOf: policyMetadataVersionURL)) == currentPolicyVersion
        let hasRescanMarker = FileManager.default.fileExists(atPath: policyRescanMarkerURL.path)
        policyRescanPending = hasRescanMarker || !hasCurrentPolicyVersion
        if policyRescanPending {
            persistPolicyRescanMarker()
            logger.notice(
                "Keep Downloaded metadata refresh scheduled for drive \(drive.id, privacy: .public)"
            )
        }
    }

    private var stateDirectoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CloudreveFileProvider", isDirectory: true)
    }

    private var pinnedFileURL: URL {
        stateDirectoryURL.appendingPathComponent("pinned-\(drive.id).json")
    }

    private var identityFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("identities-\(drive.id).json")
    }

    private var policyMetadataVersionURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-metadata-version-\(drive.id).txt")
    }

    private var policyRescanMarkerURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-rescan-\(drive.id).marker")
    }

    private func persistPolicyRescanMarker() {
        do {
            try FileManager.default.createDirectory(
                at: policyRescanMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(Self.policyMetadataVersion.utf8).write(
                to: policyRescanMarkerURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist policy rescan marker: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Consume the one-shot working-set refresh request.
    func consumePolicyRescanIfNeeded() -> Bool {
        cacheLock.lock()
        guard policyRescanPending else {
            cacheLock.unlock()
            return false
        }
        policyRescanPending = false
        cacheLock.unlock()

        try? FileManager.default.removeItem(at: policyRescanMarkerURL)
        do {
            try FileManager.default.createDirectory(
                at: policyMetadataVersionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(Self.policyMetadataVersion.utf8).write(
                to: policyMetadataVersionURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist policy metadata version: \(error.localizedDescription, privacy: .public)"
            )
        }
        logger.notice("expiring working-set anchor for Keep Downloaded metadata refresh")
        return true
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
            if identifierByURI[previousURI] == identifier.rawValue {
                identifierByURI.removeValue(forKey: previousURI)
            }
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

    // MARK: - "Keep Downloaded" pin state

    func isPinned(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pinnedIdentifiers.contains(identifier.rawValue)
    }

    private func pinnedIdentifiersSnapshot() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pinnedIdentifiers
    }

    private func cachedItem(
        for identifier: NSFileProviderItemIdentifier
    ) -> FileProviderItem? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[identifier.rawValue]
    }

    private func isEffectivelyPinnedLocked(
        _ identifier: NSFileProviderItemIdentifier, uri: String
    ) -> Bool {
        let uri = Self.canonicalURI(uri)
        if pinnedIdentifiers.contains(identifier.rawValue) {
            return true
        }

        // A pinned root covers the whole drive.
        let rootIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        if pinnedIdentifiers.contains(rootIdentifier) {
            let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return uri == rootPath || uri.hasPrefix(root)
        }

        for pinned in pinnedIdentifiers {
            let pinnedURI: String
            if pinned == rootIdentifier {
                pinnedURI = rootPath
            } else {
                pinnedURI = uriByIdentifier[pinned].map(Self.canonicalURI)
                    ?? Self.canonicalURI(pinned)
            }
            let prefix = pinnedURI.hasSuffix("/") ? pinnedURI : pinnedURI + "/"
            if uri.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Whether an item is explicitly or implicitly pinned.
    func isEffectivelyPinned(
        _ identifier: NSFileProviderItemIdentifier, uri: String
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return isEffectivelyPinnedLocked(identifier, uri: uri)
    }

    /// Pending policy updates for working-set enumeration.
    private var pendingPolicyUpdatesFileURL: URL {
        stateDirectoryURL.appendingPathComponent("pending-pinned-\(drive.id).json")
    }

    /// Queue items whose content policy changed.
    func recordPendingItemUpdates(uris: [String]) {
        cacheLock.lock()
        var pending = readPendingPolicyUpdates()
        pending.formUnion(uris)
        policyRescanPending = true
        cacheLock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: pendingPolicyUpdatesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(pending.sorted()).write(
                to: pendingPolicyUpdatesFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pending item updates: \(error.localizedDescription, privacy: .public)")
        }
        persistPolicyRescanMarker()
    }

    private func readPendingPolicyUpdates() -> Set<String> {
        guard let data = try? Data(contentsOf: pendingPolicyUpdatesFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(saved)
    }

    private func pendingItemUpdatesSnapshot() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return readPendingPolicyUpdates()
    }

    /// Take queued policy updates, clearing the persisted list.
    func takePendingItemUpdates() -> [String] {
        cacheLock.lock()
        let pending = readPendingPolicyUpdates()
        cacheLock.unlock()
        try? FileManager.default.removeItem(at: pendingPolicyUpdatesFileURL)
        return pending.sorted()
    }

    /// Request a download, retrying while the item is ingested.
    func requestDownloadWhenKnown(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager? = nil
    ) async -> Bool {
        guard let manager = manager ?? NSFileProviderManager(for: domain) else {
            logger.error(
                "cannot request download for \(identifier.rawValue, privacy: .public): no File Provider manager"
            )
            return false
        }
        var lastError: Error?
        for attempt in 0..<5 {
            if Task.isCancelled { return false }
            do {
                try await manager.requestDownloadForItem(withIdentifier: identifier)
                logger.notice(
                    "download request accepted for \(identifier.rawValue, privacy: .public) on attempt \(attempt + 1)"
                )
                return true
            } catch {
                lastError = error
                logger.error(
                    "download request attempt \(attempt + 1) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        logger.error(
            "download request failed for \(identifier.rawValue, privacy: .public) after 5 attempts: \(lastError?.localizedDescription ?? "unknown error", privacy: .public)"
        )
        return false
    }

    /// Evict local content, retrying while the new policy is ingested.
    func evictWhenAllowed(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager? = nil
    ) async -> Bool {
        guard let manager = manager ?? NSFileProviderManager(for: domain) else {
            logger.error(
                "cannot evict \(identifier.rawValue, privacy: .public): no File Provider manager"
            )
            return false
        }
        var lastError: Error?
        for attempt in 1...6 {
            if Task.isCancelled { return false }
            do {
                try await manager.evictItem(identifier: identifier)
                logger.notice(
                    "eviction accepted for \(identifier.rawValue, privacy: .public) on attempt \(attempt)"
                )
                return true
            } catch {
                lastError = error
                logger.error(
                    "eviction attempt \(attempt) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < 6 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
        logger.error(
            "eviction failed for \(identifier.rawValue, privacy: .public) after 6 attempts: \(lastError?.localizedDescription ?? "unknown error", privacy: .public)"
        )
        return false
    }

    /// Resume downloads for persisted pins.
    func requestDownloadsForPinnedItems() async {
        let pinned = pinnedIdentifiersSnapshot()
        guard !pinned.isEmpty else { return }
        do {
            let items = try await workingSetItems()
            let files = items.filter {
                !$0.contentType.conforms(to: .folder)
                    && isEffectivelyPinned($0.itemIdentifier, uri: uri(for: $0.itemIdentifier))
            }
            for start in stride(from: 0, to: files.count, by: 8) {
                if Task.isCancelled { return }
                let end = min(start + 8, files.count)
                await withTaskGroup(of: Void.self) { group in
                    for file in files[start..<end] {
                        group.addTask {
                            guard self.isEffectivelyPinned(
                                file.itemIdentifier,
                                uri: self.uri(for: file.itemIdentifier)
                            ) else { return }
                            _ = await self.requestDownloadWhenKnown(file.itemIdentifier)
                        }
                    }
                }
            }
        } catch {
            logger.error(
                "failed to resume pinned downloads: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Return the current working set, including pinned subtrees.
    func workingSetItems() async throws -> [FileProviderItem] {
        var itemsByIdentifier: [String: FileProviderItem] = [:]
        var foldersToWalk: [NSFileProviderItemIdentifier] = []
        var queuedFolders: Set<String> = []

        func add(_ item: FileProviderItem) {
            itemsByIdentifier[item.itemIdentifier.rawValue] = item
        }

        func queueFolder(_ identifier: NSFileProviderItemIdentifier) {
            if queuedFolders.insert(identifier.rawValue).inserted {
                foldersToWalk.append(identifier)
            }
        }

        for item in cachedItems() {
            add(item)
        }

        // Keep top-level items current.
        let rootItems = try await allChildren(of: .rootContainer)
        for item in rootItems {
            add(item)
        }

        let pinned = pinnedIdentifiersSnapshot()
        for rawIdentifier in pinned {
            let identifier = NSFileProviderItemIdentifier(rawIdentifier)
            if identifier == .rootContainer {
                queueFolder(identifier)
                continue
            }
            do {
                let pinnedItem = try await item(
                    for: identifier, displayName: domain.displayName)
                add(pinnedItem)
                if pinnedItem.contentType.conforms(to: .folder) {
                    queueFolder(identifier)
                }
            } catch CloudreveError.noSuchItem {
                logger.notice(
                    "pinned item \(rawIdentifier, privacy: .public) no longer exists"
                )
            }
        }

        // Include queued transitions even after an item is unpinned.
        for uri in pendingItemUpdatesSnapshot() {
            do {
                let file = try await client.fileInfo(uri: uri)
                let pendingItem = makeItem(file)
                add(pendingItem)
                if pendingItem.contentType.conforms(to: .folder) {
                    queueFolder(pendingItem.itemIdentifier)
                }
            } catch CloudreveError.noSuchItem {
                // The remote delete superseded the update.
            }
        }

        while !foldersToWalk.isEmpty {
            if Task.isCancelled { break }
            let folder = foldersToWalk.removeFirst()
            do {
                let children = try await allChildren(of: folder)
                for child in children {
                    add(child)
                    if child.contentType.conforms(to: .folder) {
                        queueFolder(child.itemIdentifier)
                    }
                }
            } catch CloudreveError.noSuchItem {
                logger.notice(
                    "working-set folder \(folder.rawValue, privacy: .public) no longer exists"
                )
            } catch {
                logger.error(
                    "working-set folder \(folder.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return Array(itemsByIdentifier.values)
    }

    private func allChildren(
        of identifier: NSFileProviderItemIdentifier
    ) async throws -> [FileProviderItem] {
        var result: [FileProviderItem] = []
        var page: String? = nil
        repeat {
            let (items, nextPage) = try await children(of: identifier, page: page)
            result.append(contentsOf: items)
            page = nextPage
        } while page != nil
        return result
    }

    /// Toggle and persist pin state, then refresh cached policies.
    func setPinned(_ pinned: Bool, for identifier: NSFileProviderItemIdentifier) {
        cacheLock.lock()
        if pinned {
            pinnedIdentifiers.insert(identifier.rawValue)
        } else {
            pinnedIdentifiers.remove(identifier.rawValue)
        }

        // Refresh descendants already cached by File Provider.
        for (rawIdentifier, cached) in cache {
            let cachedIdentifier = NSFileProviderItemIdentifier(rawIdentifier)
            let cachedURI = cachedIdentifier == .rootContainer
                ? rootPath
                : (uriByIdentifier[rawIdentifier] ?? Self.uri(fromPath: rawIdentifier))
            let explicitlyPinned = pinnedIdentifiers.contains(rawIdentifier)
            let effectivelyPinned = isEffectivelyPinnedLocked(
                cachedIdentifier, uri: cachedURI)
            if cached.pinned != explicitlyPinned
                || cached.effectivelyPinned != effectivelyPinned
            {
                cache[rawIdentifier] = cached.withPinned(
                    explicitlyPinned, effectivelyPinned: effectivelyPinned)
            }
        }
        let snapshot = pinnedIdentifiers.sorted()
        cacheLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: pinnedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: pinnedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pinned items: \(error.localizedDescription, privacy: .public)")
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

    /// Anchor for the last delivered event: "evt-<millis>".
    func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        let lastTs = readEvents().last?.ts ?? 0
        return NSFileProviderSyncAnchor(Data("evt-\(lastTs)".utf8))
    }

    /// Return events after an anchor, or expire an unknown anchor.
    func changes(since anchorData: Data, for container: NSFileProviderItemIdentifier)
        throws -> ([FpEvent], NSFileProviderSyncAnchor)
    {
        guard let text = String(data: anchorData, encoding: .utf8),
            text.hasPrefix("evt-"), let since = Int64(text.dropFirst(4))
        else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let events = readEvents()
        // A rescan marker invalidates all later anchors.
        if events.contains(where: { $0.type == "rescan" && $0.ts > since }) {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let relevant = events.filter { $0.ts > since }
        let filtered = relevant.filter { changeTouchesContainer($0, container: container) }
        let newAnchor = NSFileProviderSyncAnchor(Data("evt-\(events.last?.ts ?? since)".utf8))
        return (filtered, newAnchor)
    }

    /// Convert an event path to a canonical URI.
    func uri(forEventPath path: String) -> String {
        Self.canonicalURI(drive.remote_path + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func changeTouchesContainer(
        _ change: FpEvent, container: NSFileProviderItemIdentifier
    ) -> Bool {
        let fromURI = uri(forEventPath: change.from)
        let toURI = change.to.map { uri(forEventPath: $0) }
        // Working set gets every change; containers get direct-child changes.
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

    /// Return the API URI for an item identifier.
    func uri(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return drive.remote_path
        }
        cacheLock.lock()
        let mapped = uriByIdentifier[identifier.rawValue]
        cacheLock.unlock()
        return mapped ?? Self.uri(fromPath: identifier.rawValue)
    }

    /// Finder metadata files that stay local-only.
    static func isIgnored(filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._")
    }

    /// Convert a logical path to a Cloudreve URI.
    static func uri(fromPath path: String) -> String {
        let uri =
            path.hasPrefix("cloudreve://")
            ? path
            : "cloudreve://my" + (path.hasPrefix("/") ? path : "/" + path)
        return canonicalURI(uri)
    }

    /// Normalize percent-encoded Cloudreve paths.
    static func canonicalURI(_ uri: String) -> String {
        uri.removingPercentEncoding ?? uri
    }

    /// Canonical URI of the drive root.
    private var rootPath: String {
        Self.canonicalURI(drive.remote_path)
    }

    private func parentPath(of path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return rootPath }
        let parent = String(p[..<idx])
        // Never return a path above the drive root.
        return parent.isEmpty || parent == "cloudreve:" || parent == "cloudreve://my"
            ? rootPath : parent
    }

    // MARK: - Item construction

    /// Writable capabilities; trash is handled by the server.
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

        // Prefer a remote content hash for change detection.
        let versionBasis =
            file.metadata?["etag"] ?? file.metadata?["hash"]
            ?? "\(file.updated_at ?? "")#\(file.size)"
        let version = versionBasis.data(using: .utf8) ?? Data()
        // Invalidate Finder's old thumbnail cache once.
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
            contentModificationDate: CloudreveClient.parseDate(file.updated_at),
            pinned: isPinned(identifier),
            effectivelyPinned: isEffectivelyPinned(identifier, uri: filePath)
        )
        cacheLock.lock()
        cache[identifier.rawValue] = item
        cacheLock.unlock()
        recordIdentity(identifier, uri: filePath)
        return item
    }

    /// Items served during this session.
    func cachedItems() -> [FileProviderItem] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Array(cache.values)
    }

    func rootItem(displayName: String) -> FileProviderItem {
        FileProviderItem(
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
            contentModificationDate: nil,
            pinned: isPinned(.rootContainer)
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
        let cached = cachedItem(for: identifier)
        if let cached { return cached }

        // Resolve items not present in the session cache.
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
