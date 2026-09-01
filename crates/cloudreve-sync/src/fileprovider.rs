//! macOS File Provider (NSFileProvider) domain management.
//!
//! Registers one `NSFileProviderDomain` per configured drive. The domains are
//! served by the embedded `CloudreveFileProvider.appex` in `Contents/PlugIns`
//! of the app bundle, which materializes the drive contents in Finder under
//! `~/Library/CloudStorage/<AppName>-<DomainName>`.
//!
//! `objc2-file-provider` does not generate bindings for `NSFileProviderManager`
//! yet, so the (few) manager calls are hand-rolled with `msg_send!`.

#![cfg(target_os = "macos")]

use std::sync::{Mutex, OnceLock};

use anyhow::{anyhow, Context, Result};
use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{class, msg_send, AllocAnyThread};
use objc2_file_provider::NSFileProviderDomain;
use objc2_foundation::{NSArray, NSError, NSString, NSURL};
use tokio::sync::oneshot;

use crate::{DriveConfig, FileProviderStatus};

/// Prefix for domain identifiers owned by this app, so we never touch
/// domains registered by other providers (iCloud, Nextcloud, ...).
const DOMAIN_PREFIX: &str = "cloudreve.drive.";

pub fn domain_identifier(drive_id: &str) -> String {
    format!("{DOMAIN_PREFIX}{drive_id}")
}

fn make_domain(id: &str, display_name: &str) -> Retained<NSFileProviderDomain> {
    let identifier = NSString::from_str(id);
    let name = NSString::from_str(display_name);
    unsafe {
        NSFileProviderDomain::initWithIdentifier_displayName(
            NSFileProviderDomain::alloc(),
            &identifier,
            &name,
        )
    }
}

/// The raw value of `NSFileProviderRootContainerItemIdentifier`
/// (used when signaling changes at the drive root).
pub const ROOT_CONTAINER: &str = "NSFileProviderRootContainerItemIdentifier";

/// Returns the user-visible location of a drive's File Provider domain
/// (e.g. `~/Library/CloudStorage/Cloudreve-<name>`), if the domain is
/// registered and active.
pub async fn user_visible_url(domain_id: &str, display_name: &str) -> Option<String> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let root = NSString::from_str(ROOT_CONTAINER);
        let block = RcBlock::new(move |url: *mut NSURL, _error: *mut NSError| {
            let path = if url.is_null() {
                None
            } else {
                unsafe { (*url).path() }.map(|p| p.to_string())
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(path);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return None;
            }
            let _: () = msg_send![
                &*manager,
                getUserVisibleURLForItemIdentifier: &*root,
                completionHandler: &*block
            ];
        }
    }
    rx.await.ok().flatten()
}

/// The raw value of `NSFileProviderWorkingSetContainerItemIdentifier`.
pub const WORKING_SET_CONTAINER: &str = "NSFileProviderWorkingSetContainerItemIdentifier";

fn canonical_fileprovider_uri(uri: &str) -> String {
    urlencoding::decode(uri)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| uri.to_string())
}

// MARK: - Shared event log

/// One recorded remote event. Serialized as JSON lines, one per line, in
/// `~/.cloudreve/fp-events/<drive-id>.jsonl`. The file provider extension
/// reads this file to answer `enumerateChanges` precisely (it cannot run a
/// long-lived SSE listener itself: XPC services get suspended when idle).
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct FpEventRecord {
    /// Unix epoch milliseconds when the app received the event.
    pub ts: i64,
    #[serde(rename = "type")]
    pub event_type: String,
    /// Relative event path, or an absolute Cloudreve URI for metadata events.
    pub from: String,
    #[serde(default)]
    pub to: String,
}

static EVENT_LOG_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
const MAX_EVENT_LOG_BYTES: u64 = 256 * 1024;

fn trim_event_log_if_needed(path: &std::path::Path, file: std::fs::File) -> Result<()> {
    if file.metadata()?.len() <= MAX_EVENT_LOG_BYTES {
        return Ok(());
    }
    drop(file);
    let content = std::fs::read_to_string(path)?;
    let all: Vec<&str> = content.lines().collect();
    let keep = &all[all.len().saturating_sub(500)..];
    std::fs::write(path, keep.join("\n") + "\n")?;
    Ok(())
}

fn next_event_timestamp(path: &std::path::Path) -> Result<i64> {
    let latest = match std::fs::read_to_string(path) {
        Ok(content) => content
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<FpEventRecord>(line).ok())
            .map(|record| record.ts)
            .unwrap_or_default(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        Err(error) => return Err(error.into()),
    };
    Ok(chrono::Utc::now()
        .timestamp_millis()
        .max(latest.saturating_add(1)))
}

