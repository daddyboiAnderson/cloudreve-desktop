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
- the transactional SQLite change journal shared with the extension;
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
2. A create, modify, rename, or delete event is validated and committed to
   `~/.cloudreve/fileprovider.db` before the app signals Finder. Upload receipts
   are acknowledged in that same transaction, preserving local-upload echo
   handling if a write fails.
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
4. Each page updates inventory and inserts its outgoing events into an outbox
   in the same `meta.db` transaction. The outbox delivers to `fileprovider.db`
   using unique batch IDs, making retries after a crash idempotent. Deletions
   are inferred only after the complete traversal succeeds, and their events
   are queued in the same transaction that removes the inventory rows.
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
- Change anchors retain the compatible `evt-<number>` encoding. The database
  allocates increasing sequence numbers per drive, at least as large as the
  current millisecond timestamp. Legacy event timestamps are imported unchanged.
- The journal retains the latest 100,000 events per drive. Pruning and its
  minimum valid anchor are committed together. An older or future anchor
  explicitly expires; unread database errors fail enumeration instead of
  advancing an anchor. Event records and the journal head are read in one
  consistent snapshot.
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
- A failed recovery audit never infers deletions from a partial traversal.
  Already processed pages remain durable with their outgoing events. Audits
  retry automatically with backoff, including while SSE remains connected.
- Failed live-event journal writes retry the received batch with backoff.
- Large change sets are paged through `enumerateChanges`.
- Reset Finder Integration is a last-resort maintenance action. Normal upgrades,
  reconnects, and missed events must recover without deleting the domain.

## Persistent state and migration

`meta.db` belongs to the Rust inventory layer. `fileprovider.db` is the smaller,
versioned contract shared by the host and extension. It uses SQLite WAL mode,
FULL synchronous durability, a five-second busy timeout, and short transactions.
There is no network work inside a shared-database transaction. The canonical
schema is `macos/fileprovider/state-schema.sql`; the standalone Swift build
embeds an equivalent schema, with cross-language schema parity tests.

The shared database contains:

- `fp_event_heads` and `fp_events`: per-drive sequence, retention floor, and
  ordered event payloads;
- `fp_deliveries`: deduplication tokens for inventory outbox batches;
- `fp_records`: namespaced records for activity, pending errors, upload
  receipts, retry/pin requests, conflict metadata/actions, share baselines,
  and explicit reset requests;
- `fp_imports`: completed legacy-directory imports.

Snapshots and small request payloads retain their existing JSON encoding inside
database rows; they no longer require one file per record. Conflict read/modify/
write operations and activity updates use cross-process transactions. Pending
errors remain a snapshot of macOS-owned pending items, not a replacement queue.
Finder still owns materialization and transfer scheduling.

Legacy directories are imported once within transactions. Starting in 0.2.1 the
host removes recognized legacy metadata files after the import commits; import
markers prevent consumed requests from being re-imported. Failed imports retain
their sources and retry on a later launch. They are not active mirrors and must
not be copied over the database.
Do not run old and new app builds simultaneously during migration. A rollback
to the old file-based build cannot see new database-only requests.

Destructive reset commands are an exception: new explicit requests use
`fp-reset-requests-v2`. Historical `fp-reset` files/rows are never executed.
Build 181 incorrectly replayed those commands during import. Build 183 performs
a one-time repair for affected domains using macOS's materialized-item enumerator:
it restores identity paths from the native parent/name hierarchy, attempts to
recover pins from retained metadata, then requeues metadata received after the
accidental reset. If custom userInfo is absent but contentPolicy or the extension's
persisted `#kd` metadata marker is exposed, it restores the topmost Keep Downloaded
policy roots without promoting every inherited child to a separate pin.
On the affected macOS 27 installation, the native enumerator omitted all pin-policy
fields: identity recovery succeeded, but pins required a targeted restoration
from Finder's diagnostic `cp:keepDownloaded` state. Automatic pin recovery is
therefore best-effort, not guaranteed. Never infer pins merely from downloaded
contents. Missing parent identities are also resolved through authoritative
server metadata and published top-down before child updates in normal change
replay. This prevents new nested items from waiting indefinitely for a parent
whose guessed URI identifier differs from Finder's stable remote identifier.

