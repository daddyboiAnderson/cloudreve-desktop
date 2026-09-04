import Foundation

@main
enum ConflictCopyNamingTests {
    static func main() {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 3600)
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 14
        components.minute = 7
        let date = components.date!
        let timeZone = TimeZone(secondsFromGMT: 3600)!

        precondition(
            ConflictCopyNaming.make(
                originalName: "Report.docx",
                computerName: "Miki’s MacBook Pro",
                at: date,
                timeZone: timeZone)
                == "Report (Miki’s MacBook Pro 14-07_05092026).docx")
        precondition(
            ConflictCopyNaming.make(
                originalName: "Report.docx",
                computerName: "Miki’s MacBook Pro",
                at: date,
                timeZone: timeZone,
                collisionIndex: 1)
                == "Report (Miki’s MacBook Pro 14-07_05092026 2).docx")
        precondition(
            ConflictCopyNaming.make(
                originalName: "Notes",
                computerName: "Office/Mac:1",
                at: date,
                timeZone: timeZone)
                == "Notes (Office-Mac-1 14-07_05092026)")

        print("ConflictCopyNamingTests: all tests passed")
    }
}
