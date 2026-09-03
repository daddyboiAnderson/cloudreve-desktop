import FileProvider
import Foundation
import UniformTypeIdentifiers

@main
enum KeepDownloadedTests {
    static func main() {
        let base = FileProviderItem(
            identifier: NSFileProviderItemIdentifier("cloudreve://my/report.pdf"),
            parentIdentifier: .rootContainer,
            filename: "report.pdf",
            contentType: .pdf,
            documentSize: 42,
            childItemCount: nil,
            capabilities: [.allowsReading],
            contentVersion: Data("content-1".utf8),
            metadataVersion: Data("metadata-1".utf8),
            creationDate: nil,
            contentModificationDate: nil,
            pinned: false)

        precondition(base.contentPolicy == .inherited)
        precondition(base.userInfo?["displayKeepDownloaded"] as? NSNumber == 1)
        precondition(base.userInfo?["displayShare"] as? NSNumber == 1)

        let pinned = base.withPinned(true)
        precondition(pinned.pinned)
        precondition(pinned.effectivelyPinned)
        precondition(pinned.contentPolicy == .downloadEagerlyAndKeepDownloaded)
        precondition(pinned.itemVersion.contentVersion == base.itemVersion.contentVersion)
        precondition(pinned.itemVersion.metadataVersion != base.itemVersion.metadataVersion)
        precondition(pinned.userInfo?["displayRemoveKeepDownloaded"] as? NSNumber == 1)
        precondition(
            pinned.decorations?.contains(FileProviderItem.keepDownloadedDecoration) == true)

        let sharedAndPinned = FileProviderItem(
            identifier: base.itemIdentifier,
            parentIdentifier: base.parentItemIdentifier,
            filename: base.filename,
            contentType: base.contentType,
            documentSize: base.documentSize?.intValue,
            childItemCount: base.childItemCount?.intValue,
            capabilities: base.capabilities,
            contentVersion: base.itemVersion.contentVersion,
            metadataVersion: base.baseMetadataVersion,
            creationDate: base.creationDate,
            contentModificationDate: base.contentModificationDate,
            pinned: true,
            sharedState: true,
            sharedByCurrentUserState: true)
        precondition(sharedAndPinned.isShared)
        precondition(sharedAndPinned.isSharedByCurrentUser)
        precondition(
            sharedAndPinned.itemVersion.metadataVersion != pinned.itemVersion.metadataVersion)
        precondition(
            sharedAndPinned.decorations?.contains(FileProviderItem.keepDownloadedDecoration) == true)
        precondition(
            sharedAndPinned.decorations?.contains(FileProviderItem.sharedDecoration) == true)

        let sharedAfterPin = sharedAndPinned.withPinned(true)
        precondition(sharedAfterPin.isShared)
        precondition(
            sharedAfterPin.decorations?.contains(FileProviderItem.sharedDecoration) == true)
        let sharedAfterUnpin = sharedAfterPin.withPinned(false, effectivelyPinned: false)
        precondition(!sharedAfterUnpin.effectivelyPinned)
        precondition(sharedAfterUnpin.isShared)
        precondition(
            sharedAfterUnpin.decorations?.contains(FileProviderItem.sharedDecoration) == true)
        precondition(
            sharedAfterUnpin.itemVersion.metadataVersion != base.itemVersion.metadataVersion)

        // Unpinning an item below a separately pinned ancestor must retain the
        // inherited eager policy while clearing the item's explicit pin.
        let inherited = pinned.withPinned(false, effectivelyPinned: true)
        precondition(!inherited.pinned)
        precondition(inherited.effectivelyPinned)
        precondition(inherited.contentPolicy == .downloadEagerlyAndKeepDownloaded)
        precondition(
            inherited.decorations?.contains(FileProviderItem.keepDownloadedDecoration) == true)

        let unpinned = inherited.withPinned(false, effectivelyPinned: false)
        precondition(!unpinned.pinned)
        precondition(!unpinned.effectivelyPinned)
        precondition(unpinned.contentPolicy == .inherited)
        precondition(unpinned.itemVersion.metadataVersion == base.itemVersion.metadataVersion)
        precondition(unpinned.decorations == nil)

        let editable = FileProviderItem(
            identifier: base.itemIdentifier,
            parentIdentifier: base.parentItemIdentifier,
            filename: base.filename,
            contentType: base.contentType,
            documentSize: base.documentSize?.intValue,
            childItemCount: base.childItemCount?.intValue,
            capabilities: [
                .allowsReading, .allowsWriting, .allowsReparenting,
                .allowsRenaming, .allowsDeleting,
            ],
            contentVersion: base.itemVersion.contentVersion,
            metadataVersion: base.baseMetadataVersion,
            creationDate: base.creationDate,
            contentModificationDate: base.contentModificationDate,
            pinned: false,
            remoteVersion: "etag-1")
        let locked = FileProviderItem(
            identifier: editable.itemIdentifier,
            parentIdentifier: editable.parentItemIdentifier,
            filename: editable.filename,
            contentType: editable.contentType,
            documentSize: editable.documentSize?.intValue,
            childItemCount: editable.childItemCount?.intValue,
            capabilities: editable.capabilities,
            contentVersion: editable.itemVersion.contentVersion,
            metadataVersion: editable.baseMetadataVersion,
            creationDate: editable.creationDate,
            contentModificationDate: editable.contentModificationDate,
            pinned: false,
            locked: true,
            remoteVersion: editable.remoteVersion)
        precondition(locked.isLocked)
        precondition(!locked.capabilities.contains(.allowsWriting))
        precondition(!locked.fileSystemFlags.contains(.userWritable))
        precondition(locked.fileSystemFlags.contains(.userReadable))
        precondition(
            locked.decorations?.contains(FileProviderItem.lockedDecoration) == true)
        precondition(locked.itemVersion.metadataVersion != editable.itemVersion.metadataVersion)
        precondition(locked.withLocked(false).capabilities.contains(.allowsWriting))

        let root = FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: "Cloudreve",
            contentType: .folder,
            documentSize: nil,
            childItemCount: 1,
            capabilities: [.allowsReading],
            contentVersion: Data("root-content".utf8),
            metadataVersion: Data("root-metadata".utf8),
            creationDate: nil,
            contentModificationDate: nil,
            pinned: false)
        precondition(root.userInfo?["displayShare"] as? NSNumber == 0)

        print("KeepDownloadedTests: all tests passed")
    }
}
