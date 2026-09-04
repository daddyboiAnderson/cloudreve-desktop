import Foundation

@main
enum FileProviderActivityTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-file-provider-activity-tests-\(UUID().uuidString)")
        setenv("CLOUDREVE_FP_ACTIVITY_DIR", directory.path, 1)
        setenv(
            "CLOUDREVE_FP_UPLOAD_RECEIPT_DIR",
            directory.appendingPathComponent("receipts").path,
            1)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activity = FileProviderActivity(
            driveID: "drive-1",
            operation: "upload",
            uri: "cloudreve://my/Folder/Report.docx",
            itemIdentifier: "cloudreve-item:/123",
            filename: "Report.docx",
            totalBytes: 1_000)
        activity.update(processedBytes: 400, totalBytes: 1_000)

        var records = FileProviderActivityStore.records(driveID: "drive-1")
        precondition(records.count == 1)
        precondition(records[0].status == "running")
        precondition(records[0].processedBytes == 400)

        activity.complete()
        records = FileProviderActivityStore.records(driveID: "drive-1")
        precondition(records[0].status == "completed")
        precondition(records[0].processedBytes == 1_000)

        _ = FileProviderActivity(
            driveID: "drive-1",
            operation: "download",
            uri: "cloudreve://my/Folder/Other.pdf",
            itemIdentifier: "cloudreve-item:/456",
            filename: "Other.pdf")
        FileProviderActivityStore.markInterruptedActivitiesFailed(driveID: "drive-1")
        records = FileProviderActivityStore.records(driveID: "drive-1")
        precondition(records.first { $0.filename == "Other.pdf" }?.status == "failed")

        print("FileProviderActivityTests: all tests passed")
    }
}
