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
        precondition(base.capabilities.contains(.allowsEvicting))
        precondition(base.userInfo?["displayKeepDownloaded"] as? NSNumber == 1)

        let pinned = base.withPinned(true)
        precondition(pinned.pinned)
        precondition(pinned.effectivelyPinned)
        precondition(pinned.contentPolicy == .downloadEagerlyAndKeepDownloaded)
        precondition(!pinned.capabilities.contains(.allowsEvicting))
        precondition(pinned.itemVersion.contentVersion == base.itemVersion.contentVersion)
        precondition(pinned.itemVersion.metadataVersion != base.itemVersion.metadataVersion)
        precondition(pinned.userInfo?["displayRemoveKeepDownloaded"] as? NSNumber == 1)
        precondition(
            pinned.decorations?.contains(FileProviderItem.keepDownloadedDecoration) == true)

        // Unpinning an item below a separately pinned ancestor must retain the
        // inherited eager policy while clearing the item's explicit pin.
        let inherited = pinned.withPinned(false, effectivelyPinned: true)
        precondition(!inherited.pinned)
        precondition(inherited.effectivelyPinned)
        precondition(inherited.contentPolicy == .downloadEagerlyAndKeepDownloaded)
        precondition(!inherited.capabilities.contains(.allowsEvicting))
        precondition(
            inherited.decorations?.contains(FileProviderItem.keepDownloadedDecoration) == true)

        let unpinned = inherited.withPinned(false, effectivelyPinned: false)
        precondition(!unpinned.pinned)
        precondition(!unpinned.effectivelyPinned)
        precondition(unpinned.contentPolicy == .inherited)
        precondition(unpinned.capabilities.contains(.allowsEvicting))
        precondition(unpinned.itemVersion.metadataVersion == base.itemVersion.metadataVersion)
        precondition(unpinned.decorations == nil)

        print("KeepDownloadedTests: all tests passed")
    }
}
