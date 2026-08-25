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

use std::sync::Mutex;

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
/// For replicated extensions this is the *only* container the system accepts
/// in `signalEnumerator` — other container identifiers are ignored.
pub const WORKING_SET_CONTAINER: &str = "NSFileProviderWorkingSetContainerItemIdentifier";

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
    /// Path relative to the drive root, leading slash.
    pub from: String,
    #[serde(default)]
    pub to: String,
}

fn events_dir() -> Result<std::path::PathBuf> {
    let home = dirs::home_dir().context("Failed to get user home directory")?;
    Ok(home.join(".cloudreve").join("fp-events"))
}

/// Append remote events to the drive's FP event log, keeping the file bounded.
pub fn append_domain_events(
    drive_id: &str,
    events: &[cloudreve_api::models::explorer::FileEventData],
) -> Result<()> {
    use std::io::Write;

    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));

    let now = chrono::Utc::now().timestamp_millis();
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

    // Keep the log bounded: rewrite with the tail when it grows past 256 KiB.
    const MAX_BYTES: u64 = 256 * 1024;
    if file.metadata()?.len() > MAX_BYTES {
        drop(file);
        let content = std::fs::read_to_string(&path)?;
        let all: Vec<&str> = content.lines().collect();
        let keep = &all[all.len().saturating_sub(500)..];
        std::fs::write(&path, keep.join("\n") + "\n")?;
    }
    Ok(())
}

/// Append a "rescan" marker: tells the extension its change log can't be
/// trusted past this point (e.g. the SSE stream was down), forcing a full
/// rescan via `syncAnchorExpired`.
pub fn append_rescan_marker(drive_id: &str) -> Result<()> {
    use std::io::Write;

    let dir = events_dir()?;
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{drive_id}.jsonl"));
    let record = FpEventRecord {
        ts: chrono::Utc::now().timestamp_millis(),
        event_type: "rescan".to_string(),
        from: String::new(),
        to: String::new(),
    };
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{}", serde_json::to_string(&record)?)?;
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
                        .map(|d| unsafe { (d.identifier().to_string(), d.displayName().to_string()) })
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
    rx.await.map_err(|_| anyhow!("domain list callback dropped"))?
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
    rx.await.map_err(|_| anyhow!("addDomain callback dropped"))?
}

/// Remove a domain. WARNING: this deletes the local replica of the domain
/// (the folder under ~/Library/CloudStorage).
pub async fn remove_domain(domain_id: &str, display_name: &str) -> Result<()> {
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
                removeDomain: &*domain,
                completionHandler: &*block
            ];
        }
    }
    rx.await.map_err(|_| anyhow!("removeDomain callback dropped"))?
}

/// Remove a domain while asking macOS to preserve dirty local data.
/// Returns the folder containing preserved data when macOS creates one.
pub async fn remove_domain_preserving_dirty_data(
    domain_id: &str,
    display_name: &str,
) -> Result<Option<String>> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |url: *mut NSURL, error: *mut NSError| {
            let result = if !error.is_null() {
                Err(describe_error(error))
            } else if url.is_null() {
                Ok(None)
            } else {
                Ok(unsafe { (*url).path() }.map(|path| path.to_string()))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            // NSFileProviderDomainRemovalModePreserveDirtyUserData = 1.
            let _: () = msg_send![
                class!(NSFileProviderManager),
                removeDomain: &*domain,
                mode: 1isize,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("removeDomain preserving data callback dropped"))?
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
}
