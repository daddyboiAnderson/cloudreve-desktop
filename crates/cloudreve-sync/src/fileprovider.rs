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

use std::{
    collections::HashMap,
    ffi::CString,
    fs::File,
    io::Read,
    mem::MaybeUninit,
    ptr::NonNull,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, class, msg_send};
use objc2_file_provider::NSFileProviderDomain;
use objc2_foundation::{
    NSArray, NSError, NSFileCoordinator, NSFileCoordinatorReadingOptions, NSRange, NSString, NSURL,
};
use tokio::sync::oneshot;

use crate::{DriveConfig, FileProviderStatus};

/// Prefix for domain identifiers owned by this app, so we never touch
/// domains registered by other providers (iCloud, Nextcloud, ...).
const DOMAIN_PREFIX: &str = "cloudreve.drive.";
const DOWNLOAD_RETRY_DIRECTORY: &str = "fileprovider-download-retries";
const ACTIVITY_DIRECTORY: &str = "fileprovider-activity";
const UPLOAD_RECEIPT_DIRECTORY: &str = "fileprovider-upload-receipts";

#[derive(Debug, Clone, serde::Deserialize)]
pub struct FileProviderActivityRecord {
    pub id: String,
    pub drive_id: String,
    pub operation: String,
    pub uri: String,
    pub item_identifier: String,
    pub filename: String,
    pub status: String,
    pub total_bytes: i64,
    pub processed_bytes: i64,
    pub speed_bytes_per_sec: i64,
    pub eta_seconds: Option<i64>,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub fn read_activity(drive_id: &str) -> Result<Vec<FileProviderActivityRecord>> {
    let mut db = crate::fileprovider_db::StateDb::open()?;
    let records = db.records(ACTIVITY_DIRECTORY)?;
    let Some(record) = records.into_iter().find(|record| record.key == format!("{drive_id}.json")) else {
        return Ok(Vec::new());
    };
    Ok(serde_json::from_str::<Vec<FileProviderActivityRecord>>(&record.payload)?
        .into_iter().filter(|record| record.drive_id == drive_id).collect())
}

#[derive(serde::Deserialize)]
struct FileProviderUploadReceipt {
    drive_id: String,
    uri: String,
    completed_at: i64,
}

pub fn matching_upload_receipt(drive_id: &str, uri: &str) -> Result<Option<crate::fileprovider_db::Record>> {
    let mut db = crate::fileprovider_db::StateDb::open()?;
    let now = chrono::Utc::now().timestamp();
    for record in db.records(UPLOAD_RECEIPT_DIRECTORY)? {
        let receipt: FileProviderUploadReceipt = serde_json::from_str(&record.payload)?;
        let age = now.saturating_sub(receipt.completed_at);
        if age > 5 * 60 {
            db.consume(UPLOAD_RECEIPT_DIRECTORY, &record)?;
        } else if age >= -10 && receipt.drive_id == drive_id && receipt.uri == uri {
            return Ok(Some(record));
        }
    }
    Ok(None)
}

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
pub async fn user_visible_item_url(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
) -> Option<String> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let identifier = NSString::from_str(item_identifier);
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
                getUserVisibleURLForItemIdentifier: &*identifier,
                completionHandler: &*block
            ];
        }
    }
    rx.await.ok().flatten()
}

pub async fn user_visible_url(domain_id: &str, display_name: &str) -> Option<String> {
    static ROOT_CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    let key = format!("{domain_id}\0{display_name}");
    if let Some(path) = ROOT_CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .get(&key)
        .cloned()
    {
        return Some(path);
    }

    let path = user_visible_item_url(domain_id, display_name, ROOT_CONTAINER).await?;
    ROOT_CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .insert(key, path.clone());
    Some(path)
}

const SF_DATALESS: u32 = 0x4000_0000;

pub fn is_materialized(path: &str) -> bool {
    let Ok(path) = CString::new(path) else {
        return false;
    };
    let mut metadata = MaybeUninit::<libc::stat>::uninit();
    let result = unsafe { libc::lstat(path.as_ptr(), metadata.as_mut_ptr()) };
    if result != 0 {
        return false;
    }
    unsafe { metadata.assume_init().st_flags & SF_DATALESS == 0 }
}

