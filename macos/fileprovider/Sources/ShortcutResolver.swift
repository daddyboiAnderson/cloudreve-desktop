import Foundation

/// Resolves share shortcuts while preserving their Finder location.
enum ShortcutResolver {
    static func parent(_ uri: String) -> String {
        guard let scheme = uri.range(of: "://"),
            let slash = uri[scheme.upperBound...].lastIndex(of: "/")
        else { return uri }
        return String(uri[..<slash])
    }

    static func child(_ name: String, of uri: String) -> String {
        (uri.hasSuffix("/") ? String(uri.dropLast()) : uri) + "/" + name
    }

    static func resolve(
        _ uri: String, followLeaf: Bool,
        lookup: (String) async throws -> String?
    ) async throws -> String {
        var current = uri
        var visited: Set<String> = []
        for _ in 0..<32 {
            guard visited.insert(current).inserted else {
                throw CloudreveError.badResponse("Circular shared shortcut")
            }
            var prefixes: [String] = []
            var prefix = followLeaf ? current : parent(current)
            while parent(prefix) != prefix {
                prefixes.append(prefix)
                prefix = parent(prefix)
            }
            var redirected = false
            for candidate in prefixes.reversed() {
                if let target = try await lookup(candidate), !target.isEmpty {
                    guard target.hasPrefix("cloudreve://") else {
                        throw CloudreveError.badResponse("Invalid shared shortcut target")
                    }
                    let suffix = String(current.dropFirst(candidate.count))
                    current = (target.hasSuffix("/") ? String(target.dropLast()) : target) + suffix
                    redirected = true
                    break
                }
            }
            if !redirected { return current }
        }
        throw CloudreveError.badResponse("Too many shared shortcut redirects")
    }
}
