import FileProvider
import UniformTypeIdentifiers

/// File Provider item backed by Cloudreve metadata.
final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let capabilities: NSFileProviderItemCapabilities
    private let baseCapabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let creationDate: Date?
    let contentModificationDate: Date?
    /// Explicit "Keep Downloaded" state.
    let pinned: Bool
    /// Effective state, including inheritance from a pinned folder.
    let effectivelyPinned: Bool
    /// Whether the item has an active Cloudreve share.
    let sharedState: Bool
    /// Whether the current Cloudreve account owns the share.
    let sharedByCurrentUserState: Bool
    /// Whether the server rejected a mutation because another app holds a lock.
    let isLocked: Bool
    let remoteID: String?
    let remoteURI: String?
    /// ETag sent back when Finder uploads a new version.
    let remoteVersion: String?
    /// Unmarked metadata version used when rebuilding the item.
    let baseMetadataVersion: Data

    /// Forces File Provider to notice a policy-only metadata change.
    private static let pinnedVersionMarker = Data("#kd".utf8)
    private static let sharedVersionMarker = Data("#shared".utf8)
    private static let sharedByCurrentUserVersionMarker = Data("#shared-owner".utf8)
    private static let lockedVersionMarker = Data("#locked".utf8)
    private static let lockRestrictedCapabilities: NSFileProviderItemCapabilities = [
        .allowsWriting, .allowsReparenting, .allowsRenaming, .allowsTrashing, .allowsDeleting,
    ]
    static let keepDownloadedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.keep-downloaded-v2")
    static let sharedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.shared-v1")
    static let lockedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.locked-v1")

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
        effectivelyPinned: Bool? = nil,
        sharedState: Bool = false,
        sharedByCurrentUserState: Bool = false,
        locked: Bool = false,
        remoteID: String? = nil,
        remoteURI: String? = nil,
        remoteVersion: String? = nil
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.childItemCount = childItemCount.map { NSNumber(value: $0) }
        self.baseCapabilities = capabilities
        self.pinned = pinned
        let resolvedEffectivelyPinned = effectivelyPinned ?? pinned
        self.effectivelyPinned = resolvedEffectivelyPinned
        self.sharedState = sharedState
        self.sharedByCurrentUserState = sharedByCurrentUserState
        self.isLocked = locked
        self.remoteID = remoteID
        self.remoteURI = remoteURI
        self.remoteVersion = remoteVersion
        var resolvedCapabilities = capabilities
        if locked {
            resolvedCapabilities.subtract(Self.lockRestrictedCapabilities)
        }
        self.capabilities = resolvedCapabilities
        self.baseMetadataVersion = metadataVersion
        var effectiveMetadataVersion = metadataVersion
        if self.effectivelyPinned {
            effectiveMetadataVersion += Self.pinnedVersionMarker
        }
        if self.sharedState {
            effectiveMetadataVersion += Self.sharedVersionMarker
        }
        if self.sharedByCurrentUserState {
            effectiveMetadataVersion += Self.sharedByCurrentUserVersionMarker
        }
        if self.isLocked {
            effectiveMetadataVersion += Self.lockedVersionMarker
        }
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: effectiveMetadataVersion)
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        super.init()
    }

    /// Download and eviction policy shown to File Provider.
    var contentPolicy: NSFileProviderContentPolicy {
        effectivelyPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    var isShared: Bool { sharedState }

    var isSharedByCurrentUser: Bool { sharedByCurrentUserState }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if capabilities.contains(.allowsWriting) {
            flags.insert(.userWritable)
        }
        return flags
    }

    /// Activation-rule values for the custom actions.
    var userInfo: [AnyHashable: Any]? {
        [
            "displayKeepDownloaded": NSNumber(value: !pinned),
            "displayRemoveKeepDownloaded": NSNumber(value: pinned),
            "displayOpenInBrowser": NSNumber(value: true),
            "displayShare": NSNumber(value: itemIdentifier != .rootContainer),
        ]
    }

    /// Finder decorations for Keep Downloaded and sharing state.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        var result: [NSFileProviderItemDecorationIdentifier] = []
        if isLocked {
            result.append(Self.lockedDecoration)
        }
        if effectivelyPinned {
            result.append(Self.keepDownloadedDecoration)
        }
        if sharedState {
            result.append(Self.sharedDecoration)
        }
        return result.isEmpty ? nil : result
    }

    /// Copy with updated explicit and effective pin state.
    func withPinned(_ pinned: Bool, effectivelyPinned: Bool? = nil) -> FileProviderItem {
        FileProviderItem(
            identifier: itemIdentifier,
            parentIdentifier: parentItemIdentifier,
            filename: filename,
            contentType: contentType,
            documentSize: documentSize?.intValue,
            childItemCount: childItemCount?.intValue,
            capabilities: baseCapabilities,
            contentVersion: itemVersion.contentVersion,
            metadataVersion: baseMetadataVersion,
            creationDate: creationDate,
            contentModificationDate: contentModificationDate,
            pinned: pinned,
            effectivelyPinned: effectivelyPinned ?? pinned,
            sharedState: sharedState,
            sharedByCurrentUserState: sharedByCurrentUserState,
            locked: isLocked,
            remoteID: remoteID,
            remoteURI: remoteURI,
            remoteVersion: remoteVersion
        )
    }

    /// Copy with updated lock state.
    func withLocked(_ locked: Bool) -> FileProviderItem {
        FileProviderItem(
            identifier: itemIdentifier,
            parentIdentifier: parentItemIdentifier,
            filename: filename,
            contentType: contentType,
            documentSize: documentSize?.intValue,
            childItemCount: childItemCount?.intValue,
            capabilities: baseCapabilities,
            contentVersion: itemVersion.contentVersion,
            metadataVersion: baseMetadataVersion,
            creationDate: creationDate,
            contentModificationDate: contentModificationDate,
            pinned: pinned,
            effectivelyPinned: effectivelyPinned,
            sharedState: sharedState,
            sharedByCurrentUserState: sharedByCurrentUserState,
            locked: locked,
            remoteID: remoteID,
            remoteURI: remoteURI,
            remoteVersion: remoteVersion
        )
    }
}