fn coordinated_content_read(path: &str) -> Result<()> {
    let path = NSString::from_str(path);
    let url = NSURL::fileURLWithPath(&path);
    let coordinator = NSFileCoordinator::new();
    let read_result = Arc::new(Mutex::new(None));
    let captured_result = Arc::clone(&read_result);
    let reader = RcBlock::new(move |coordinated_url: NonNull<NSURL>| {
        let result = unsafe { coordinated_url.as_ref() }
            .path()
            .ok_or_else(|| anyhow!("coordinated URL has no filesystem path"))
            .and_then(|path| {
                let mut file = File::open(path.to_string())?;
                let mut byte = [0_u8; 1];
                let _ = file.read(&mut byte)?;
                Ok(())
            });
        *captured_result.lock().unwrap() = Some(result);
    });
    let mut coordination_error = None;
    coordinator.coordinateReadingItemAtURL_options_error_byAccessor(
        &url,
        NSFileCoordinatorReadingOptions::WithoutChanges,
        Some(&mut coordination_error),
        &reader,
    );
    if let Some(error) = coordination_error {
        return Err(anyhow!(error.localizedDescription().to_string()));
    }
    read_result
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow!("coordinated read was not performed"))?
}

pub async fn refresh_materialized_item_after_remote_update(
    domain_id: String,
    item_identifier: String,
    local_path: String,
) {
    for _ in 0..50 {
        if !is_materialized(&local_path) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    if is_materialized(&local_path) {
        tracing::warn!(
            target: "fileprovider",
            item_identifier,
            "Old content generation could not be evicted; deferring remote refresh"
        );
        return;
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    if let Err(error) = mark_download_retry(&domain_id, &item_identifier) {
        tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Could not mark proactive content refresh"
        );
    }

    let read_path = local_path.clone();
    let result = tokio::task::spawn_blocking(move || coordinated_content_read(&read_path)).await;
    match result {
        Ok(Ok(())) if is_materialized(&local_path) => tracing::info!(
            target: "fileprovider",
            item_identifier,
            "Proactively materialized the latest remote content"
        ),
        Ok(Ok(())) => tracing::warn!(
            target: "fileprovider",
            item_identifier,
            "Proactive content read completed but the item remains dataless"
        ),
        Ok(Err(error)) => tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Proactive content refresh failed"
        ),
        Err(error) => tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Proactive content refresh worker failed"
        ),
    }
}

/// The raw value of `NSFileProviderWorkingSetContainerItemIdentifier`.
pub const WORKING_SET_CONTAINER: &str = "NSFileProviderWorkingSetContainerItemIdentifier";

fn canonical_fileprovider_uri(uri: &str) -> String {
    urlencoding::decode(uri)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| uri.to_string())
}