fn events_dir() -> Result<std::path::PathBuf> {
    let home = dirs::home_dir().context("Failed to get user home directory")?;
    Ok(home.join(".cloudreve").join("fp-events"))
}

/// Ask the next extension process to discard its local identity and pin state.
pub fn request_local_state_reset(drive_id: &str) -> Result<()> {
    let home = dirs::home_dir().context("Failed to get user home directory")?;
    let dir = home.join(".cloudreve").join("fp-reset");
    std::fs::create_dir_all(&dir)?;
    let token = format!("{}-{}\n", chrono::Utc::now().timestamp_millis(), uuid::Uuid::new_v4());
    std::fs::write(dir.join(format!("{drive_id}.marker")), token)?;
    Ok(())
}

/// Append remote events to the drive's FP event log, keeping the file bounded.
pub fn append_domain_events(
    drive_id: &str,
    events: &[cloudreve_api::models::explorer::FileEventData],
) -> Result<()> {
    use std::io::Write;
    let _guard = EVENT_LOG_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap();

    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));

    let now = next_event_timestamp(&path)?;
    let mut lines = String::new();
    for (i, e) in events.iter().enumerate() {
        let record = FpEventRecord {
            ts: now + i as i64, // preserve order within the batch
            event_type: format!("{:?}", e.event_type).to_lowercase(),
            from: e.from.clone(),
            to: e.to.clone(),
        };
        lines.push_str(&serde_json::to_string(&record)?);
        lines.push('\n');
    }

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    file.write_all(lines.as_bytes())?;

    trim_event_log_if_needed(&path, file)?;
    Ok(())
}

/// Append a "rescan" marker: tells the extension its change log can't be
/// trusted past this point (e.g. the SSE stream was down), forcing a full
/// rescan via `syncAnchorExpired`.
pub fn append_rescan_marker(drive_id: &str) -> Result<()> {
    use std::io::Write;
    let _guard = EVENT_LOG_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap();

    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));
    let record = FpEventRecord {
        ts: next_event_timestamp(&path)?,
        event_type: "rescan".to_string(),
        from: String::new(),
        to: String::new(),
    };
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{}", serde_json::to_string(&record)?)?;
    trim_event_log_if_needed(&path, file)?;
    Ok(())
}

/// Record metadata-only changes, such as a share being added or removed.
pub fn append_metadata_events(drive_id: &str, source_uris: &[String]) -> Result<()> {
    use std::io::Write;

    if source_uris.is_empty() {
        let _guard = EVENT_LOG_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap();
        let dir = events_dir()?;
        std::fs::create_dir_all(&dir)?;
        let path = dir.join(format!("{drive_id}.jsonl"));
        let record = FpEventRecord {
            ts: next_event_timestamp(&path)?,
            event_type: "metadata_rescan".to_string(),
            from: String::new(),
            to: String::new(),
        };
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        writeln!(file, "{}", serde_json::to_string(&record)?)?;
        trim_event_log_if_needed(&path, file)?;
        return Ok(());
    }
    let _guard = EVENT_LOG_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap();

    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));
    let now = next_event_timestamp(&path)?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;

    for (index, source_uri) in source_uris.iter().enumerate() {
        let record = FpEventRecord {
            ts: now + index as i64,
            event_type: "metadata".to_string(),
            from: source_uri.clone(),
            to: String::new(),
        };
        writeln!(file, "{}", serde_json::to_string(&record)?)?;
    }

    trim_event_log_if_needed(&path, file)?;
    Ok(())
}

/// Record share changes by filename when Cloudreve omits the source URI.
pub fn append_metadata_name_events(drive_id: &str, names: &[String]) -> Result<()> {
    use std::io::Write;
    if names.is_empty() { return Ok(()); }
    let _guard = EVENT_LOG_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap();
    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));
    let now = next_event_timestamp(&path)?;
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    for (index, name) in names.iter().enumerate() {
        let record = FpEventRecord {
            ts: now + index as i64,
            event_type: "metadata_name".to_string(),
            from: name.clone(),
            to: String::new(),
        };
        writeln!(file, "{}", serde_json::to_string(&record)?)?;
    }
    trim_event_log_if_needed(&path, file)?;
    Ok(())
}

/// Tell the system that new content is available in the given containers of a
/// drive's File Provider domain. The system then asks the extension for
/// changes (launching it if needed).
pub fn signal_containers(domain_id: &str, display_name: &str, containers: &[String]) {
    let domain = make_domain(domain_id, display_name);
    unsafe {
        let manager: *mut AnyObject =
            msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
        if manager.is_null() {
            tracing::warn!(target: "fileprovider", "no NSFileProviderManager for domain {domain_id} (not registered?)");
            return;
        }
        for container in containers {
            let identifier = NSString::from_str(container);
            let container_log = container.clone();
            let block = RcBlock::new(move |error: *mut NSError| {
                if !error.is_null() {
                    let desc = (*error).localizedDescription();
                    tracing::warn!(target: "fileprovider", "signalEnumerator({container_log}) failed: {desc}");
                } else {
                    tracing::info!(target: "fileprovider", "signalEnumerator({container_log}) completed");
                }
            });
            let _: () = msg_send![
                &*manager,
                signalEnumeratorForContainerItemIdentifier: &*identifier,
                completionHandler: &*block
            ];
        }
    }
}

