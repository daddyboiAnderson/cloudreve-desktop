import Foundation
import FileProvider

/// Read macOS's existing metadata without enumerating the remote hierarchy or
/// downloading contents. Explicit pins are distinguished from inherited policy.
enum MaterializedStateRecovery {
    struct Item {
        let identifier: String
        let parent: String
        let name: String
        let explicitlyPinned: Bool
        var effectivelyPinned: Bool = false
    }

    static func read(manager: NSFileProviderManager) async throws -> [Item] {
        let enumerator = manager.enumeratorForMaterializedItems()
        let observer = Observer(enumerator: enumerator)
        return try await withCheckedThrowingContinuation { continuation in
            observer.completion = { result in
                // Retain the observer through all asynchronous pages.
                withExtendedLifetime(observer) { continuation.resume(with: result) }
            }
            enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(rawValue: Data()))
        }
    }

    static func reconstruct(_ items: [Item], root: String, existing: [String: String]) -> (identities: [String: String], pins: Set<String>) {
        var identities = existing
        identities[NSFileProviderItemIdentifier.rootContainer.rawValue] = root
        var remaining = items
        while !remaining.isEmpty {
            var pending: [Item] = []
            for item in remaining {
                if item.identifier == NSFileProviderItemIdentifier.rootContainer.rawValue { continue }
                guard let parent = identities[item.parent] else { pending.append(item); continue }
                // The store's identity map uses decoded, canonical Cloudreve URIs.
                identities[item.identifier] = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + item.name
            }
            if pending.count == remaining.count { break }
            remaining = pending
        }
        let byID = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { _, new in new })
        let pins = Set(items.filter { item in
            guard identities[item.identifier] != nil else { return false }
            if item.explicitlyPinned { return true }
            guard item.effectivelyPinned else { return false }
            // Materialized enumeration can omit userInfo. Preserve the known
            // effective policy using its topmost roots, never pin every child.
            var parent = item.parent
            var visited = Set<String>()
            while parent != NSFileProviderItemIdentifier.rootContainer.rawValue {
                guard visited.insert(parent).inserted, let ancestor = byID[parent] else { return false }
                if ancestor.effectivelyPinned || ancestor.explicitlyPinned { return false }
                parent = ancestor.parent
            }
            return true
        }.map(\.identifier))
        identities.removeValue(forKey: NSFileProviderItemIdentifier.rootContainer.rawValue)
        return (identities, pins)
    }

    private final class Observer: NSObject, NSFileProviderEnumerationObserver {
        let enumerator: NSFileProviderEnumerator
        var completion: ((Result<[Item], Error>) -> Void)?
        var items: [Item] = []
        init(enumerator: NSFileProviderEnumerator) { self.enumerator = enumerator }

        func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
            for item in updatedItems {
                let info = item.userInfo ?? nil
                var recovered = Item(identifier: item.itemIdentifier.rawValue,
                    parent: item.parentItemIdentifier.rawValue, name: item.filename,
                    explicitlyPinned: (info?["displayRemoveKeepDownloaded"] as? NSNumber)?.boolValue == true)
                // #kd is written by FileProviderItem solely for effective
                // Keep Downloaded policy; it is not a materialization flag.
                let version = (item.itemVersion ?? nil)?.metadataVersion ?? Data()
                recovered.effectivelyPinned = item.contentPolicy == .downloadEagerlyAndKeepDownloaded
                    || version.suffix(3) == Data("#kd".utf8)
                items.append(recovered)
            }
        }
        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            if let nextPage { enumerator.enumerateItems(for: self, startingAt: nextPage) }
            else { finish(.success(items)) }
        }
        func finishEnumeratingWithError(_ error: Error) { finish(.failure(error)) }
        private func finish(_ result: Result<[Item], Error>) {
            let callback = completion
            completion = nil
            enumerator.invalidate()
            callback?(result)
        }
    }
}
