import FileProvider
import Foundation

/// Generic File Provider domain management CLI.
///
/// Domains are scoped to the *host app bundle* of the calling process, so to
/// manage the domains of a given app, run this binary from inside that app's
/// bundle (e.g. copy it to Cloudreve.app/Contents/MacOS/ first).
///
/// Usage:
///   fpctl list
///   fpctl add <domain-id> <display-name>
///   fpctl remove <domain-id> <display-name>

func finish(_ error: Error?, _ verb: String) -> Never {
    if let error {
        FileHandle.standardError.write(
            "error: \(verb) failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    print("ok: \(verb)")
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    FileHandle.standardError.write("usage: fpctl list|add|remove [id] [name]\n".data(using: .utf8)!)
    exit(2)
}

switch command {
case "list":
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error { finish(error, "list") }
        for d in domains {
            print("domain: \(d.identifier.rawValue) — \(d.displayName)")
        }
        exit(0)
    }
case "add", "remove":
    guard args.count >= 3 else {
        FileHandle.standardError.write(
            "usage: fpctl \(command) <domain-id> <display-name>\n".data(using: .utf8)!)
        exit(2)
    }
    let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(args[1]), displayName: args[2])
    if command == "add" {
        NSFileProviderManager.add(domain) { error in finish(error, "add") }
    } else {
        NSFileProviderManager.remove(domain) { error in finish(error, "remove") }
    }
case "signal":
    // fpctl signal <domain-id> <display-name> [container-identifier]
    guard args.count >= 3 else {
        FileHandle.standardError.write(
            "usage: fpctl signal <domain-id> <display-name> [container]\n".data(using: .utf8)!)
        exit(2)
    }
    let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(args[1]), displayName: args[2])
    let container =
        args.count >= 4
        ? NSFileProviderItemIdentifier(args[3])
        : NSFileProviderItemIdentifier.rootContainer
    guard let manager = NSFileProviderManager(for: domain) else {
        FileHandle.standardError.write("error: no manager for domain\n".data(using: .utf8)!)
        exit(1)
    }
    print("signaling \(container.rawValue)...")
    manager.signalEnumerator(for: container) { error in
        finish(error, "signal")
    }
default:
    FileHandle.standardError.write("usage: fpctl list|add|remove [id] [name]\n".data(using: .utf8)!)
    exit(2)
}

dispatchMain()