/// Refresh shared metadata in the replicated working set.
pub fn signal_metadata_refresh(drive_id: &str, display_name: &str, source_uris: &[String]) {
    let canonical_uris = source_uris
        .iter()
        .map(|uri| canonical_fileprovider_uri(uri))
        .collect::<Vec<_>>();

    if let Err(error) = append_metadata_events(drive_id, &canonical_uris) {
        tracing::warn!(
            target: "fileprovider",
            error = %error,
            "Failed to record metadata refresh"
        );
    }

    let mut containers = vec![WORKING_SET_CONTAINER.to_string()];
    for uri in &canonical_uris {
        let trimmed = uri.trim_end_matches('/');
        let parent = trimmed
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let container = if parent.is_empty() || parent == "cloudreve:" || parent == "cloudreve://my"
        {
            ROOT_CONTAINER.to_string()
        } else {
            parent.to_string()
        };
        if !containers.contains(&container) {
            containers.push(container);
        }
    }

    signal_containers(&domain_identifier(drive_id), display_name, &containers);
}

pub fn signal_metadata_name_refresh(drive_id: &str, display_name: &str, names: &[String]) {
    if let Err(error) = append_metadata_name_events(drive_id, names) {
        tracing::warn!(target: "fileprovider", error = %error, "Failed to record named metadata refresh");
    }
    signal_containers(
        &domain_identifier(drive_id), display_name,
        &[WORKING_SET_CONTAINER.to_string()],
    );
}

fn describe_error(error: *mut NSError) -> anyhow::Error {
    if error.is_null() {
        return anyhow!("unknown FileProvider error");
    }
    let (domain, code, desc) = unsafe {
        (
            (*error).domain().to_string(),
            (*error).code(),
            (*error).localizedDescription().to_string(),
        )
    };
    anyhow!("{desc} (domain: {domain}, code: {code})")
}

/// List domains currently registered by this app process's bundle.
pub async fn list_domains() -> Result<Vec<(String, String)>> {
    let (tx, rx) = oneshot::channel();
    // Non-Send ObjC objects (block) are confined to this scope; the ObjC
    // runtime copies the completion handler, so it outlives our RcBlock.
    {
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(
            move |domains: *mut NSArray<NSFileProviderDomain>, error: *mut NSError| {
                let result = if !error.is_null() {
                    Err(describe_error(error))
                } else if domains.is_null() {
                    Ok(Vec::new())
                } else {
                    let domains = unsafe { &*domains };
                    Ok(domains
                        .iter()
                        .map(|d| unsafe {
                            (d.identifier().to_string(), d.displayName().to_string())
                        })
                        .collect())
                };
                if let Some(tx) = tx.lock().unwrap().take() {
                    let _ = tx.send(result);
                }
            },
        );
        unsafe {
            let _: () = msg_send![
                class!(NSFileProviderManager),
                getDomainsWithCompletionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("domain list callback dropped"))?
}

/// Register a new domain. Errors if the domain already exists.
pub async fn add_domain(domain_id: &str, display_name: &str) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let _: () = msg_send![
                class!(NSFileProviderManager),
                addDomain: &*domain,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("addDomain callback dropped"))?
}

/// Remove a domain. WARNING: this deletes the local replica of the domain
/// (the folder under ~/Library/CloudStorage). Locally modified but not yet
/// uploaded ("dirty") items are preserved by the system; clean downloaded
/// content is discarded so a fresh domain cannot re-ingest stale downloads
/// as new uploads (the legacy removeDomain API preserves downloaded data).
pub async fn remove_domain(domain_id: &str, display_name: &str) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(
            move |_preserved_location: *mut NSURL, error: *mut NSError| {
                let result = if error.is_null() {
                    Ok(())
                } else {
                    Err(describe_error(error))
                };
                if let Some(tx) = tx.lock().unwrap().take() {
                    let _ = tx.send(result);
                }
            },
        );
        unsafe {
            // NSFileProviderDomainRemovalModePreserveDirtyUserData = 1
            let _: () = msg_send![
                class!(NSFileProviderManager),
                removeDomain: &*domain,
                mode: 1isize,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("removeDomain callback dropped"))?
}

/// Tell macOS whether the host application is available for a registered
/// domain. Disconnecting keeps downloaded files visible, but prevents Finder
/// from asking the extension to enumerate or mutate remote content and shows
/// the localized reason at the top of the domain.
async fn set_domain_connected(domain_id: &str, display_name: &str, connected: bool) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            if connected {
                let _: () = msg_send![&*manager, reconnectWithCompletionHandler: &*block];
            } else {
                let reason = NSString::from_str(
                    "Cloudreve application has been closed. Reopen to reconnect.",
                );
                let _: () = msg_send![
                    &*manager,
                    disconnectWithReason: &*reason,
                    options: 0usize,
                    completionHandler: &*block
                ];
            }
        }
    }
    rx.await
        .map_err(|_| anyhow!("domain connection callback dropped"))?
}

