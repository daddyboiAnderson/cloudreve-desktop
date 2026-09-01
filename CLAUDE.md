# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cloudreve Desktop is a Tauri-based Windows desktop application that synchronizes files with a Cloudreve cloud drive server using the Windows Cloud Files API (cfapi). It provides:
- Real-time bidirectional file synchronization
- On-demand file hydration (files appear locally but are downloaded only when accessed)
- Windows Explorer shell integration (context menus, thumbnails, custom states)
- Multiple storage provider support for uploads (S3, OneDrive, Qiniu, Upyun, local)
- System tray application with React-based UI

## Build Commands

```bash
# Backend (Rust) - run from project root
cargo build                    # Build all workspace crates
cargo build --release          # Release build
cargo check                    # Check for compilation errors
cargo test                     # Run all tests
cargo test --package cloudreve-sync --lib inventory::db::tests  # Run specific module tests
cargo test --package cloudreve-api  # Run API crate tests

# Frontend (React/TypeScript) - run from ui/ directory
cd ui
yarn install                   # Install dependencies
yarn dev                       # Start Vite dev server (localhost:5173)
yarn build                     # Build for production
yarn lint                      # Run ESLint

# Full Tauri Application - run from project root
cargo tauri dev                # Development mode with hot reload
cargo tauri build              # Production build
```

## Architecture

### Workspace Structure

```
├── src-tauri/           # Tauri application shell
├── crates/
│   ├── cloudreve-sync/  # Core sync service (main logic)
│   ├── cloudreve-api/   # Async REST client for Cloudreve server
│   └── win32_notif/     # Windows notification utilities
├── macos/               # macOS File Provider (NSFileProvider) integration
└── ui/                  # React frontend (Vite + MUI)
```

### macOS File Provider (`macos/`)

- `fileprovider/Sources/`: Swift `NSFileProviderReplicatedExtension` backed by the Cloudreve API — enumerates directories, downloads file contents on demand, and supports mutations (create/upload, rename, move, delete-to-trash; local/relay storage policies only). Reads `~/.cloudreve/drives.json` via a sandbox temporary-exception (local dev only; use an app group for distribution).
- On macOS, drives are **File Provider only**: `Mount::start()` is a no-op (no sync folder, no FS watcher, no initial sync), `MountCommand::Sync` is ignored, and `get_drives_info` reports the domain's user-visible URL (`~/Library/CloudStorage/...`) instead of `sync_path`.
- Remote-change feed: the app's SSE listener (`remote_events.rs`) appends events to `~/.cloudreve/fp-events/<drive-id>.jsonl` and calls `signalEnumerator(workingSet)` — the extension replays the log in `enumerateChanges`. The extension itself cannot hold a long-lived SSE connection (XPC services are suspended when idle). Only the working-set container may be signaled for replicated extensions (per NSFileProviderManager.h docs); anchors are event timestamps (`evt-<millis>`), unknown anchors yield `syncAnchorExpired` (full rescan).
- Client IDs: the app sends `X-Cr-Client-Id` derived from the drive UUID (`api_client_id` in mounts.rs) — sharing one ID across processes breaks the server-side event channel.
- `fileprovider/Support/`: appex `Info.plist` (`com.apple.fileprovider-nonui` extension point) and entitlements
- `fpctl/fpctl.swift`: generic CLI to list/add/remove FP domains; run it from inside a host app bundle to manage that bundle's domains
- `testhost/`: minimal host app for testing the extension without building the Tauri app
- `scripts/build-extension.sh`: builds the appex with raw `swiftc` (no Xcode project), ad-hoc signs it
- `scripts/embed-into-app.sh`: embeds the appex into a built `Cloudreve.app`, re-signs, refreshes LS/pluginkit — run after every `cargo tauri build --bundles app`

#### macOS synchronization and share-state rules