fn download_retry_identifier(drive_id: &str, item_identifier: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in drive_id
        .bytes()
        .chain(std::iter::once(0))
        .chain(item_identifier.bytes())
    {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn mark_download_retry(domain_id: &str, item_identifier: &str) -> Result<()> {
    let drive_id = domain_id.strip_prefix(DOMAIN_PREFIX).unwrap_or(domain_id);
    crate::fileprovider_db::StateDb::open()?.put(
        DOWNLOAD_RETRY_DIRECTORY,
        &download_retry_identifier(drive_id, item_identifier),
        &chrono::Utc::now().timestamp_millis().to_string(),
    )
}

// MARK: - Shared event log

/// One recorded remote event, stored transactionally in fileprovider.db.
/// The File Provider extension replays the journal in enumerateChanges (it cannot run a
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
    #[serde(default)]
    pub local_echo: bool,
}


/// Ask the next extension process to discard its local identity and pin state.
pub fn request_local_state_reset(drive_id: &str) -> Result<()> {
    let token = format!(
        "{}-{}\n",
        chrono::Utc::now().timestamp_millis(),
        uuid::Uuid::new_v4()
    );
    // Destructive commands must never be imported from legacy state directories.
    crate::fileprovider_db::StateDb::open()?.put("fp-reset-requests-v2", &format!("{drive_id}.marker"), &token)
}

/// Commit a batch before signalling Finder. Sequence allocation is transactional.
pub fn append_domain_events(
    drive_id: &str,
    events: &[cloudreve_api::models::explorer::FileEventData],
    local_echo_paths: &std::collections::HashSet<String>,
    receipts: &[crate::fileprovider_db::Record],
) -> Result<()> {
    let mut records = events.iter().map(|event| FpEventRecord {
        ts: 0,
        event_type: format!("{:?}", event.event_type).to_lowercase(),
        from: event.from.clone(),
        to: event.to.clone(),
        local_echo: local_echo_paths.contains(&event.from) || (!event.to.is_empty() && local_echo_paths.contains(&event.to)),
    }).collect::<Vec<_>>();
    crate::fileprovider_db::StateDb::open()?.append_events_consuming(drive_id, &mut records, receipts)
}

pub fn append_rescan_marker(drive_id: &str) -> Result<()> {
    append_state_events(drive_id, "rescan", &[String::new()])
}

pub fn append_metadata_events(drive_id: &str, source_uris: &[String]) -> Result<()> {
    if source_uris.is_empty() {
        append_state_events(drive_id, "metadata_rescan", &[String::new()])
    } else {
        append_state_events(drive_id, "metadata", source_uris)
    }
}

pub fn append_metadata_name_events(drive_id: &str, names: &[String]) -> Result<()> {
    append_state_events(drive_id, "metadata_name", names)
}

fn append_state_events(drive_id: &str, kind: &str, paths: &[String]) -> Result<()> {
    let mut records = paths.iter().map(|path| FpEventRecord {
        ts: 0, event_type: kind.into(), from: path.clone(),
        to: String::new(), local_echo: false,
    }).collect::<Vec<_>>();
    crate::fileprovider_db::StateDb::open()?.append_events(drive_id, &mut records)
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

async fn signal_error_resolved(
    domain_id: &str,
    display_name: &str,
    error_domain: &str,
    error_code: i64,
) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let error_domain = NSString::from_str(error_domain);
        let error_code = isize::try_from(error_code).context("invalid File Provider error code")?;
        let resolved_error = NSError::new(error_code, &error_domain);
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
                signalErrorResolved: &*resolved_error,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider resolution callback dropped"))?
}

/// Resume File Provider operations paused with CannotSynchronize.
pub async fn signal_cannot_synchronize_resolved(domain_id: &str, display_name: &str) -> Result<()> {
    signal_error_resolved(domain_id, display_name, "NSFileProviderErrorDomain", -2005).await
}

async fn clear_retry_error(
    domain_id: &str,
    display_name: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) {
    let (Some(error_domain), Some(error_code)) = (error_domain, error_code) else {
        return;
    };
    if let Err(error) =
        signal_error_resolved(domain_id, display_name, error_domain, error_code).await
    {
        tracing::warn!(
            target: "fileprovider",
            %error,
            error_domain,
            error_code,
            "Could not clear the saved File Provider error before retrying"
        );
    }
}

/// Ask File Provider to retry uploading one materialized file.
pub async fn retry_item_upload(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) -> Result<()> {
    clear_retry_error(domain_id, display_name, error_domain, error_code).await;
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let identifier = NSString::from_str(item_identifier);
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
                requestModificationOfFields: 1usize,
                forItemWithIdentifier: &*identifier,
                options: 0usize,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider upload retry callback dropped"))?
}

/// Ask File Provider to retry downloading one item.
pub async fn retry_item_download(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) -> Result<()> {
    mark_download_retry(domain_id, item_identifier)?;
    clear_retry_error(domain_id, display_name, error_domain, error_code).await;
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let identifier = NSString::from_str(item_identifier);
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
            let full_file = NSRange::new(isize::MAX as usize, 0);
            let _: () = msg_send![
                &*manager,
                requestDownloadForItemWithIdentifier: &*identifier,
                requestedRange: full_file,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider download retry callback dropped"))?
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
        &domain_identifier(drive_id),
        display_name,
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
