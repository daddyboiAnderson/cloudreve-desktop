import FileProvider
import Foundation

/// Minimal stand-in for the Tauri app: registers/removes/lists the
/// Cloudreve file provider domain so the embedded .appex can be tested
/// without building the whole Rust workspace.
///
/// Usage:
///   TestHost register   - add the "Cloudreve Test" domain
///   TestHost remove     - remove it (deletes the local replica!)
///   TestHost list       - list registered domains

let domainID = "cloudreve-test"
let domain = NSFileProviderDomain(
    identifier: NSFileProviderDomainIdentifier(domainID),
    displayName: "Cloudreve Test")

func finish(_ error: Error?, _ verb: String) -> Never {
    if let error {
        FileHandle.standardError.write(
            "error: \(verb) failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    print("ok: \(verb)")
    exit(0)
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "register"

switch command {
case "register":
    print("registering domain '\(domainID)' (\(domain.displayName))...")
    NSFileProviderManager.add(domain) { error in
        // NSFileProviderErrorDomain error .providerNotFound etc. surface here
        finish(error, "register")
    }
case "remove":
    NSFileProviderManager.remove(domain) { error in
        finish(error, "remove")
    }
case "list":
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error {
            finish(error, "list")
        }
        for d in domains {
            print("domain: \(d.identifier.rawValue) — \(d.displayName)")
        }
        exit(0)
    }
default:
    FileHandle.standardError.write("usage: TestHost [register|remove|list]\n".data(using: .utf8)!)
    exit(2)
}

dispatchMain()