The extension's private identity/pin/policy snapshots remain in its own container
in this migration; preserving them avoids changing Finder identity or resetting
the domain. Logs, icons, backups, content, and drive configuration remain files.
Unknown files, symlinks, nonempty unknown directories and manual backups are not
deleted automatically. Cleanup never recursively deletes a directory.

### Cleaning up a migrated installation

The host runs `StateDb::migrate_and_cleanup` before loading drives. It imports
record namespaces, including historical reset markers as inert recovery data,
then removes recognized source files. Inactive drives' UUID-named event logs are
also imported before removal. Historical `fp-health` records are archived in
the database but never executed. Live databases, configuration, logs, icons and
the extension's private state are outside the cleanup allowlist. Older and newer
builds must not run simultaneously.

For manual cleanup of pre-0.2.1 builds, after confirming the installed host and
extension use the database-backed build,
check `PRAGMA quick_check`, completed namespaces in `fp_imports`, and the active
drive's `fp_event_heads.imported` flag. Legacy directories can then be moved to a
dated backup outside `~/.cloudreve`; preserve unimported historical drives there
rather than treating them as current events. An empty legacy request directory
has no payload to migrate. Do not delete database import markers or re-submit
archived reset/pin requests.

The expected active directory contains:

- `drives.json`: drive configuration;
- `meta.db`: host inventory and recovery outbox;
- `fileprovider.db`: shared journal and operational records;
- `icos/` and `logs/`: icons and diagnostic logs.

SQLite may also create `-wal`, `-shm`, or journal sidecars. These are active
database files, not cleanup candidates. Never move them independently of their
database. The extension's private container and Finder's domain are not part of
this cleanup; keep their identity, pin, and policy state intact.

Legacy archive candidates are `fileprovider-activity`,
`fileprovider-download-retries`, `fileprovider-pending`,
`fileprovider-upload-receipts`, `fp-events`, `fp-health`, `fp-reset`,
`fp-share-state`, `pin-requests`, and `upload-conflicts`, plus existing manual
backups. Archiving is reversible, but restoring these files alone does not roll
back the database migration. Do not launch an older build against this cleaned
installation as a verification step.

Verify database integrity and retained Finder entries after cleanup. A fresh
remote change appearing in Finder is the end-to-end sync check; merely removing
legacy folders or seeing an existing placeholder does not prove event delivery.

Current development signing uses temporary sandbox exceptions for the shared
database and its WAL/SHM/journal sidecars, plus legacy paths needed for import.
A distributed build should move shared storage to an entitled App Group using
a configured signing team. This migration does not change the signing identity
or pretend that an App Group is available to the current ad-hoc build.

Validation includes:

```bash
bash macos/scripts/test-state-database.sh
bash macos/scripts/test-pin-requests.sh
bash macos/scripts/test-file-provider-activity.sh
cargo test -p cloudreve-sync --lib fileprovider
```

These tests use isolated temporary databases and cover migration, transaction
rollback, concurrent writers, receipt acknowledgement, outbox deduplication,
Rust/Swift interoperability, retention floors, and Finder's 100-event pages.

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
Public releases use a DMG for installation and a separately signed `.app.tar.gz`
for the updater; both contain the same final embedded bundle. See
[`RELEASING.md`](RELEASING.md) for the required packaging and publication order.

## Production identity and updates (0.2.1)

The app uses `cloudreve.desktop` and the extension uses
`cloudreve.desktop.fileprovider`. Users upgrading from `.dev` builds must
reconnect and reapply Keep Downloaded selections; see
[`releases/0.2.1.md`](releases/0.2.1.md). This transition does not delete the old
extension container or Finder content. The old login preference is migrated to
the new LaunchAgent filename when the recognized legacy entry exists.

Settings → About checks this fork's GitHub `latest.json` over HTTPS. The host
retains the checked update and verifies its package with the pinned public key
before installation. It accepts initial download URLs only under this repository's
GitHub release path. An operation lock prevents overlapping checks/installs. The
user explicitly approves installation and is asked to save and close documents;
after installation the host shuts down its sync service and restarts. Windows
retains its existing package-managed update mechanism and Explorer integration.

Updater signatures are not Apple code-signing certificates. Current ad-hoc
releases are not notarized and cannot promise that security warnings appear only
once. No Gatekeeper or quarantine bypass is implemented.