- Cloudreve file IDs are the canonical identity. `NSFileProviderItemIdentifier` values and persisted metadata maps must be keyed by the stable remote ID, never by a filename or path. URIs are lookup locations and may change after rename or move; update the ID-to-URI map while preserving the item identifier.
- The host app owns one SSE subscription per drive. It uses a fresh client ID for every subscription attempt, writes verified remote events to the drive's JSONL feed, and signals the working-set container. The File Provider extension replays that feed; it must not open its own long-lived SSE connection or crawl the whole drive for each event.
- Create/modify events are verified with `/file/info` before being queued. An invalid event path, a reconnect, or a missed-event gap records a rescan marker. Full reconciliation is reserved for those cases and must deliver explicit updates/deletions rather than relying on omitted working-set items disappearing.
- Finder folder enumeration is demand-driven. Record containers when Finder presents them and refresh only the root plus recently presented containers (bounded and persisted) when a working-set signal arrives. Do not add periodic full-drive polling or recursively enumerate unopened subfolders.
- Share state comes from the extended file metadata (`shared` and ownership flags), not from filenames or stale share-link UI state. The share create/edit/delete commands signal a targeted metadata refresh; remote share events use the same metadata refresh path. `makeItem` must include the share flags in `itemVersion.metadataVersion` so Finder redraws the decoration.
- When a share event has no usable source URI, use the metadata-name fallback only for already presented items. Do not guess an item's identity from a duplicate name across folders. A later directory listing or `/file/info` response is authoritative.
- Remote deletes must evict the corresponding cached item and call `didDeleteItems`. During a rescan, delete an absent item only when its parent was freshly listed or proven gone; leave unverified cached items alone until their container is opened.
- `signalEnumerator` is reliable only for the replicated working-set container. Keep the app's event log and signal flow intact; per-container signals are not a substitute for working-set invalidation.

Rust-side domain lifecycle: `crates/cloudreve-sync/src/fileprovider.rs` (one domain per drive, `NSFileProviderManager` via hand-rolled `msg_send!` since `objc2-file-provider` lacks Manager bindings; domain registration is called from `src-tauri` on startup and on add/remove drive).

#### Cloudreve API reference (up-to-date docs)

- API overview: https://docs.cloudreve.org/en/api/overview
- Events (SSE): https://docs.cloudreve.org/en/api/events
- Complete v4 API reference (Apifox): https://cloudrevev4.apifox.cn/
- Rename file endpoint: https://cloudrevev4.apifox.cn/rename-file-300254639e0

