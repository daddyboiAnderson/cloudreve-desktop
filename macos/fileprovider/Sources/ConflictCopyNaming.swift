import Foundation

enum ConflictCopyNaming {
    static func make(
        originalName: String,
        computerName: String? = nil,
        at date: Date = Date(),
        timeZone: TimeZone = .current,
        collisionIndex: Int = 0
    ) -> String {
        let filename = originalName as NSString
        let fileExtension = filename.pathExtension
        let stem = filename.deletingPathExtension
        let device = sanitizedComputerName(computerName ?? currentComputerName())

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH-mm_ddMMyyyy"

        let collision = collisionIndex == 0 ? "" : " \(collisionIndex + 1)"
        let suffix = " (\(device) \(formatter.string(from: date))\(collision))"
        return stem + suffix + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
    }

    private static func currentComputerName() -> String {
        let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localized, !localized.isEmpty { return localized }

        let hostname = ProcessInfo.processInfo.hostName
        return hostname.hasSuffix(".local") ? String(hostname.dropLast(6)) : hostname
    }

    private static func sanitizedComputerName(_ value: String) -> String {
        var invalid = CharacterSet.controlCharacters
        invalid.formUnion(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let sanitized = value
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Mac" : sanitized
    }
}
