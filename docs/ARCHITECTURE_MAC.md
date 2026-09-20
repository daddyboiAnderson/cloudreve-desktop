# macOS architecture

Cloudreve Desktop uses Apple's File Provider framework on macOS. Finder owns the
visible file hierarchy and local placeholder database; the Cloudreve desktop app
and its embedded File Provider extension cooperate to supply metadata, content,
and changes. This is intentionally different from the Windows implementation,
which maintains the sync root through the Cloud Files API.

## Components

### Desktop app

The Tauri app owns long-lived work:

- drive configuration, authentication, and token refresh;
- the Cloudreve server-sent events (SSE) connection;
- the durable SQLite inventory used for missed-event recovery;
- the JSON-lines change feed shared with the extension;
- File Provider domain registration and enumerator signalling;
- menu-bar UI, activity history, sharing, and conflict windows.

The relevant Rust code is primarily in:

- `crates/cloudreve-sync/src/drive/remote_events.rs`
- `crates/cloudreve-sync/src/drive/fileprovider_audit.rs`
- `crates/cloudreve-sync/src/fileprovider.rs`
- `crates/cloudreve-sync/src/inventory.rs`

### File Provider extension

`CloudreveFileProvider.appex` is an ExtensionKit process launched and suspended
by macOS. It must not host a permanent event listener. It handles native Finder
operations instead:

- enumerating folders and the working set;
- resolving stable item identifiers to Cloudreve URIs;
- returning placeholders and metadata;
- downloading content on demand;
- uploading Finder changes;
- renames, moves, deletes, pinning, and conflict recovery;
- replaying the change feed produced by the desktop app.

Its Swift implementation lives in `macos/fileprovider/Sources/`.

### Cloudreve server

The server remains authoritative for the remote hierarchy. SSE provides fast
notification, while ordinary list and file-info APIs provide authoritative
metadata and content. SSE is not treated as a durable replay log.

## Remote-to-Finder synchronization

The normal change path is:

1. The desktop app maintains an SSE subscription for every mounted drive.
2. A create, modify, rename, or delete event is validated and appended to
   `~/.cloudreve/fp-events/<drive-id>.jsonl`.
3. The app calls `NSFileProviderManager.signalEnumerator` for the domain's
   working-set container.
4. macOS launches or wakes the extension and calls `enumerateChanges`.
5. The extension reads events after Finder's sync anchor, resolves current
   metadata through Cloudreve, and reports updates or deletions to Finder.
6. Events are returned in pages of 100. `moreComing` asks macOS for the next
   page, preventing a large recovery delta from monopolizing the extension.

The working-set feed is domain-wide. A change is not discarded merely because
its folder has not recently appeared in Finder. This is essential for newly
created nested folder chains. Delivering metadata does not download file
contents: files remain native on-demand placeholders until macOS requests them.

When Finder opens a folder, its ordinary enumerator lists that folder directly
from Cloudreve. Consequently, the first visit always uses current server state
even if no historical event was retained.

## Missed-event recovery

SSE connections can be interrupted while the app is stopped, the network is
unavailable, or the server requests a reconnect. Cloudreve therefore does not
assume that reconnecting SSE reveals the missing interval.

On every confirmed subscription or reconnection:

1. The app records a rescan marker and signals the working set. The extension
   expires the affected anchor and quickly reconciles Finder's existing working
   set and presented folders.
2. In parallel, a metadata-only background audit walks the remote hierarchy in
   pages of 200, with a small delay between directories.
3. Each item is compared by stable remote ID with the
   `fileprovider_remote_items` SQLite table. New, modified, renamed, and deleted
   items become normal File Provider events.
4. A generation is committed only after the complete traversal succeeds.
   Deletions are never inferred from a partial or failed audit.
5. Descendant deletions are collapsed when an absent parent folder already
   represents the subtree.

The first audit after the recovery table is introduced establishes a baseline
without emitting every remote item as a new Finder entry. Later audits emit only
deltas. Received-share redirect folders are not recursively traversed because
their target hierarchy and permissions are represented separately.

The audit fetches metadata only. It does not materialize remote files locally.

## Finder-to-remote synchronization

Finder invokes the extension for local creates, modifications, moves, renames,
and deletes. The extension performs the corresponding Cloudreve operation and
returns the authoritative item metadata and stable identity. Local upload echoes
are marked in the shared change feed so the extension can avoid treating its own
operation as an unrelated remote content replacement.

Keep Downloaded state is persisted by stable item identifier. macOS remains in
charge of eviction and materialization; Cloudreve supplies content when Finder
requests it and schedules refreshes for remotely modified materialized files.

## Identity and anchors

- A File Provider domain is registered per Cloudreve drive.
- Items prefer a stable identifier derived from the Cloudreve remote ID.
- The extension persists identifier-to-URI mappings so renames preserve Finder
  identity.
- Change anchors use `evt-<timestamp>` values from the append-only JSON-lines
  feed. Timestamps are monotonic within a drive even when events arrive in the
  same millisecond.
- Rescan markers intentionally expire anchors when continuity is uncertain.

The recently presented-folder cache is an optimization for fast reconciliation,
not a correctness boundary. Increasing or decreasing its bound must never decide
whether a real remote change reaches Finder.

## Shares

Share metadata is refreshed independently from file content. The app polls share
state because current Cloudreve SSE events do not fully describe every share
addition or removal. Metadata events update Finder decorations and descriptions
without forcing content downloads. Received-share redirects are preserved as
native File Provider items and excluded from recursive recovery traversal.

## Failure behavior

- SSE uses a fresh client ID on each macOS subscription attempt and reconnects
  with bounded exponential backoff.
- An idle event stream is treated as disconnected and re-established.
- A failed recovery audit leaves the previous SQLite generation intact and is
  retried after a later reconnect.
- Large change sets are paged through `enumerateChanges`.
- Reset Finder Integration is a last-resort maintenance action. Normal upgrades,
  reconnects, and missed events must recover without deleting the domain.

## Packaging and verification

The extension must be embedded in the production Tauri `.app`, and the app and
extension must share an incremented `CFBundleVersion`:

```bash
cargo tauri build --bundles app
FP_CONFIGURATION=Release FP_BUILD_NUMBER=<number> \
  ./macos/scripts/embed-into-app.sh \
  target/release/bundle/macos/Cloudreve.app
codesign --verify --deep --strict \
  target/release/bundle/macos/Cloudreve.app
```

Do not package a raw `cargo build --release` binary as the app: it lacks Tauri's
production custom-protocol configuration and attempts to load the development
server. For local handoff, provide the `.app` bundle directly rather than a ZIP.