/// Update all enabled domains without changing their identifiers, sync
/// anchors, event logs, or local replicas.
pub async fn set_domains_connected(drives: &[DriveConfig], connected: bool) {
    for drive in drives.iter().filter(|drive| drive.enabled) {
        let id = domain_identifier(&drive.id);
        if let Err(error) = set_domain_connected(&id, &drive.name, connected).await {
            tracing::warn!(
                target: "fileprovider",
                domain = %id,
                connected,
                error = %error,
                "failed to update File Provider connection state"
            );
        }
    }
}

/// Lightweight status for Drive Settings. This deliberately checks only the
/// stable domain registration and leaves enumeration and sync behavior alone.
pub async fn domain_status(drive_id: &str, display_name: &str) -> FileProviderStatus {
    let id = domain_identifier(drive_id);
    match list_domains().await {
        Ok(domains) if domains.iter().any(|(registered, _)| registered == &id) => {
            match probe_domain(&id, display_name).await {
                Ok(()) => FileProviderStatus {
                    connected: true,
                    message: None,
                },
                Err(error) => FileProviderStatus {
                    connected: false,
                    message: Some(format!(
                        "Finder domain is registered but not responding: {error:#}"
                    )),
                },
            }
        }
        Ok(_) => FileProviderStatus {
            connected: false,
            message: Some(format!(
                "Finder domain is not registered ({id}). Reset Finder Integration to add it again."
            )),
        },
        Err(error) => FileProviderStatus {
            connected: false,
            message: Some(format!("Could not inspect Finder integration: {error:#}")),
        },
    }
}

/// Signal the existing working-set enumerator and keep the native error code.
/// This uses the same signal already used for remote changes and does not alter
/// anchors, identities, or event processing.
async fn probe_domain(domain_id: &str, display_name: &str) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let identifier = NSString::from_str(WORKING_SET_CONTAINER);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            let _: () = msg_send![
                &*manager,
                signalEnumeratorForContainerItemIdentifier: &*identifier,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider status callback dropped"))?
}

/// Reconcile registered File Provider domains with the configured drives:
/// add domains for new drives, remove domains whose drive is gone.
/// Errors are logged, not propagated: file provider integration is best-effort.
pub async fn sync_domains_with_drives(drives: &[DriveConfig]) {
    let registered = match list_domains().await {
        Ok(domains) => domains,
        Err(e) => {
            tracing::warn!(target: "fileprovider", "failed to list FP domains: {e:#}");
            return;
        }
    };

    tracing::info!(
        target: "fileprovider",
        "FP sync: registered={registered:?}, drives={:?}",
        drives.iter().map(|d| (&d.id, &d.name, d.enabled)).collect::<Vec<_>>()
    );

    let wanted: Vec<(&DriveConfig, String)> = drives
        .iter()
        .filter(|d| d.enabled)
        .map(|d| (d, domain_identifier(&d.id)))
        .collect();

    // Remove stale domains (ours, but drive no longer configured)
    for (id, name) in &registered {
        if id.starts_with(DOMAIN_PREFIX) && !wanted.iter().any(|(_, wid)| wid == id) {
            tracing::info!(target: "fileprovider", "removing stale FP domain {id} ({name})");
            if let Err(e) = remove_domain(id, name).await {
                tracing::warn!(target: "fileprovider", "failed to remove FP domain {id}: {e:#}");
            }
        }
    }

    // Add missing domains
    for (drive, id) in &wanted {
        if registered.iter().any(|(rid, _)| rid == id) {
            continue;
        }
        tracing::info!(target: "fileprovider", "registering FP domain {id} ({})", drive.name);
        if let Err(e) = add_domain(id, &drive.name).await {
            tracing::warn!(target: "fileprovider", "failed to add FP domain {id}: {e:#}");
        }
    }

    // A normal app quit leaves the registered domain in a persistent native
    // disconnected state. Reconnect only after domain reconciliation and the
    // app-owned event service have started again.
    set_domains_connected(drives, true).await;
}
