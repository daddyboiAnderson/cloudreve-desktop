import FileProvider
import OSLog
import UniformTypeIdentifiers

private actor OperationGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = true
        }
    }
}

private actor MetadataRefreshCoordinator {
    private var inFlight: [String: Task<RemoteFile, Error>] = [:]

    func run(
        for key: String,
        operation: @escaping () async throws -> RemoteFile
    ) async throws -> RemoteFile {
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { try await operation() }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

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
    /// Stable identities confirmed absent remotely. Finder may replay these
    /// as create callbacks after a domain is re-registered.
    private var deletedIdentityURIs: [String: String] = [:]
    /// Version marker used to force a working-set refresh after policy changes.
    private static let policyMetadataVersion = "keep-downloaded-policy-v3"
    private static let metadataRefreshTTL: TimeInterval = 5
    private var policyRescanPending = false
    private var metadataRefreshAt: [String: Date] = [:]
    private var presentedContainers: [String: UInt64] = [:]
    private var presentedContainerSequence: UInt64 = 0
    private var remoteDeleteGenerationByURI: [String: UInt64] = [:]
    private var pendingStabilizationDeletes: Set<String> = []
    private static let presentedContainerLimit = 8
    private let cacheLock = NSLock()
    private let actionGate = OperationGate()
    private let managerCallGate = OperationGate()
    private let metadataRefreshCoordinator = MetadataRefreshCoordinator()

    // MARK: - Change feed (shared event log)

    /// Remote event recorded by the main app as JSON lines.
    struct FpEvent: Codable {
        let ts: Int64  // unix epoch milliseconds
        let type: String  // create | modify | metadata | rename | delete
        let from: String  // path relative to drive root, or an absolute URI
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
        resetLocalStateIfRequested()
        if let data = try? Data(contentsOf: identityFileURL),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            var normalized: [String: String] = [:]
            var reverse: [String: String] = [:]
            var needsRepair = false

            // Keep one stable identity per canonical URI.
            for savedIdentifier in saved.keys.sorted() {
                guard let rawURI = saved[savedIdentifier] else { continue }
                let identifier = Self.canonicalIdentifier(savedIdentifier)
                let uri = Self.canonicalURI(rawURI)
                if let existing = reverse[uri] {
                    needsRepair = true
                    logger.error(
                        "duplicate item identity for \(uri, privacy: .public): keeping \(existing, privacy: .public), ignoring \(identifier, privacy: .public)"
                    )
                    continue
                }
                normalized[identifier] = uri
                reverse[uri] = identifier
                needsRepair = needsRepair || rawURI != uri || savedIdentifier != identifier
            }
            uriByIdentifier = normalized
            identifierByURI = reverse
            if needsRepair { persistIdentitySnapshot(normalized) }
        }
        if let data = try? Data(contentsOf: pinnedFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            pinnedIdentifiers = Set(saved.map(Self.canonicalIdentifier))
        }
        if let data = try? Data(contentsOf: deletedIdentitiesFileURL),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            deletedIdentityURIs = Dictionary(
                uniqueKeysWithValues: saved.map {
                    (Self.canonicalIdentifier($0.key), Self.canonicalURI($0.value))
                })
        }
        // Persist presented folders for later reconciliation.
        if let data = try? Data(contentsOf: presentedFileURL),
            let saved = try? JSONDecoder().decode([String: UInt64].self, from: data)
        {
            presentedContainers = Dictionary(
                uniqueKeysWithValues: saved.map {
                    (Self.canonicalIdentifier($0.key), $0.value)
                })
            presentedContainerSequence = presentedContainers.values.max() ?? 0
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

    private var deletedIdentitiesFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("deleted-identities-\(drive.id).json")
    }

    private var presentedFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("presented-\(drive.id).json")
    }

    private var policyMetadataVersionURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-metadata-version-\(drive.id).txt")
    }

    private var policyRescanMarkerURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-rescan-\(drive.id).marker")
    }

    private var resetMarkerURL: URL {
        DriveStore.drivesURL.deletingLastPathComponent()
            .appendingPathComponent("fp-reset/\(drive.id).marker")
    }

    private var resetAcknowledgementURL: URL {
        stateDirectoryURL
            .appendingPathComponent("reset-applied-\(drive.id).marker")
    }

    private func resetLocalStateIfRequested() {
        let request = try? Data(contentsOf: resetMarkerURL)
        let acknowledged = try? Data(contentsOf: resetAcknowledgementURL)
        guard ResetRequest.shouldApply(request: request, acknowledged: acknowledged),
            let request
        else { return }
        for url in [
            identityFileURL, deletedIdentitiesFileURL, pinnedFileURL,
            presentedFileURL, pendingPolicyUpdatesFileURL,
            policyMetadataVersionURL, policyRescanMarkerURL,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try FileManager.default.createDirectory(
                at: resetAcknowledgementURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try request.write(to: resetAcknowledgementURL, options: .atomic)
        } catch {
            logger.error(
                "failed to acknowledge File Provider reset: \(error.localizedDescription, privacy: .public)"
            )
        }
        logger.notice("cleared local File Provider state for drive reset")
    }

    private func persistIdentitySnapshot(_ snapshot: [String: String]) {
        do {
            try FileManager.default.createDirectory(
                at: identityFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: identityFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist item identities: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistDeletedIdentitySnapshot(_ snapshot: [String: String]) {
        do {
            try FileManager.default.createDirectory(
                at: deletedIdentitiesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: deletedIdentitiesFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist deleted identities: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func withActionLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await actionGate.acquire()
        do {
            let result = try await operation()
            await actionGate.release()
            return result
        } catch {
            await actionGate.release()
            throw error
        }
    }

    private func withManagerCall<T>(_ operation: () async throws -> T) async rethrows -> T {
        await managerCallGate.acquire()
        do {
            let result = try await operation()
            await managerCallGate.release()
            return result
        } catch {
            await managerCallGate.release()
            throw error
        }
    }

    func queueStabilizationDelete(_ identifier: NSFileProviderItemIdentifier) {
        cacheLock.lock()
        pendingStabilizationDeletes.insert(identifier.rawValue)
        cacheLock.unlock()
        evictCachedItems(withIdentifiers: [identifier])
    }

    func takeStabilizationDeletes() -> [NSFileProviderItemIdentifier] {
        cacheLock.lock()
        let identifiers = pendingStabilizationDeletes
        pendingStabilizationDeletes.removeAll()
        cacheLock.unlock()
        return identifiers.map { NSFileProviderItemIdentifier($0) }
    }

    func signalWorkingSet() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await withManagerCall {
                try await manager.signalEnumerator(for: .workingSet)
            }
        } catch {
            logger.error(
                "failed to signal working set: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        if let existing = identifierByURI[uri] {
            return NSFileProviderItemIdentifier(existing)
        }

        // Do not reuse an identifier for a renamed item.
        if let mappedURI = uriByIdentifier[uri], mappedURI != uri {
            var identifier: String
            repeat {
                identifier = "cloudreve-item:/\(UUID().uuidString.lowercased())"
            } while uriByIdentifier[identifier] != nil
            logger.notice(
                "allocating a new identity for reused path \(uri, privacy: .public); old identity belongs to \(mappedURI, privacy: .public)"
            )
            return NSFileProviderItemIdentifier(identifier)
        }

        return NSFileProviderItemIdentifier(uri)
    }

    private func identifier(
        for file: RemoteFile,
        preserving preserved: NSFileProviderItemIdentifier? = nil
    ) -> NSFileProviderItemIdentifier {
        let uri = Self.canonicalURI(file.path)
        cacheLock.lock()
        defer { cacheLock.unlock() }

        // Prefer the current URI mapping over a stale rename event.
        if let existing = identifierByURI[uri] {
            return NSFileProviderItemIdentifier(existing)
        }

        if let preserved {
            return NSFileProviderItemIdentifier(
                Self.canonicalIdentifier(preserved.rawValue))
        }
        return NSFileProviderItemIdentifier(
            ItemIdentity.remoteID(file.id, fallbackURI: uri))
    }

    private func recordIdentity(_ identifier: NSFileProviderItemIdentifier, uri: String) {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        if let existing = identifierByURI[uri], existing != identifier.rawValue {
            cacheLock.unlock()
            logger.error(
                "identity collision for \(uri, privacy: .public): keeping \(existing, privacy: .public), ignoring \(identifier.rawValue, privacy: .public)"
            )
            return
        }
        if uriByIdentifier[identifier.rawValue] == uri,
            identifierByURI[uri] == identifier.rawValue,
            deletedIdentityURIs[identifier.rawValue] == nil
        {
            cacheLock.unlock()
            return
        }
        if let previousURI = uriByIdentifier[identifier.rawValue] {
            if identifierByURI[previousURI] == identifier.rawValue {
                identifierByURI.removeValue(forKey: previousURI)
            }
        }
        uriByIdentifier[identifier.rawValue] = uri
        identifierByURI[uri] = identifier.rawValue
        let deletedIdentityChanged =
            deletedIdentityURIs.removeValue(forKey: identifier.rawValue) != nil
        let snapshot = uriByIdentifier
        let deletedSnapshot = deletedIdentityURIs
        cacheLock.unlock()
        persistIdentitySnapshot(snapshot)
        if deletedIdentityChanged {
            persistDeletedIdentitySnapshot(deletedSnapshot)
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

    private func metadataIsFresh(
        for identifier: NSFileProviderItemIdentifier
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let refreshedAt = metadataRefreshAt[identifier.rawValue] else {
            return false
        }
        return Date().timeIntervalSince(refreshedAt) < Self.metadataRefreshTTL
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
            if !isEffectivelyPinned(identifier, uri: uri(for: identifier)) {
                return true
            }
            do {
                try await withManagerCall {
                    try await manager.requestDownloadForItem(withIdentifier: identifier)
                }
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
            if isEffectivelyPinned(identifier, uri: uri(for: identifier)) {
                return true
            }
            do {
                try await withManagerCall {
                    try await manager.evictItem(identifier: identifier)
                }
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
        await withActionLock {
            await requestDownloadsForPinnedItemsUnlocked()
        }
    }

    private func requestDownloadsForPinnedItemsUnlocked() async {
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

    /// Retry evictions that were blocked by an in-progress system download.
    func retryEvictionsWhenUnpinned(
        _ identifiers: [NSFileProviderItemIdentifier],
        manager: NSFileProviderManager
    ) {
        let uniqueIdentifiers = identifiers.reduce(into: [String: NSFileProviderItemIdentifier]()) {
            $0[$1.rawValue] = $1
        }.values

        Task { [weak self] in
            guard let self else { return }
            var remaining = Array(uniqueIdentifiers)
            for attempt in 0..<12 {
                if Task.isCancelled { return }
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                let candidates = remaining
                remaining = await withActionLock {
                    var failed: [NSFileProviderItemIdentifier] = []
                    for identifier in candidates {
                        if self.isEffectivelyPinned(
                            identifier, uri: self.uri(for: identifier))
                        {
                            continue
                        }
                        if !(await self.evictWhenAllowed(identifier, manager: manager)) {
                            failed.append(identifier)
                        }
                    }
                    return failed
                }
                if remaining.isEmpty { return }
            }
            let unresolved = remaining.prefix(3).map(\.rawValue).joined(separator: ", ")
            self.logger.error(
                "deferred eviction still pending after retries: \(unresolved, privacy: .public)"
            )
        }
    }

    /// A working-set listing with the verification data used to build it.
    struct WorkingSetSnapshot {
        let items: [FileProviderItem]
        /// Containers re-listed in this snapshot.
        let freshListings: [String: Set<String>]
        /// Containers proven absent on the server.
        let extinctURIs: [String]
    }

    /// Return the current working set, including pinned subtrees.
    func workingSetItems() async throws -> [FileProviderItem] {
        try await workingSetSnapshot().items
    }

    /// Build the current working set and track fresh listings.
    func workingSetSnapshot() async throws -> WorkingSetSnapshot {
        var itemsByIdentifier: [String: FileProviderItem] = [:]
        var foldersToWalk: [NSFileProviderItemIdentifier] = []
        var queuedFolders: Set<String> = []
        /// Containers re-listed during this run and their current children.
        var freshListings: [String: Set<String>] = [:]
        /// Containers proven absent during this run.
        var extinctContainers: Set<String> = []

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
        freshListings[NSFileProviderItemIdentifier.rootContainer.rawValue] = Set(
            rootItems.map { $0.itemIdentifier.rawValue })
        for item in rootItems {
            add(item)
        }

        // Re-list folders Finder has presented during this extension session.
        for container in presentedContainersSnapshot() where container != .rootContainer {
            do {
                let children = try await allChildren(of: container)
                freshListings[container.rawValue] = Set(
                    children.map { $0.itemIdentifier.rawValue })
                for item in children {
                    add(item)
                }
            } catch CloudreveError.noSuchItem {
                logger.notice(
                    "presented folder \(container.rawValue, privacy: .public) no longer exists"
                )
                extinctContainers.insert(container.rawValue)
            } catch {
                logger.error(
                    "presented folder \(container.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
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
                    for: identifier, displayName: domain.displayName,
                    refreshIfStale: true)
                add(pinnedItem)
                if pinnedItem.contentType.conforms(to: .folder) {
                    queueFolder(identifier)
                }
            } catch CloudreveError.noSuchItem {
                logger.notice(
                    "pinned item \(rawIdentifier, privacy: .public) no longer exists"
                )
                extinctContainers.insert(rawIdentifier)
            }
        }

        // Include queued transitions even after an item is unpinned.
        for uri in pendingItemUpdatesSnapshot() {
            do {
                let file = try await client.fileInfoWithShareState(uri: uri)
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
                freshListings[folder.rawValue] = Set(
                    children.map { $0.itemIdentifier.rawValue })
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
                extinctContainers.insert(folder.rawValue)
            } catch {
                logger.error(
                    "working-set folder \(folder.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Remove cached items proven absent by fresh listings.
        let extinctURIs = extinctContainers.map {
            self.uri(for: NSFileProviderItemIdentifier($0))
        }
        var pruned: [NSFileProviderItemIdentifier] = []
        for (rawIdentifier, item) in itemsByIdentifier {
            if extinctContainers.contains(rawIdentifier)
                || extinctURIs.contains(where: { extinct in
                    self.uri(for: item.itemIdentifier).hasPrefix(extinct + "/")
                })
            {
                itemsByIdentifier.removeValue(forKey: rawIdentifier)
                pruned.append(item.itemIdentifier)
                continue
            }
            let parent = item.parentItemIdentifier.rawValue
            if let present = freshListings[parent], !present.contains(rawIdentifier) {
                itemsByIdentifier.removeValue(forKey: rawIdentifier)
                pruned.append(item.itemIdentifier)
            }
        }
        if !pruned.isEmpty {
            evictCachedItems(withIdentifiers: pruned)
        }
        return WorkingSetSnapshot(
            items: Array(itemsByIdentifier.values),
            freshListings: freshListings,
            extinctURIs: extinctURIs)
    }

    /// Item versions currently in the session cache, for change detection.
    private func cacheVersionsSnapshot() -> [String: NSFileProviderItemVersion] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.mapValues { $0.itemVersion }
    }

    private func identityMapsSnapshot() -> (
        byIdentifier: [String: String], byURI: [String: String]
    ) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (uriByIdentifier, identifierByURI)
    }

    /// Reconcile cached working-set items with the server.
    func reconcileWorkingSet() async throws -> (
        updated: [FileProviderItem], deleted: [NSFileProviderItemIdentifier]
    ) {
        let before = cacheVersionsSnapshot()
        let snapshot = try await workingSetSnapshot()
        let currentIDs = Set(snapshot.items.map { $0.itemIdentifier.rawValue })

        var updated: [FileProviderItem] = []
        for item in snapshot.items {
            guard let old = before[item.itemIdentifier.rawValue] else {
                updated.append(item)
                continue
            }
            if old.contentVersion != item.itemVersion.contentVersion
                || old.metadataVersion != item.itemVersion.metadataVersion
            {
                updated.append(item)
            }
        }

        let identityMaps = identityMapsSnapshot()
        let identities = identityMaps.byIdentifier
        let identifierByURI = identityMaps.byURI

        let rootRaw = NSFileProviderItemIdentifier.rootContainer.rawValue
        var deleted: [NSFileProviderItemIdentifier] = []
        for (raw, uri) in identities where !currentIDs.contains(raw) {
            if snapshot.extinctURIs.contains(where: { uri.hasPrefix($0 + "/") }) {
                deleted.append(NSFileProviderItemIdentifier(raw))
                continue
            }
            let parentURI = parentPath(of: uri)
            let parentRaw = parentURI == rootPath ? rootRaw : identifierByURI[parentURI]
            guard let parentRaw, let present = snapshot.freshListings[parentRaw],
                !present.contains(raw)
            else { continue }
            deleted.append(NSFileProviderItemIdentifier(raw))
        }
        return (updated, deleted)
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

    /// Fetch the immediate contents of a folder Finder has opened.
    func currentChildren(
        of identifier: NSFileProviderItemIdentifier
    ) async throws -> [FileProviderItem] {
        try await allChildren(of: identifier)
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
        logger.notice(
            "changes for \(container.rawValue, privacy: .public): anchor \(since), relevant \(relevant.count), delivered \(filtered.count), next \(events.last?.ts ?? since)"
        )
        return (filtered, newAnchor)
    }

    /// Convert an event path to a canonical URI.
    func uri(forEventPath path: String) -> String {
        if path.hasPrefix("cloudreve://") {
            return Self.canonicalURI(path)
        }
        return Self.canonicalURI(drive.remote_path + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func changeTouchesContainer(
        _ change: FpEvent, container: NSFileProviderItemIdentifier
    ) -> Bool {
        let fromURI = uri(forEventPath: change.from)
        let toURI = change.to.map { uri(forEventPath: $0) }
        if container == .workingSet { return true }

        let containerURI = container == .rootContainer
            ? rootPath : Self.canonicalURI(uri(for: container))
        if fromURI == containerURI || toURI == containerURI { return true }
        let parentOf = { (uri: String) -> String in
            var u = uri
            if u.hasSuffix("/") { u.removeLast() }
            guard let idx = u.lastIndex(of: "/") else { return self.rootPath }
            let parent = String(u[..<idx])
            if parent == self.drive.remote_path || parent == "cloudreve://my" || parent.isEmpty {
                return self.rootPath
            }
            return Self.canonicalURI(parent)
        }
        return parentOf(fromURI) == containerURI || (toURI.map { parentOf($0) } == containerURI)
    }

    /// Return the API URI for an item identifier.
    func uri(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return drive.remote_path
        }
        let canonicalIdentifier = Self.canonicalIdentifier(identifier.rawValue)
        cacheLock.lock()
        let mapped = uriByIdentifier[canonicalIdentifier]
        let cached = cache[canonicalIdentifier]?.remoteURI
        cacheLock.unlock()
        return mapped ?? cached ?? Self.uri(fromPath: canonicalIdentifier)
    }

    /// Whether Finder is referring to an item identity we have already seen
    /// at this URI. This distinguishes a stale mirrored create callback after
    /// domain re-registration from a genuinely new Finder item.
    func isKnownIdentity(
        _ identifier: NSFileProviderItemIdentifier, forURI uri: String
    ) -> Bool {
        let raw = Self.canonicalIdentifier(identifier.rawValue)
        let canonicalURI = Self.canonicalURI(uri)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return uriByIdentifier[raw] == canonicalURI
            || deletedIdentityURIs[raw] == canonicalURI
    }

    /// Tracks remote deletes that race with an in-flight Finder upload.
    func remoteDeleteGeneration(for uri: String) -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return remoteDeleteGenerationByURI[Self.canonicalURI(uri)] ?? 0
    }

    func recordRemoteDelete(for uri: String) {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        remoteDeleteGenerationByURI[uri, default: 0] &+= 1
        cacheLock.unlock()
    }

    func remoteDeleteOccurred(for uri: String, after generation: UInt64) -> Bool {
        remoteDeleteGeneration(for: uri) != generation
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

    /// File Provider canonicalizes opaque identifiers containing `://` to
    /// `:/` when returning them. Store one form so callbacks hit the same map.
    static func canonicalIdentifier(_ raw: String) -> String {
        guard raw.hasPrefix("cloudreve-item://") else { return raw }
        return "cloudreve-item:/" + raw.dropFirst("cloudreve-item://".count)
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
        preservingIdentifier preserved: NSFileProviderItemIdentifier? = nil,
        metadataRevision: Data? = nil
    ) -> FileProviderItem {
        let filePath = Self.canonicalURI(file.path)
        let identifier = identifier(for: file, preserving: preserved)
        let parentPath = parentPath(of: filePath)
        let parent: NSFileProviderItemIdentifier =
            (parentPath == rootPath || filePath == rootPath)
            ? .rootContainer
            : self.identifier(forURI: parentPath)

        // Prefer a remote content hash for change detection.
        let versionBasis =
            file.metadata?["etag"] ?? file.metadata?["hash"]
            ?? "\(file.updated_at ?? "")#\(file.size)"
        var version = versionBasis.data(using: .utf8) ?? Data()
        if let metadataRevision { version += metadataRevision }
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
            effectivelyPinned: isEffectivelyPinned(identifier, uri: filePath),
            sharedState: file.shared ?? false,
            sharedByCurrentUserState: file.shared == true && file.owned == true,
            remoteID: file.id,
            remoteURI: filePath
        )
        cacheLock.lock()
        cache[identifier.rawValue] = item
        metadataRefreshAt[identifier.rawValue] = Date()
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

    /// Refresh share flags for the root and presented Finder folders.
    func refreshPresentedShareMetadata() async -> [FileProviderItem] {
        var candidates: [String: FileProviderItem] = [:]
        func add(_ items: [FileProviderItem]) {
            for item in items { candidates[item.itemIdentifier.rawValue] = item }
        }
        do {
            add(try await allChildren(of: .rootContainer))
        } catch {
            logger.error(
                "root share metadata listing failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        for container in presentedContainersSnapshot() where container != .rootContainer {
            if Task.isCancelled { break }
            do {
                add(try await allChildren(of: container))
            } catch CloudreveError.noSuchItem {
                continue
            } catch {
                logger.error(
                    "presented share metadata listing failed for \(container.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return Array(candidates.values)
    }

    /// Verify every persisted identity with the changed filename. Names are
    /// not unique, so all matches are checked against authoritative metadata.
    func refreshShareMetadata(named name: String) async -> [FileProviderItem] {
        let matches = identityMatches(named: name)
        let revision = Data("#share-refresh-\(Date().timeIntervalSince1970)".utf8)
        var refreshed: [FileProviderItem] = []
        for (raw, uri) in matches {
            do {
                let file = try await client.fileInfoWithShareState(uri: uri)
                refreshed.append(makeItem(
                    file,
                    preservingIdentifier: NSFileProviderItemIdentifier(raw),
                    metadataRevision: revision))
            } catch { continue }
        }
        logger.notice("named share refresh \(name, privacy: .public): \(refreshed.count) item(s)")
        return refreshed
    }

    private func identityMatches(named name: String) -> [(String, String)] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let matches = uriByIdentifier.compactMap { raw, uri -> (String, String)? in
            let decodedName = URL(fileURLWithPath: uri).lastPathComponent
            return decodedName == name ? (raw, uri) : nil
        }
        return matches
    }

    /// Forget cached items after a confirmed remote delete, so later
    /// working-set enumerations cannot resurrect them. A deleted folder
    /// takes its cached descendants with it.
    func evictCachedItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
        cacheLock.lock()
        var doomed = Set(identifiers.map { Self.canonicalIdentifier($0.rawValue) })
        for identifier in identifiers {
            let raw = Self.canonicalIdentifier(identifier.rawValue)
            guard let uri = uriByIdentifier[raw] else { continue }
            let prefix = uri + "/"
            for (raw, mappedURI) in uriByIdentifier where mappedURI.hasPrefix(prefix) {
                doomed.insert(raw)
            }
        }
        for raw in doomed {
            cache.removeValue(forKey: raw)
            metadataRefreshAt.removeValue(forKey: raw)
            presentedContainers.removeValue(forKey: raw)
            pinnedIdentifiers.remove(raw)
            if let uri = uriByIdentifier.removeValue(forKey: raw) {
                deletedIdentityURIs[raw] = uri
                if identifierByURI[uri] == raw {
                    identifierByURI.removeValue(forKey: uri)
                }
            }
        }
        let identitySnapshot = uriByIdentifier
        let deletedSnapshot = deletedIdentityURIs
        let pinnedSnapshot = pinnedIdentifiers.sorted()
        cacheLock.unlock()

        persistIdentitySnapshot(identitySnapshot)
        persistDeletedIdentitySnapshot(deletedSnapshot)
        do {
            try FileManager.default.createDirectory(
                at: pinnedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(pinnedSnapshot).write(to: pinnedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pins after remote delete: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func recordPresentedContainer(_ identifier: NSFileProviderItemIdentifier) {
        cacheLock.lock()
        presentedContainerSequence &+= 1
        presentedContainers[Self.canonicalIdentifier(identifier.rawValue)] =
            presentedContainerSequence
        if presentedContainers.count > Self.presentedContainerLimit {
            let overflow = presentedContainers.count - Self.presentedContainerLimit
            for key in presentedContainers.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                presentedContainers.removeValue(forKey: key.key)
            }
        }
        let snapshot = presentedContainers
        cacheLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: presentedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: presentedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist presented containers: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func presentedContainersSnapshot() -> [NSFileProviderItemIdentifier] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return presentedContainers
            .sorted(by: { $0.value > $1.value })
            .map { NSFileProviderItemIdentifier($0.key) }
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
            pinned: isPinned(.rootContainer),
            remoteURI: drive.remote_path
        )
    }

    // MARK: - Queries

    /// Refresh one item from Cloudreve.
    func refreshItem(
        for identifier: NSFileProviderItemIdentifier, displayName: String
    ) async throws -> FileProviderItem {
        if identifier == .rootContainer {
            return rootItem(displayName: displayName)
        }
        if identifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        let itemURI = uri(for: identifier)
        let client = self.client
        do {
            let file = try await metadataRefreshCoordinator.run(for: itemURI) {
                try await client.fileInfoWithShareState(uri: itemURI)
            }
            return makeItem(file, preservingIdentifier: identifier)
        } catch CloudreveError.noSuchItem {
            // Confirmed gone on the server: drop the stale cache entry.
            evictCachedItems(withIdentifiers: [identifier])
            throw CloudreveError.noSuchItem
        }
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        displayName: String,
        refreshIfStale: Bool = true
    ) async throws -> FileProviderItem {
        if identifier == .rootContainer {
            return rootItem(displayName: displayName)
        }
        if identifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        let cached = cachedItem(for: identifier)
        if let cached {
            if !refreshIfStale || metadataIsFresh(for: identifier) {
                logger.debug(
                    "metadata cache hit for \(identifier.rawValue, privacy: .public)")
                return cached
            }

            logger.debug(
                "refreshing stale metadata for \(identifier.rawValue, privacy: .public)")
            do {
                return try await refreshItem(for: identifier, displayName: displayName)
            } catch CloudreveError.noSuchItem {
                throw CloudreveError.noSuchItem
            } catch {
                logger.notice(
                    "metadata refresh failed for \(identifier.rawValue, privacy: .public); using cached item: \(error.localizedDescription, privacy: .public)"
                )
                return cached
            }
        }

        // Resolve items not present in the session cache.
        logger.debug(
            "metadata cache miss for \(identifier.rawValue, privacy: .public)")
        return try await refreshItem(for: identifier, displayName: displayName)
    }

    func browserURL(
        for identifier: NSFileProviderItemIdentifier, item: FileProviderItem
    ) -> URL? {
        let itemURI = item.remoteURI ?? uri(for: identifier)
        let isFolder = item.contentType.conforms(to: .folder)
        let folderURI = isFolder ? itemURI : parentPath(of: itemURI)
        guard var components = URLComponents(string: drive.instance_url) else { return nil }
        components.path = "/home"
        var queryItems = [URLQueryItem(name: "path", value: folderURI)]
        if !isFolder {
            queryItems.append(
                URLQueryItem(name: "open", value: item.remoteID ?? itemURI))
        }
        if let userID = drive.user_id, !userID.isEmpty {
            queryItems.append(URLQueryItem(name: "user_hint", value: userID))
        }
        components.queryItems = queryItems
        return components.url
    }

    func children(
        of identifier: NSFileProviderItemIdentifier, page: String?
    ) async throws -> (items: [FileProviderItem], nextPage: String?) {
        let result = try await client.listDirectory(uri: uri(for: identifier), page: page)
        let visible = result.files.filter { !Self.isIgnored(filename: $0.name) }
        let revision = Data("#listed-share-\(Date().timeIntervalSince1970)".utf8)
        var verified = visible

        // Directory listings can retain a removed share flag. Verify only the
        // small set reported as shared when Finder presents this folder.
        for index in verified.indices where verified[index].shared == true {
            let itemURI = Self.canonicalURI(verified[index].path)
            do {
                verified[index] = try await client.fileInfoWithShareState(
                    uri: itemURI)
            } catch {
                logger.notice(
                    "share verification failed for \(itemURI, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let sharedCount = verified.reduce(into: 0) { count, file in
            if file.shared == true { count += 1 }
        }
        logger.info(
            "listed \(identifier.rawValue, privacy: .public): \(visible.count) items, shared: \(sharedCount), next: \(result.nextPage ?? "nil", privacy: .public)")
        return (
            verified.map { makeItem($0, metadataRevision: revision) },
            result.nextPage)
    }
}