Endpoints used by the extension (all under `{instance_url}/api/v4`, auth via `Authorization: Bearer <access_token>`):
- `GET /file?uri=<cloudreve://my/...>&page_size=&next_page_token=|page=` — list directory (token- or page-based pagination)
- `GET /file/info?uri=` — file metadata (`type` 0=file/1=folder, `path` is a full `cloudreve://my/...` URI)
- `POST /file/url` `{uris, download:true}` → presigned download URLs
- `PUT /file/upload` `{uri, size, policy_id:"", entity_type:"version"?}` → upload session; chunks via `POST /file/upload/{session_id}/{index}` (local/relay policies auto-complete). Failed sessions leave file locks (error 40073) — release via `DELETE /file/lock` `{tokens:[...]}` (tokens are in the error's `data`), or cancel via `DELETE /file/upload` `{id, uri}`
- `POST /file/create` `{uri, type:"file"|"folder"}`, `POST /file/rename` `{uri, new_name}`, `POST /file/move` `{uris, dst}`, `DELETE /file` `{uris}` — mutations; DELETE without `unlink` is a soft delete (server trash; trash listing URI is `cloudreve://trash`)
- `POST /file/restore` `{uris}` — restore from trash. **Quirk:** trash items live at `cloudreve://trash/<uuid>`, and restore emits `create` events with that bogus UUID path — always verify create/modify event paths with `/file/info`; on 404, force a full rescan instead of replaying the event.
- `POST /session/token/refresh` `{refresh_token}` → new token pair
- `GET /file/events?uri=` — SSE stream (`event:` subscribed/resumed/keep-alive/reconnect-required/event; data is a JSON array of `{type: create|modify|rename|delete, file_id, from, to}`, paths relative to subscribed URI, leading slash). Requires an `X-Cr-Client-Id` header with a UUID. One live channel per client ID: reconnecting with a used ID attaches to a dead channel ("resumed") that receives nothing — always subscribe with a fresh UUID.

#### NSFileProvider implementation knowledge (hard-won)

- Replicated extensions only honor `signalEnumerator` for the **working-set container**; per-container signals are silently ignored (see NSFileProviderManager.h).
- XPC services are suspended when idle — no long-lived SSE in the extension; the app owns the event stream and shares events via `~/.cloudreve/fp-events/<drive-id>.jsonl` (JSON lines: `{ts, type, from, to}`; `type: "rescan"` forces a full rescan).
- Sync anchors are `evt-<millis>` event-log timestamps; unknown anchors → `syncAnchorExpired` → full rescan (safe recovery after extension restarts).
- Declaring the trash container unsupported (`enumerator(for: .trashContainer)` throws `NSFeatureUnsupportedError`) makes the system route Finder "Move to Trash" straight to `deleteItem`, which soft-deletes to the server trash.
- Items returned to the system must have an `itemVersion` or the extension crashes (`__FILEPROVIDER_BAD_ITEM_MISSING_ITEMVERSION__`).
- The session item cache is append-only; `workingSetItems()` seeds from it. Without pruning, remotely deleted items are resurrected on every working-set re-enumeration (which rescan markers force on each SSE reconnect) and never disappear from Finder. The working set must drop items that fresh listings prove are gone, and confirmed deletes must evict the cache (`evictCachedItems`).
- Omitting an item from a working-set re-enumeration does NOT delete it from the system mirror — only `didDeleteItems` removes items. Since a rescan marker expires the anchor and discards queued delete events, `enumerateChanges` for the working set catches anchor expiry and reconciles against the server (`reconcileWorkingSet`), delivering updates and deletions explicitly. Deletions are only reported for items whose parent container was freshly listed (or proven gone) in that pass — everything else is unverified and must be left alone.
- "Keep Downloaded" uses `contentPolicy`, custom File Provider actions, and `userInfo` activation keys. Pin state is persisted per drive; actions refresh the working set, request downloads for known files, and explicitly evict content when unpinned. Effective pins receive the File Provider badge from the appex resources.
- Keep Downloaded queues policy updates in `pending-pinned-<drive-id>.json` and uses `~/Library/Application Support/CloudreveFileProvider/` because the extension cannot write to the shared event log. Await download/eviction retries inside the action's XPC call.

macOS development notes:
- The dev build uses bundle id `cloudreve.desktop.dev` so it never clashes with an installed `/Applications/Cloudreve.app` (`NSFileProviderManager` resolves providers per host bundle id).
- New File Provider domains start **user-disabled**; enable once in System Settings → General → Login Items & Extensions → File Providers.
- `pluginkit -a <appex>` is needed to register hand-built extensions; `fileproviderctl dump <domain>` shows sync engine state.
- `log` is a zsh builtin — use `/usr/bin/log stream --predicate 'subsystem == "cloudreve.desktop.dev.fileprovider"'` for extension logs.

#### macOS upgrade-safe build procedure

Never distribute the raw bundle produced by `cargo tauri build`/`tauri build`: it does not contain the current File Provider extension. Build the Tauri app, then embed and re-sign the extension with one shared, monotonically increasing numeric build number:

```bash
npx --yes @tauri-apps/cli@2.11.4 build --bundles app
FP_CONFIGURATION=Release FP_SHORT_VERSION=0.2.0 FP_BUILD_NUMBER=<new-number> \
  FP_REGISTER_EXTENSION=0 ./macos/scripts/embed-into-app.sh \
  target/release/bundle/macos/Cloudreve.app
```

- Increase `FP_BUILD_NUMBER` for every packaged macOS update, including test replacements. Do not reuse or decrease it for an upgrade build.
- `embed-into-app.sh` stamps the same `CFBundleVersion` and `CFBundleShortVersionString` into the host app and embedded `.appex`, then re-signs the bundle. Keep those versions matched.
- Use `FP_REGISTER_EXTENSION=0` when creating a package; register only when intentionally testing that exact local bundle.
- Do not create a new File Provider domain identifier during an app upgrade or reset. Existing drives depend on the stable `cloudreve.drive.<drive UUID>` identifier for remote-event delivery.
- If macOS retains stale registration after an ad-hoc replacement, use the app's **Reset Finder Integration** action; do not add automatic domain replacement or alter sync anchors/event processing as an upgrade workaround.
- Before handing off a build, verify both plist build numbers and run `codesign --verify --deep --strict Cloudreve.app`.

### Tauri Layer (`src-tauri/`)

- `lib.rs`: Application entry, initializes sync service, sets up system tray, spawns event bridge
- `commands.rs`: Tauri IPC commands exposed to frontend (`list_drives`, `add_drive`, `remove_drive`, etc.)
- `event_handler.rs`: Bridges `EventBroadcaster` events to Tauri frontend events

**Initialization Flow**: App starts → system tray setup → async `init_sync_service()` spawned → DriveManager created → shell services initialized → event bridge connects EventBroadcaster to Tauri

### Core Sync Module (`crates/cloudreve-sync/`)

**Drive Management:**
- `drive/manager.rs`: Central `DriveManager` coordinating all mounted drives via command channel
- `drive/mounts.rs`: Individual mount point (`Mount`) handling
- `drive/callback.rs`: Windows Cloud Filter callbacks (`SyncFilter` trait)
- `drive/sync.rs`: Sync logic and placeholder/metadata conversion
- `drive/remote_events.rs`: SSE handling for server-pushed changes

**Windows Cloud Files API (`cfapi/`):**
- `filter/`: Callback traits (`SyncFilter`, `Filter`) and request handling
- `placeholder.rs`, `placeholder_file.rs`: Cloud file placeholder management
- `root/`: Sync root registration and connection

**Persistence (`inventory/`):**
- SQLite via Diesel ORM at `~/.cloudreve/meta.db`
- Stores file metadata, task queue, upload sessions, drive properties
- Migrations in `migrations/inventory/`

**Uploads (`uploader/`):**
- Chunked upload with provider backends: S3, OneDrive, Qiniu, Upyun, local
- Encryption and resumable upload support

**Shell Extensions (`shellext/`):**
- Context menus, thumbnails, custom file states, status UI
- `shell_service.rs`: COM-based Windows Explorer integration

### Frontend (`ui/`)

React 19 + TypeScript + MUI + Vite application:
- `src/pages/popup/`: Main tray popup (drive list, task progress)
- `src/pages/AddDrive.tsx`: Add drive wizard
- `src/pages/settings/`: Settings pages
- i18n via react-i18next, translations in `ui/public/locales/`

### Key Patterns

**Command Channels**: `DriveManager` and `Mount` use `mpsc::UnboundedSender` for async command dispatch from shell extensions and Tauri commands.

**Callback Threading**: Windows Cloud Filter callbacks run on OS threads, using `blocking_recv()` on oneshot channels to await async operations.

**Event Broadcasting**: `EventBroadcaster` (tokio broadcast channel) pushes events to both the Tauri frontend (via event bridge) and any SSE subscribers.

**Global State**: `APP_STATE` (tokio `OnceCell`) holds initialized `DriveManager`, `EventBroadcaster`, and service handles for the application lifetime.

## Windows-Specific Notes

- Requires Windows Cloud Files API (`windows` crate with extensive feature flags in Cargo.toml)
- COM shell extensions for Explorer integration
- Deep link protocol: `cloudreve://`
- Single instance enforcement via `tauri-plugin-single-instance`

## Database Migrations

Migrations are embedded and run automatically on startup. To add a new migration:
1. Create folder in `migrations/inventory/` (e.g., `0005_new_table/`)
2. Add `up.sql` and `down.sql` files
3. Use idempotent SQL (`IF NOT EXISTS`) for clean upgrades

## Localization

- Backend: `rust-i18n` macro with translations in `locales/`
- Frontend: `react-i18next` with translations in `ui/public/locales/{locale}/common.json`
