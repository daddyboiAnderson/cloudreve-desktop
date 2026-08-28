import FileProvider
import UniformTypeIdentifiers

/// NSFileProviderItem backed by remote Cloudreve metadata.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let creationDate: Date?
    let contentModificationDate: Date?
    /// "Keep Downloaded" state set explicitly on this item: drives the
    /// custom context menu actions (via the userInfo activation rules).
    let pinned: Bool
    /// Effective state including inheritance from a pinned ancestor folder:
    /// drives the content policy. Serving the eager policy explicitly (rather
    /// than relying on the system to apply inheritance) makes the system
    /// download freshly enumerated children of pinned folders right away.
    let effectivelyPinned: Bool

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: Int?,
        childItemCount: Int?,
        capabilities: NSFileProviderItemCapabilities,
        contentVersion: Data,
        metadataVersion: Data,
        creationDate: Date?,
        contentModificationDate: Date?,
        pinned: Bool,
        effectivelyPinned: Bool? = nil
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.childItemCount = childItemCount.map { NSNumber(value: $0) }
        self.capabilities = capabilities
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: metadataVersion)
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        self.pinned = pinned
        self.effectivelyPinned = effectivelyPinned ?? pinned
        super.init()
    }

    /// Declarative download/eviction policy (macOS 13+).
    /// `.downloadEagerlyAndKeepDownloaded` = "Keep Downloaded": the system
    /// downloads the item eagerly, keeps downloading remote updates, never
    /// evicts it, and schedules downloads for inherited-policy items that
    /// appear below a pinned folder — this is what auto-downloads files
    /// uploaded from the web UI or other devices.
    var contentPolicy: NSFileProviderContentPolicy {
        effectivelyPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    /// Keys consumed by the NSExtensionFileProviderActions activation rules
    /// in Info.plist so exactly one of the pin/unpin menu entries is shown.
    var userInfo: [AnyHashable: Any]? {
        [
            "displayKeepDownloaded": NSNumber(value: !pinned),
            "displayRemoveKeepDownloaded": NSNumber(value: pinned),
        ]
    }

    /// Copy with a different pin state, so a toggled cached item reports the
    /// new policy before the next server round-trip.
    func withPinned(_ pinned: Bool) -> FileProviderItem {
        FileProviderItem(
            identifier: itemIdentifier,
            parentIdentifier: parentItemIdentifier,
            filename: filename,
            contentType: contentType,
            documentSize: documentSize?.intValue,
            childItemCount: childItemCount?.intValue,
            capabilities: capabilities,
            contentVersion: itemVersion.contentVersion,
            metadataVersion: itemVersion.metadataVersion,
            creationDate: creationDate,
            contentModificationDate: contentModificationDate,
            pinned: pinned,
            effectivelyPinned: pinned
        )
    }
}
