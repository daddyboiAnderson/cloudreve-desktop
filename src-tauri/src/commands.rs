use crate::AppStateHandle;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::{Duration, Utc};
use cloudreve_api::api::{ExplorerApi, GroupApi, ShareApi, UserApi};
use cloudreve_api::models::explorer::{file_type, GetFileInfoService, Share};
use cloudreve_api::models::share::{ListShareResponse, ListShareService, ShareLinkRequest};
use cloudreve_api::models::uri::CrUri;
use cloudreve_api::models::user::{Group, UserSearchResult};
use cloudreve_sync::drive::commands::ConflictAction;
use cloudreve_sync::{
    config::LogLevel, ConfigManager, Credentials, DriveConfig, DriveInfo, StatusSummary,
};
#[cfg(target_os = "macos")]
use core_graphics::{
    event::CGEvent,
    event_source::{CGEventSource, CGEventSourceStateID},
};
#[cfg(target_os = "macos")]
use objc2::runtime::AnyObject;
#[cfg(target_os = "macos")]
use objc2::MainThreadMarker;
#[cfg(target_os = "macos")]
use objc2_app_kit::NSApp as ns_app;
#[cfg(target_os = "macos")]
use objc2_app_kit::{
    NSBitmapImageFileType, NSBitmapImageRep, NSBitmapImageRepPropertyKey, NSColor,
    NSFontWeightSemibold, NSImage, NSImageSymbolConfiguration, NSWindow, NSWindowButton,
};
#[cfg(target_os = "macos")]
use objc2_foundation::{NSDictionary, NSString};
#[cfg(target_os = "macos")]
use std::ffi::c_void;
#[cfg(target_os = "macos")]
use std::ptr::NonNull;
#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
#[cfg(windows)]
use tauri::utils::{config::WindowEffectsConfig, WindowEffect};
#[cfg(target_os = "macos")]
use tauri::LogicalPosition;
#[cfg(target_os = "macos")]
use tauri::PhysicalPosition;
#[cfg(target_os = "macos")]
use tauri::TitleBarStyle;
use tauri::{
    webview::{WebviewWindow, WebviewWindowBuilder},
    AppHandle, Emitter, Manager, State, WebviewUrl,
};
#[cfg(windows)]
use tauri_plugin_frame::WebviewWindowExt;
use tauri_plugin_positioner::{Position, WindowExt};
use uuid::Uuid;
#[cfg(windows)]
use windows::ApplicationModel::{StartupTask, StartupTaskState};

/// Result type for Tauri commands
type CommandResult<T> = Result<T, String>;

#[cfg(target_os = "macos")]
static MAIN_POPUP_FOCUS_LOST_AT_MS: AtomicU64 = AtomicU64::new(0);
#[cfg(target_os = "macos")]
static SUPPRESS_MAIN_POPUP_FOCUS_LOSS_UNTIL_MS: AtomicU64 = AtomicU64::new(0);

#[cfg(target_os = "macos")]
fn monotonic_popup_time_ms() -> u64 {
    use std::sync::OnceLock;
    use std::time::Instant;

    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64 + 1
}

#[cfg(target_os = "macos")]
fn refresh_traffic_light_tracking(window: &WebviewWindow) {
    let window = window.clone();
    let app = window.app_handle().clone();
    let _ = app.run_on_main_thread(move || {
        let Ok(handle) = window.ns_window() else {
            return;
        };
        let ns_window = unsafe { &*handle.cast::<NSWindow>() };
        ns_window.setAcceptsMouseMovedEvents(true);

        for button_type in [
            NSWindowButton::CloseButton,
            NSWindowButton::MiniaturizeButton,
            NSWindowButton::ZoomButton,
        ] {
            let Some(button) = ns_window.standardWindowButton(button_type) else {
                continue;
            };
            button.updateTrackingAreas();
            if let Some(view) = unsafe { button.superview() } {
                view.updateTrackingAreas();
                if let Some(container) = unsafe { view.superview() } {
                    container.updateTrackingAreas();
                }
            }
        }
    });
}

#[cfg(target_os = "macos")]
fn record_main_popup_focus_loss() {
    let now = monotonic_popup_time_ms();
    if now >= SUPPRESS_MAIN_POPUP_FOCUS_LOSS_UNTIL_MS.load(Ordering::Relaxed) {
        MAIN_POPUP_FOCUS_LOST_AT_MS.store(now, Ordering::Relaxed);
    }
}

/// Check if a path is a root drive (e.g., "C:\", "D:\", "E:\")
fn is_root_drive(path: &str) -> bool {
    let path = path.trim();
    let chars: Vec<char> = path.chars().collect();

    // Must start with a single ASCII letter followed by ':'
    if chars.len() < 2 || !chars[0].is_ascii_alphabetic() || chars[1] != ':' {
        return false;
    }

    // "C:" or "C:\" or "C:/" (with optional trailing slashes)
    let rest: String = chars[2..].iter().collect();
    let rest = rest.trim_end_matches(|c| c == '\\' || c == '/');
    rest.is_empty()
}

/// Get the URL with language query parameter appended
fn get_url_with_lang(base_path: &str) -> String {
    let locale = crate::get_effective_locale();
    if base_path.contains('?') {
        format!("{}&lng={}", base_path, locale)
    } else {
        format!("{}?lng={}", base_path, locale)
    }
}

/// Check if a directory is empty (has no files or subdirectories)
#[tauri::command]
pub async fn is_dir_empty(path: String) -> CommandResult<bool> {
    let p = std::path::Path::new(&path);
    if !p.exists() || !p.is_dir() {
        return Ok(true);
    }
    match std::fs::read_dir(p) {
        Ok(mut entries) => Ok(entries.next().is_none()),
        Err(_) => Ok(true),
    }
}

/// List all configured drives
#[tauri::command]
pub async fn list_drives(state: State<'_, AppStateHandle>) -> CommandResult<Vec<DriveConfig>> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    Ok(app_state.drive_manager.list_drives().await)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ShareTarget {
    pub drive_id: String,
    pub drive_name: String,
    pub instance_url: String,
    pub uri: String,
    pub name: String,
    pub is_folder: bool,
    pub shares: Vec<Share>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ShareGroupContext {
    pub groups: Vec<Group>,
    pub current_group_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ShareWindowTarget {
    pub drive_id: String,
    pub uri: String,
}

async fn get_share_mount(
    state: &State<'_, AppStateHandle>,
    drive_id: &str,
) -> CommandResult<(Arc<cloudreve_sync::drive::mounts::Mount>, DriveConfig)> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    let mount = app_state
        .drive_manager
        .get_drive(drive_id)
        .await
        .ok_or_else(|| format!("Drive not found: {drive_id}"))?;
    let config = mount.get_config().await;
    Ok((mount, config))
}

fn validate_share_uri(
    uri: &str,
    remote_path: &str,
    current_user_id: &str,
) -> CommandResult<String> {
    let target = CrUri::new(uri).map_err(|error| format!("Invalid Cloudreve URI: {error}"))?;
    let root = CrUri::new(remote_path)
        .map_err(|error| format!("Invalid configured drive URI: {error}"))?;

    if target.is_search()
        || target.fs() != root.fs()
        || !share_identity_matches(&target.id(), &root.id(), current_user_id)
        || target
            .elements()
            .iter()
            .any(|element| element == "." || element == "..")
    {
        return Err("The selected item is outside this drive".to_string());
    }

    let root_path = root.path().trim_end_matches('/').to_string();
    let target_path = target.path().trim_end_matches('/').to_string();
    if !root_path.is_empty()
        && target_path != root_path
        && !target_path.starts_with(&format!("{root_path}/"))
    {
        return Err("The selected item is outside this drive".to_string());
    }

    Ok(target.to_string())
}

fn share_identity_matches(target_id: &str, root_id: &str, current_user_id: &str) -> bool {
    target_id == root_id
        || (target_id.is_empty() && root_id == current_user_id)
        || (root_id.is_empty() && target_id == current_user_id)
}

fn share_request_for_drive(
    mut request: ShareLinkRequest,
    remote_path: &str,
    current_user_id: &str,
) -> CommandResult<ShareLinkRequest> {
    request.uri = validate_share_uri(&request.uri, remote_path, current_user_id)?;
    Ok(request)
}

async fn resolve_share_uri(client: &cloudreve_api::Client, uri: &str) -> CommandResult<String> {
    crate::share_shortcuts::resolve(uri, |candidate| async move {
        let file = client
            .get_file_info(&GetFileInfoService {
                uri: Some(candidate),
                id: None,
                extended: Some(true),
                folder_summary: None,
            })
            .await
            .map_err(|error| error.to_string())?;
        Ok(file
            .metadata
            .and_then(|metadata| metadata.get("sys:shared_redirect").cloned()))
    })
    .await
}

#[cfg(target_os = "macos")]
fn signal_share_metadata_refresh(drive_id: &str, drive_name: &str, source_uris: &[String]) {
    cloudreve_sync::fileprovider::signal_metadata_refresh(drive_id, drive_name, source_uris);
}

/// Resolve a Finder item and load its existing share links.
#[tauri::command]
pub async fn get_share_target(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    uri: String,
) -> CommandResult<ShareTarget> {
    let (mount, config) = get_share_mount(&state, &drive_id).await?;
    let uri = validate_share_uri(&uri, &config.remote_path, &config.user_id)?;
    let resolved_uri = resolve_share_uri(&mount.cr_client, &uri).await?;
    let file = mount
        .cr_client
        .get_file_info(&GetFileInfoService {
            uri: Some(resolved_uri.clone()),
            id: None,
            extended: Some(true),
            folder_summary: None,
        })
        .await
        .map_err(|error| error.to_string())?;

    let file_path = file.path.clone();
    let mut shares = file
        .extended_info
        .and_then(|info| info.shares)
        .unwrap_or_default()
        .into_iter()
        .filter(|share| {
            crate::share_shortcuts::can_manage_share(share, &config.user_id, &resolved_uri)
        })
        .collect::<Vec<_>>();

    if shares.is_empty() {
        if let Ok(response) = mount
            .cr_client
            .list_share_links(&ListShareService {
                page_size: 100,
                order_by: None,
                order_direction: None,
                next_page_token: None,
            })
            .await
        {
            shares = response
                .shares
                .into_iter()
                .filter(|share| {
                    crate::share_shortcuts::can_manage_share(share, &config.user_id, &resolved_uri)
                        && share.source_uri.as_deref() == Some(file_path.as_str())
                })
                .collect();
        }
    }

    // The extended file response is the authoritative share state for this
    // item. Refresh its Finder decoration when the Share window is opened.
    #[cfg(target_os = "macos")]
    signal_share_metadata_refresh(&drive_id, &config.name, std::slice::from_ref(&uri));

    Ok(ShareTarget {
        drive_id,
        drive_name: config.name,
        instance_url: config.instance_url,
        uri,
        name: file.name,
        is_folder: file.file_type == file_type::FOLDER,
        shares,
    })
}

/// Load groups and the signed-in user's current group for the share picker.
#[tauri::command]
pub async fn get_share_groups(
    state: State<'_, AppStateHandle>,
    drive_id: String,
) -> CommandResult<ShareGroupContext> {
    let (mount, _) = get_share_mount(&state, &drive_id).await?;
    let groups = mount
        .cr_client
        .list_groups()
        .await
        .map_err(|error| error.to_string())?;
    let current_group_id = mount
        .cr_client
        .get_user_me()
        .await
        .map_err(|error| error.to_string())?
        .group
        .map(|group| group.id);

    Ok(ShareGroupContext {
        groups,
        current_group_id,
    })
}

/// Create a share link for a Finder item.
#[tauri::command]
pub async fn create_share_link(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    request: ShareLinkRequest,
) -> CommandResult<String> {
    let (mount, config) = get_share_mount(&state, &drive_id).await?;
    let mut request = share_request_for_drive(request, &config.remote_path, &config.user_id)?;
    #[cfg(target_os = "macos")]
    let source_uri = request.uri.clone();
    request.uri = resolve_share_uri(&mount.cr_client, &request.uri).await?;
    let url = mount
        .cr_client
        .create_share_link(&request)
        .await
        .map_err(|error| error.to_string())?;
    #[cfg(target_os = "macos")]
    signal_share_metadata_refresh(&drive_id, &config.name, std::slice::from_ref(&source_uri));
    Ok(url)
}

/// Update an existing share link.
#[tauri::command]
pub async fn edit_share_link(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    share_id: String,
    request: ShareLinkRequest,
) -> CommandResult<String> {
    let (mount, config) = get_share_mount(&state, &drive_id).await?;
    let mut request = share_request_for_drive(request, &config.remote_path, &config.user_id)?;
    #[cfg(target_os = "macos")]
    let source_uri = request.uri.clone();
    request.uri = resolve_share_uri(&mount.cr_client, &request.uri).await?;
    let url = mount
        .cr_client
        .edit_share_link(&share_id, &request)
        .await
        .map_err(|error| error.to_string())?;
    #[cfg(target_os = "macos")]
    signal_share_metadata_refresh(&drive_id, &config.name, std::slice::from_ref(&source_uri));
    Ok(url)
}

/// Load the full settings for an existing share link.
#[tauri::command]
pub async fn get_share_link_info(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    share_id: String,
) -> CommandResult<Share> {
    let (mount, _) = get_share_mount(&state, &drive_id).await?;
    mount
        .cr_client
        .get_share_link_info(&share_id)
        .await
        .map_err(|error| error.to_string())
}

/// List share links owned by a drive's Cloudreve account.
#[tauri::command]
pub async fn list_share_links(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    page_size: Option<i32>,
    next_page_token: Option<String>,
) -> CommandResult<ListShareResponse> {
    let (mount, _) = get_share_mount(&state, &drive_id).await?;
    mount
        .cr_client
        .list_share_links(&ListShareService {
            page_size: page_size.unwrap_or(100).clamp(10, 100),
            order_by: None,
            order_direction: None,
            next_page_token,
        })
        .await
        .map_err(|error| error.to_string())
}

/// Delete an existing share link.
#[tauri::command]
pub async fn delete_share_link(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    share_id: String,
) -> CommandResult<()> {
    let (mount, config) = get_share_mount(&state, &drive_id).await?;
    #[cfg(target_os = "macos")]
    let source_uri = mount
        .cr_client
        .get_share_link_info(&share_id)
        .await
        .ok()
        .and_then(|share| share.source_uri);
    mount
        .cr_client
        .delete_share_link(&share_id)
        .await
        .map_err(|error| error.to_string())?;
    #[cfg(target_os = "macos")]
    let source_uris = source_uri.into_iter().collect::<Vec<_>>();
    #[cfg(target_os = "macos")]
    signal_share_metadata_refresh(&drive_id, &config.name, &source_uris);
    Ok(())
}

/// Search users available as explicit share recipients.
#[tauri::command]
pub async fn search_share_users(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    keyword: String,
) -> CommandResult<Vec<UserSearchResult>> {
    let (mount, _) = get_share_mount(&state, &drive_id).await?;
    if keyword.trim().is_empty() {
        return Ok(Vec::new());
    }
    mount
        .cr_client
        .search_users(keyword.trim())
        .await
        .map_err(|error| error.to_string())
}

/// Resolve the full identity of users already assigned to a share link.
#[tauri::command]
pub async fn get_share_users(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    user_ids: Vec<String>,
) -> CommandResult<Vec<UserSearchResult>> {
    let (mount, _) = get_share_mount(&state, &drive_id).await?;
    let mut users = Vec::new();

    for user_id in user_ids.into_iter().filter(|id| !id.trim().is_empty()) {
        let Ok(user) = mount.cr_client.get_user_info(&user_id).await else {
            continue;
        };
        users.push(UserSearchResult {
            id: user.id,
            nickname: user.nickname,
            email: user.email,
            avatar: user.avatar,
            group: user.group,
        });
    }

    Ok(users)
}

#[derive(serde::Deserialize)]
pub struct AddDriveArgs {
    pub site_url: String,
    pub access_token: String,
    pub refresh_token: String,
    pub access_token_expires: u64,
    pub refresh_token_expires: u64,
    pub drive_name: String,
    pub remote_path: String,
    pub local_path: String,
    pub user_id: String,
    pub drive_id: Option<String>,
}

/// The same Cloudreve account/root gets the same native domain identity when
/// it is removed and added again. Display names and local paths are mutable.
fn stable_drive_id(instance_url: &str, user_id: &str, remote_path: &str) -> String {
    let key = format!(
        "{}\n{}\n{}",
        instance_url.trim_end_matches('/').to_ascii_lowercase(),
        user_id,
        remote_path.trim_end_matches('/')
    );
    Uuid::new_v5(&Uuid::NAMESPACE_URL, key.as_bytes()).to_string()
}

/// Add a new drive configuration
#[tauri::command]
pub async fn add_drive(
    state: State<'_, AppStateHandle>,
    config: AddDriveArgs,
) -> CommandResult<String> {
    let site_url =
        tauri::Url::parse(&config.site_url).map_err(|e| format!("Invalid Cloudreve URL: {e}"))?;
    if site_url.scheme() != "https" {
        return Err("Cloudreve connections must use HTTPS".to_string());
    }
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;

    // Validate local_path for new drives (not for reauthorization)
    if config.drive_id.is_none() && is_root_drive(&config.local_path) {
        return Err(t!("localPathCannotBeRootDrive").to_string());
    }

    // Convert relative expiry times (seconds) to absolute RFC3339 timestamps
    let now = Utc::now();
    let access_expires = (now + Duration::seconds(config.access_token_expires as i64)).to_rfc3339();
    let refresh_expires =
        (now + Duration::seconds(config.refresh_token_expires as i64)).to_rfc3339();

    let credentials = Credentials {
        access_token: Some(config.access_token),
        refresh_token: config.refresh_token,
        access_expires: Some(access_expires),
        refresh_expires,
    };

    // If drive_id is provided, update existing drive instead of creating a new one
    if let Some(drive_id) = config.drive_id {
        app_state
            .drive_manager
            .update_drive_credentials(
                &drive_id,
                config.drive_name,
                config.site_url,
                credentials,
                &config.user_id,
            )
            .await
            .map_err(|e| e.to_string())?;

        // Persist drive configurations
        app_state
            .drive_manager
            .persist()
            .await
            .map_err(|e| e.to_string())?;

        return Ok(drive_id);
    }

    // Keep the File Provider domain stable when this account/root is re-added.
    let drive_id = stable_drive_id(&config.site_url, &config.user_id, &config.remote_path);

    let drive_config = DriveConfig {
        id: drive_id,
        name: config.drive_name.clone(),
        instance_url: config.site_url,
        remote_path: config.remote_path,
        credentials,
        sync_path: config.local_path.into(),
        icon_path: None,
        raw_icon_path: None,
        enabled: true,
        user_id: config.user_id,
        sync_root_id: None,
        ignore_patterns: Vec::new(),
        extra: Default::default(),
    };

    // Add drive to manager
    let id = app_state
        .drive_manager
        .add_drive(drive_config)
        .await
        .map_err(|e| e.to_string())?;

    // Persist drive configurations
    app_state
        .drive_manager
        .persist()
        .await
        .map_err(|e| e.to_string())?;

    // Register a File Provider domain for the new drive (macOS only, best-effort)
    #[cfg(target_os = "macos")]
    {
        if let Err(e) = cloudreve_sync::fileprovider::add_domain(
            &cloudreve_sync::fileprovider::domain_identifier(&id),
            &config.drive_name,
        )
        .await
        {
            tracing::warn!(target: "fileprovider", "failed to register FP domain for {id}: {e:#}");
        }
    }

    Ok(id)
}

/// Remove a drive by ID
#[tauri::command]
pub async fn remove_drive(
    state: State<'_, AppStateHandle>,
    drive_id: String,
) -> CommandResult<Option<DriveConfig>> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;

    let result = app_state
        .drive_manager
        .remove_drive(&drive_id)
        .await
        .map_err(|e| e.to_string())?;

    // Persist drive configurations after removal
    app_state
        .drive_manager
        .persist()
        .await
        .map_err(|e| e.to_string())?;

    // Remove the drive's File Provider domain (macOS only, best-effort).
    // Note: this also deletes the local replica under ~/Library/CloudStorage.
    #[cfg(target_os = "macos")]
    if let Some(ref drive) = result {
        if let Err(e) = cloudreve_sync::fileprovider::remove_domain(
            &cloudreve_sync::fileprovider::domain_identifier(&drive_id),
            &drive.name,
        )
        .await
        {
            tracing::warn!(target: "fileprovider", "failed to remove FP domain for {drive_id}: {e:#}");
        }
    }

    Ok(result)
}

/// Get ignore patterns for a drive
#[tauri::command]
pub async fn get_ignore_patterns(
    state: State<'_, AppStateHandle>,
    drive_id: String,
) -> CommandResult<Vec<String>> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    app_state
        .drive_manager
        .get_ignore_patterns(&drive_id)
        .await
        .map_err(|e| e.to_string())
}

/// Set ignore patterns for a drive
#[tauri::command]
pub async fn set_ignore_patterns(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    patterns: Vec<String>,
) -> CommandResult<()> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;

    app_state
        .drive_manager
        .update_ignore_patterns(&drive_id, patterns)
        .await
        .map_err(|e| e.to_string())?;

    app_state
        .drive_manager
        .persist()
        .await
        .map_err(|e| e.to_string())?;

    Ok(())
}

/// Get sync status for a drive
#[tauri::command]
pub async fn get_sync_status(
    state: State<'_, AppStateHandle>,
    drive_id: String,
) -> CommandResult<serde_json::Value> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    app_state
        .drive_manager
        .get_sync_status(&drive_id)
        .await
        .map_err(|e| e.to_string())
}

/// Get status summary including all drives and recent tasks
#[tauri::command]
pub async fn get_status_summary(
    state: State<'_, AppStateHandle>,
    drive_id: Option<String>,
) -> CommandResult<StatusSummary> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    app_state
        .drive_manager
        .get_status_summary(drive_id.as_deref())
        .await
        .map_err(|e| e.to_string())
}

/// Resolve a pending local-vs-remote conflict.
#[tauri::command]
pub async fn resolve_conflict(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    file_id: i64,
    path: String,
    action: String,
) -> CommandResult<()> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    // Keep the frontend contract string-based so TS does not need to mirror the
    // Rust enum layout. The accepted values are the same action IDs used by the
    // Windows shell/toast resolver.
    let action = ConflictAction::from_str(&action)
        .ok_or_else(|| format!("Invalid conflict action: {action}"))?;
    let drive = app_state
        .drive_manager
        .get_drive(&drive_id)
        .await
        .ok_or_else(|| format!("Drive not found: {drive_id}"))?;

    drive
        .resolve_conflict(action, file_id, path)
        .await
        .map_err(|e| e.to_string())
}

/// Resolve all pending conflicts for a drive (or all drives if drive_id is None).
#[tauri::command]
pub async fn resolve_all_conflicts(
    state: State<'_, AppStateHandle>,
    drive_id: Option<String>,
    action: String,
) -> CommandResult<(usize, usize)> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    let action = ConflictAction::from_str(&action)
        .ok_or_else(|| format!("Invalid conflict action: {action}"))?;

    let mut total_success = 0usize;
    let mut total_failed = 0usize;

    if let Some(id) = drive_id {
        let drive = app_state
            .drive_manager
            .get_drive(&id)
            .await
            .ok_or_else(|| format!("Drive not found: {id}"))?;
        let (s, f) = drive
            .resolve_all_conflicts(action)
            .await
            .map_err(|e| e.to_string())?;
        total_success += s;
        total_failed += f;
    } else {
        let drives = app_state.drive_manager.list_drives().await;
        for config in drives {
            if let Some(drive) = app_state.drive_manager.get_drive(&config.id).await {
                match drive.resolve_all_conflicts(action).await {
                    Ok((s, f)) => {
                        total_success += s;
                        total_failed += f;
                    }
                    Err(e) => {
                        tracing::error!(
                            target: "commands",
                            drive_id = %config.id,
                            error = %e,
                            "Failed to resolve all conflicts for drive"
                        );
                        // We intentionally continue with other drives rather
                        // than failing the whole batch.
                    }
                }
            }
        }
    }

    Ok((total_success, total_failed))
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn get_upload_conflict(
    state: State<'_, AppStateHandle>,
    id: String,
) -> CommandResult<crate::upload_conflict::UploadConflictRecord> {
    let mut conflict = crate::upload_conflict::get(&id).map_err(|error| error.to_string())?;
    if let Some(owner_id) = conflict.owner_id.as_deref() {
        if let Ok((mount, _)) = get_share_mount(&state, &conflict.drive_id).await {
            if let Ok(user) = mount.cr_client.get_user_info(owner_id).await {
                conflict.owner_name = Some(user.nickname);
            }
        }
    }
    Ok(conflict)
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn resolve_upload_conflict(id: String, action: String) -> CommandResult<()> {
    let record =
        crate::upload_conflict::set_action(&id, &action).map_err(|error| error.to_string())?;
    let domain_id = cloudreve_sync::fileprovider::domain_identifier(&record.drive_id);
    cloudreve_sync::fileprovider::signal_cannot_synchronize_resolved(&domain_id, &record.drive_name)
        .await
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "macos")]
async fn file_provider_issues(
    state: &State<'_, AppStateHandle>,
) -> CommandResult<(
    Vec<DriveConfig>,
    Vec<crate::file_provider_issue::FileProviderIssue>,
)> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    let drives = app_state.drive_manager.list_drives().await;
    let drive_ids = drives
        .iter()
        .map(|drive| drive.id.clone())
        .collect::<std::collections::HashSet<_>>();
    let issues = crate::file_provider_issue::list(&drive_ids).map_err(|error| error.to_string())?;
    Ok((drives, issues))
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn list_file_provider_issues(
    state: State<'_, AppStateHandle>,
    drive_id: Option<String>,
) -> CommandResult<Vec<crate::file_provider_issue::FileProviderIssue>> {
    let (_, mut issues) = file_provider_issues(&state).await?;
    if let Some(drive_id) = drive_id {
        issues.retain(|issue| issue.drive_id == drive_id);
    }
    Ok(issues)
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn resolve_file_provider_issue(
    state: State<'_, AppStateHandle>,
    issue_id: String,
    action: String,
) -> CommandResult<()> {
    let (drives, issues) = file_provider_issues(&state).await?;
    let issue = issues
        .into_iter()
        .find(|issue| issue.id == issue_id)
        .ok_or_else(|| "This Finder issue is no longer available".to_string())?;
    let drive = drives
        .into_iter()
        .find(|drive| drive.id == issue.drive_id)
        .ok_or_else(|| "Drive is no longer available".to_string())?;
    let domain_id = cloudreve_sync::fileprovider::domain_identifier(&drive.id);

    if issue.source == "upload_conflict" {
        let conflict_id = issue
            .conflict_id
            .ok_or_else(|| "Upload conflict is no longer available".to_string())?;
        crate::upload_conflict::set_action(&conflict_id, &action)
            .map_err(|error| error.to_string())?;
        return cloudreve_sync::fileprovider::signal_cannot_synchronize_resolved(
            &domain_id,
            &drive.name,
        )
        .await
        .map_err(|error| error.to_string());
    }

    if action != "retry" {
        return Err("Only retry is available for this Finder issue".to_string());
    }
    match issue.operation.as_str() {
        "upload" => cloudreve_sync::fileprovider::retry_item_upload(
            &domain_id,
            &drive.name,
            &issue.item_identifier,
            issue.error_domain.as_deref(),
            issue.error_code,
        )
        .await
        .map_err(|error| error.to_string()),
        "download" => cloudreve_sync::fileprovider::retry_item_download(
            &domain_id,
            &drive.name,
            &issue.item_identifier,
            issue.error_domain.as_deref(),
            issue.error_code,
        )
        .await
        .map_err(|error| error.to_string()),
        _ => Err("Unknown Finder operation".to_string()),
    }
}

#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn reveal_file_provider_issue(
    state: State<'_, AppStateHandle>,
    issue_id: String,
) -> CommandResult<()> {
    let (drives, issues) = file_provider_issues(&state).await?;
    let issue = issues
        .into_iter()
        .find(|issue| issue.id == issue_id)
        .ok_or_else(|| "This Finder issue is no longer available".to_string())?;
    let drive = drives
        .into_iter()
        .find(|drive| drive.id == issue.drive_id)
        .ok_or_else(|| "Drive is no longer available".to_string())?;
    let domain_id = cloudreve_sync::fileprovider::domain_identifier(&drive.id);
    let path = cloudreve_sync::fileprovider::user_visible_item_url(
        &domain_id,
        &drive.name,
        &issue.item_identifier,
    )
    .await
    .ok_or_else(|| "Finder could not locate this item".to_string())?;
    showfile::show_path_in_file_manager(path);
    Ok(())
}

/// Get all drives with their status information for the settings UI
#[tauri::command]
pub async fn get_drives_info(state: State<'_, AppStateHandle>) -> CommandResult<Vec<DriveInfo>> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    app_state
        .drive_manager
        .get_drives_info()
        .await
        .map_err(|e| e.to_string())
}

/// Remove and re-add the Finder domain with fresh extension-local state.
#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn reset_file_provider(
    state: State<'_, AppStateHandle>,
    drive_id: String,
) -> CommandResult<()> {
    let app_state = state
        .get()
        .ok_or_else(|| "App not yet initialized".to_string())?;
    let drive = app_state
        .drive_manager
        .list_drives()
        .await
        .into_iter()
        .find(|drive| drive.id == drive_id)
        .ok_or_else(|| format!("Drive not found: {drive_id}"))?;

    let domain_id = cloudreve_sync::fileprovider::domain_identifier(&drive.id);
    cloudreve_sync::fileprovider::request_local_state_reset(&drive.id)
        .map_err(|error| format!("Could not prepare Finder reset: {error:#}"))?;
    let registered = cloudreve_sync::fileprovider::list_domains()
        .await
        .map_err(|error| format!("Could not inspect Finder integration: {error:#}"))?;

    if registered.iter().any(|(id, _)| id == &domain_id) {
        cloudreve_sync::fileprovider::remove_domain(&domain_id, &drive.name)
            .await
            .map_err(|error| format!("Could not remove Finder integration: {error:#}"))?;
    }

    cloudreve_sync::fileprovider::add_domain(&domain_id, &drive.name)
        .await
        .map_err(|error| format!("Could not add Finder integration: {error:#}"))?;

    Ok(())
}

/// File icon response containing base64 encoded RGBA pixel data
#[derive(serde::Serialize)]
pub struct FileIconResponse {
    /// Base64 encoded RGBA pixel data
    pub data: String,
    /// Icon width in pixels
    pub width: u32,
    /// Icon height in pixels
    pub height: u32,
}

fn file_icon_to_response(icon: file_icon_provider::Icon) -> FileIconResponse {
    FileIconResponse {
        data: BASE64.encode(&icon.pixels),
        width: icon.width,
        height: icon.height,
    }
}

/// Get file icon for a given path
/// Returns base64 encoded RGBA pixel data with dimensions
#[tauri::command]
pub async fn get_file_icon(
    #[allow(unused_variables)] app: AppHandle,
    path: String,
    size: Option<u16>,
) -> CommandResult<FileIconResponse> {
    let icon_size = size.unwrap_or(32);

    let result =
        tokio::task::spawn_blocking(move || file_icon_provider::get_file_icon(&path, icon_size))
            .await
            .map_err(|e| format!("Task join error: {}", e))?
            .map_err(|e| format!("Failed to get file icon: {:?}", e))?;

    Ok(file_icon_to_response(result))
}

/// Return an SF Symbol used by the macOS share window.
#[cfg(target_os = "macos")]
#[tauri::command]
pub async fn get_system_symbol(app: AppHandle, name: String) -> CommandResult<String> {
    const ALLOWED_SYMBOLS: &[&str] = &[
        "square.and.arrow.up",
        "lock.fill",
        "rectangle.grid.2x2.fill",
        "doc.text.fill",
        "timer",
    ];
    if !ALLOWED_SYMBOLS.contains(&name.as_str()) {
        return Err("Unsupported SF Symbol".to_string());
    }

    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let symbol_name = NSString::from_str(&name);
        let point_size = unsafe {
            NSImageSymbolConfiguration::configurationWithPointSize_weight(
                60.0,
                NSFontWeightSemibold,
            )
        };
        let color =
            NSImageSymbolConfiguration::configurationWithHierarchicalColor(&NSColor::whiteColor());
        let configuration = point_size.configurationByApplyingConfiguration(&color);
        let result =
            NSImage::imageWithSystemSymbolName_accessibilityDescription(&symbol_name, None)
                .and_then(|image| image.imageWithSymbolConfiguration(&configuration))
                .and_then(|image| image.TIFFRepresentation())
                .and_then(|data| NSBitmapImageRep::imageRepWithData(&data))
                .and_then(|representation| {
                    let properties = NSDictionary::<NSBitmapImageRepPropertyKey, AnyObject>::new();
                    unsafe {
                        representation.representationUsingType_properties(
                            NSBitmapImageFileType::PNG,
                            &properties,
                        )
                    }
                })
                .map(|data| {
                    let length = data.length() as usize;
                    let mut bytes = vec![0u8; length];
                    if length > 0 {
                        let buffer = NonNull::new(bytes.as_mut_ptr() as *mut c_void)
                            .expect("non-empty image data has a buffer");
                        unsafe { data.getBytes_length(buffer, length as _) };
                    }
                    format!("data:image/png;base64,{}", BASE64.encode(bytes))
                });
        let _ = sender.send(result.ok_or_else(|| "SF Symbol unavailable".to_string()));
    })
    .map_err(|error| format!("Could not render SF Symbol: {error}"))?;

    receiver
        .await
        .map_err(|_| "SF Symbol rendering was cancelled".to_string())?
}

/// Show or create the main window (positioned at tray center)
pub fn show_main_window(app: &AppHandle) {
    show_main_window_at_position(app, Position::TrayCenter);
}

/// Show the main popup at the clicked screen position.
#[cfg(target_os = "macos")]
pub fn show_main_window_at_click(app: &AppHandle, click: PhysicalPosition<f64>) {
    // Prefer the hardware cursor position for proxied status items.
    let click = hardware_cursor_position(app).unwrap_or(click);
    show_main_window_at_position(app, Position::TrayCenter);

    let Some(window) = app.get_webview_window("main_popup") else {
        return;
    };
    position_main_window_at_click(&window, click);

    // Reapply the position after the status-item callback settles.
    let window = window.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        position_main_window_at_click(&window, click);
    });
}

/// Toggle the tray popup at the clicked position.
#[cfg(target_os = "macos")]
pub fn toggle_main_window_at_click(app: &AppHandle, click: PhysicalPosition<f64>) {
    let now = monotonic_popup_time_ms();
    let focus_lost_at = MAIN_POPUP_FOCUS_LOST_AT_MS.load(Ordering::Relaxed);
    let recently_lost_focus = focus_lost_at != 0 && now.saturating_sub(focus_lost_at) <= 300;
    let is_visible = app
        .get_webview_window("main_popup")
        .and_then(|window| window.is_visible().ok())
        .unwrap_or(false);

    if is_visible || recently_lost_focus {
        // Ignore focus loss caused by hiding the window.
        SUPPRESS_MAIN_POPUP_FOCUS_LOSS_UNTIL_MS.store(now + 500, Ordering::Relaxed);
        MAIN_POPUP_FOCUS_LOST_AT_MS.store(0, Ordering::Relaxed);
        if let Some(window) = app.get_webview_window("main_popup") {
            let _ = window.hide();
        }
        crate::schedule_update_dock_visibility(app);
        return;
    }

    show_main_window_at_click(app, click);
}

#[cfg(target_os = "macos")]
fn hardware_cursor_position(app: &AppHandle) -> Option<PhysicalPosition<f64>> {
    // Use HID coordinates instead of proxy status-item coordinates.
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok()?;
    let location = CGEvent::new(source).ok()?.location();
    let scale = app.primary_monitor().ok().flatten()?.scale_factor();
    Some(PhysicalPosition::new(
        location.x * scale,
        location.y * scale,
    ))
}

#[cfg(target_os = "macos")]
fn position_main_window_at_click(window: &WebviewWindow, click: PhysicalPosition<f64>) {
    let Ok(monitors) = window.available_monitors() else {
        return;
    };
    let monitor = monitors.into_iter().find(|monitor| {
        let position = monitor.position();
        let size = monitor.size();
        click.x >= position.x as f64
            && click.x < (position.x + size.width as i32) as f64
            && click.y >= position.y as f64
            && click.y < (position.y + size.height as i32) as f64
    });
    let Some(monitor) = monitor.or_else(|| window.primary_monitor().ok().flatten()) else {
        return;
    };
    let Ok(window_size) = window.outer_size() else {
        return;
    };

    let monitor_position = monitor.position();
    let monitor_size = monitor.size();
    let scale = monitor.scale_factor();
    let min_x = monitor_position.x;
    let max_x = monitor_position.x + monitor_size.width as i32 - window_size.width as i32;
    let min_y = monitor_position.y;
    let max_y = monitor_position.y + monitor_size.height as i32 - window_size.height as i32;
    let x = (click.x.round() as i32 - window_size.width as i32 / 2).clamp(min_x, max_x);
    // A menu-bar click is normally at the vertical center of its icon. Half a
    // standard 24-point menu bar places the popup immediately below it.
    let y = (click.y.round() as i32 + (12.0 * scale).round() as i32).clamp(min_y, max_y);

    if let Err(err) = window.set_position(PhysicalPosition::new(x, y)) {
        tracing::warn!(
            target: "main",
            error = %err,
            "Failed to position main popup at tray click"
        );
    }
}

/// Show or create the main window (positioned at bottom right)
pub fn show_main_window_center(app: &AppHandle) {
    show_main_window_at_position(app, Position::Center);
}

fn move_window_safely(window: &WebviewWindow, position: Position, label: &str) {
    // Probe monitor availability before using the tray positioner.
    match position {
        Position::Center => {
            if let Err(err) = window.center() {
                tracing::warn!(
                    target: "main",
                    window = label,
                    error = %err,
                    "Failed to center window"
                );
            }
        }
        position => match window.current_monitor() {
            Ok(Some(_)) => {
                if let Err(err) = window.move_window(position) {
                    tracing::warn!(
                        target: "main",
                        window = label,
                        error = %err,
                        "Failed to move window with positioner; falling back to center"
                    );
                    let _ = window.center();
                }
            }
            Ok(None) => {
                tracing::warn!(
                    target: "main",
                    window = label,
                    "Window has no current monitor; preserving its last position"
                );
            }
            Err(err) => {
                tracing::warn!(
                    target: "main",
                    window = label,
                    error = %err,
                    "Failed to get current monitor; preserving its last position"
                );
            }
        },
    }
}

fn apply_default_window_icon<'a>(
    builder: WebviewWindowBuilder<'a, tauri::Wry, AppHandle>,
    app: &'a AppHandle,
    label: &str,
) -> Option<WebviewWindowBuilder<'a, tauri::Wry, AppHandle>> {
    // Non-Windows desktops otherwise tend to show the Wayland/X11 default icon
    // for custom windows. Reusing Tauri's default icon keeps taskbar entries
    // consistent without hard-coding a platform-specific icon path here.
    let Some(icon) = app.default_window_icon() else {
        tracing::warn!(
            target: "main",
            window = label,
            "No default window icon is configured"
        );
        return Some(builder);
    };

    match builder.icon(icon.clone()) {
        Ok(builder) => Some(builder),
        Err(err) => {
            tracing::warn!(
                target: "main",
                window = label,
                error = %err,
                "Failed to set window icon"
            );
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn activate_app(app: &AppHandle) {
    if let Err(error) = app.run_on_main_thread(|| {
        let Some(mtm) = MainThreadMarker::new() else {
            tracing::warn!(target: "share", "Share window activation was requested off the main thread");
            return;
        };

        let app = ns_app(mtm);
        #[allow(deprecated)]
        app.activateIgnoringOtherApps(true);
    }) {
        tracing::warn!(target: "share", error = %error, "Failed to activate the app for the Share window");
    }
}

/// Keep Dock visibility in sync with native window state.
#[cfg(target_os = "macos")]
fn update_dock_on_window_close(window: &WebviewWindow) {
    let window_clone = window.clone();
    window.on_window_event(move |event| {
        if matches!(
            event,
            tauri::WindowEvent::CloseRequested { .. }
                | tauri::WindowEvent::Destroyed
                | tauri::WindowEvent::Focused(false)
        ) {
            crate::schedule_update_dock_visibility(&window_clone.app_handle().clone());
        }
    });
}

/// Internal function to show or create the main window at a specific position
fn show_main_window_at_position(app: &AppHandle, position: Position) {
    if let Some(window) = app.get_webview_window("main_popup") {
        move_window_safely(&window, position, "main_popup");
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        #[cfg(target_os = "macos")]
        crate::update_dock_visibility(app);
        return;
    }

    let builder = WebviewWindowBuilder::new(
        app,
        "main_popup",
        WebviewUrl::App(get_url_with_lang("index.html/#/popup").into()),
    )
    .title("Cloudreve")
    .inner_size(370.0, 530.0)
    .resizable(false)
    .visible(false)
    .decorations(false)
    .skip_taskbar(true)
    .minimizable(false);

    #[cfg(target_os = "macos")]
    let builder = builder
        .transparent(true)
        // Keep the tray popup available on every Space.
        .visible_on_all_workspaces(true);

    let Some(builder) = apply_default_window_icon(builder, app, "main_popup") else {
        return;
    };

    match builder.build() {
        Ok(window) => {
            #[cfg(target_os = "macos")]
            update_dock_on_window_close(&window);

            // Hide the popup on close or focus loss.
            let window_for_events = window.clone();
            window.on_window_event(move |event| match event {
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    if ConfigManager::get().fast_popup_launch() {
                        api.prevent_close();
                        let _ = window_for_events.hide();
                        #[cfg(target_os = "macos")]
                        crate::schedule_update_dock_visibility(
                            &window_for_events.app_handle().clone(),
                        );
                    }
                }
                #[cfg(target_os = "macos")]
                tauri::WindowEvent::Focused(false) => {
                    record_main_popup_focus_loss();
                    let _ = window_for_events.hide();
                    crate::schedule_update_dock_visibility(&window_for_events.app_handle().clone());
                }
                _ => {}
            });

            // Show once before positioning so AppKit assigns a monitor.
            let _ = window.show();
            move_window_safely(&window, position, "main_popup");
            let _ = window.set_focus();
            #[cfg(target_os = "macos")]
            crate::update_dock_visibility(app);
        }
        Err(e) => {
            tracing::error!(target: "main_popup", error = %e, "Failed to create main window");
        }
    }
}

/// Show a file in the system file explorer (Windows Explorer, Finder, etc.)
/// This will open the parent folder and select/highlight the file.
#[tauri::command]
pub async fn show_file_in_explorer(path: String) -> CommandResult<()> {
    showfile::show_path_in_file_manager(&path);
    Ok(())
}

/// Command to show the add-drive window
#[tauri::command]
pub async fn show_add_drive_window(app: AppHandle) -> CommandResult<()> {
    show_add_drive_window_impl(&app);
    Ok(())
}

/// Route Cloudreve deep links to the appropriate native window.
pub fn handle_deep_link(app: &AppHandle, raw_url: &str) {
    if let Ok(url) = tauri::Url::parse(raw_url) {
        let is_share = url.scheme() == "cloudreve"
            && (url.host_str() == Some("share") || url.path().trim_matches('/') == "share");
        if is_share {
            let drive_id = url
                .query_pairs()
                .find(|(key, _)| key == "drive_id")
                .map(|(_, value)| value.into_owned());
            let uri = url
                .query_pairs()
                .find(|(key, _)| key == "uri")
                .map(|(_, value)| value.into_owned());

            if let (Some(drive_id), Some(uri)) = (drive_id, uri) {
                show_share_window_impl(app, &drive_id, &uri);
                return;
            }

            tracing::warn!(target: "share", "Ignoring share deep link without drive_id or uri");
            return;
        }

        #[cfg(target_os = "macos")]
        {
            let is_upload_conflict = url.scheme() == "cloudreve"
                && (url.host_str() == Some("upload-conflict")
                    || url.path().trim_matches('/') == "upload-conflict");
            if is_upload_conflict {
                if let Some(id) = url
                    .query_pairs()
                    .find(|(key, _)| key == "id")
                    .map(|(_, value)| value.into_owned())
                {
                    show_upload_conflict_window_impl(app, &id);
                    return;
                }
                tracing::warn!(target: "upload_conflict", "Ignoring conflict deep link without id");
                return;
            }
        }
    }

    let _ = app.emit("deeplink", raw_url.to_string());
    show_add_drive_window_impl(app);
}

#[cfg(target_os = "macos")]
pub fn show_upload_conflict_window_impl(app: &AppHandle, id: &str) {
    if let Ok(record) = crate::upload_conflict::get(id) {
        // Failed modifications need a separate metadata event for Finder's badge.
        cloudreve_sync::fileprovider::signal_metadata_refresh(
            &record.drive_id,
            &record.drive_name,
            std::slice::from_ref(&record.uri),
        );
    }

    if let Some(window) = app.get_webview_window("upload-conflict") {
        let _ = app.show();
        let _ = window.show();
        let _ = window.unminimize();
        crate::update_dock_visibility(app);
        activate_app(app);
        let _ = window.set_focus();
        refresh_traffic_light_tracking(&window);
        let _ = window.emit("upload-conflict-target", id.to_string());
        return;
    }

    let url_path = format!(
        "index.html/#/upload-conflict?id={}",
        urlencoding::encode(id)
    );
    let builder = WebviewWindowBuilder::new(
        app,
        "upload-conflict",
        WebviewUrl::App(get_url_with_lang(&url_path).into()),
    )
    .title("Upload Conflict")
    .inner_size(500.0, 500.0)
    .min_inner_size(460.0, 460.0)
    .resizable(false)
    .visible(false)
    .decorations(true)
    .title_bar_style(TitleBarStyle::Overlay)
    .hidden_title(true)
    .skip_taskbar(true)
    .minimizable(false)
    .maximizable(false)
    .transparent(true)
    .traffic_light_position(LogicalPosition::new(16.0, 25.0));

    let Some(builder) = apply_default_window_icon(builder, app, "upload-conflict") else {
        return;
    };
    match builder.build() {
        Ok(window) => {
            update_dock_on_window_close(&window);
            move_window_safely(&window, Position::Center, "upload-conflict");
            let _ = app.show();
            let _ = window.show();
            crate::update_dock_visibility(app);
            activate_app(app);
            let _ = window.set_focus();
            refresh_traffic_light_tracking(&window);
        }
        Err(error) => {
            tracing::error!(target: "upload_conflict", error = %error, "Failed to create upload conflict window");
        }
    }
}

/// Show or create the Share window for a Finder item.
pub fn show_share_window_impl(app: &AppHandle, drive_id: &str, uri: &str) {
    let target = ShareWindowTarget {
        drive_id: drive_id.to_string(),
        uri: uri.to_string(),
    };

    if let Some(window) = app.get_webview_window("share") {
        #[cfg(target_os = "macos")]
        let _ = app.show();
        let _ = window.show();
        let _ = window.unminimize();
        #[cfg(target_os = "macos")]
        {
            crate::update_dock_visibility(app);
            activate_app(app);
        }
        let _ = window.set_focus();
        #[cfg(target_os = "macos")]
        refresh_traffic_light_tracking(&window);
        let _ = window.emit("share-target", &target);
        return;
    }

    let url_path = format!(
        "index.html/#/share?drive_id={}&uri={}",
        urlencoding::encode(drive_id),
        urlencoding::encode(uri)
    );
    let builder = WebviewWindowBuilder::new(
        app,
        "share",
        WebviewUrl::App(get_url_with_lang(&url_path).into()),
    )
    .title("Share Options")
    .inner_size(540.0, 620.0)
    .min_inner_size(480.0, 480.0)
    .resizable(false)
    .visible(false)
    .decorations(false)
    .skip_taskbar(true)
    .minimizable(false);

    #[cfg(any(target_os = "macos", windows))]
    let builder = builder.transparent(true);

    #[cfg(target_os = "macos")]
    let builder = builder
        .decorations(true)
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .minimizable(false)
        .maximizable(false)
        .traffic_light_position(LogicalPosition::new(16.0, 25.0));

    let Some(builder) = apply_default_window_icon(builder, app, "share") else {
        return;
    };

    match builder.build() {
        Ok(window) => {
            #[cfg(target_os = "macos")]
            update_dock_on_window_close(&window);

            move_window_safely(&window, Position::Center, "share");
            #[cfg(target_os = "macos")]
            let _ = app.show();
            let _ = window.show();
            #[cfg(target_os = "macos")]
            {
                crate::update_dock_visibility(app);
                activate_app(app);
            }
            let _ = window.set_focus();
            #[cfg(target_os = "macos")]
            refresh_traffic_light_tracking(&window);
        }
        Err(error) => {
            tracing::error!(target: "share", error = %error, "Failed to create Share window");
        }
    }
}

/// Command used by the UI and useful for opening Share from another app.
#[tauri::command]
pub async fn show_share_window(app: AppHandle, drive_id: String, uri: String) -> CommandResult<()> {
    show_share_window_impl(&app, &drive_id, &uri);
    Ok(())
}

/// Command to show the reauthorize window for a specific drive
#[tauri::command]
pub async fn show_reauthorize_window(
    app: AppHandle,
    drive_id: String,
    site_url: String,
    drive_name: String,
) -> CommandResult<()> {
    show_reauthorize_window_impl(&app, &drive_id, &site_url, &drive_name);
    Ok(())
}

/// Show or create the add-drive window
pub fn show_add_drive_window_impl(app: &AppHandle) {
    show_drive_window_internal(
        app,
        "Add Drive",
        &get_url_with_lang("index.html/#/add-drive"),
    );
}

/// Show or create the reauthorize window for a specific drive
pub fn show_reauthorize_window_impl(
    app: &AppHandle,
    drive_id: &str,
    site_url: &str,
    drive_name: &str,
) {
    // URL encode the site_url to safely pass it in the route
    let encoded_site_url = urlencoding::encode(site_url);
    let encoded_drive_name = urlencoding::encode(drive_name);
    let url_path = format!(
        "index.html/#/reauthorize/{}/{}/{}",
        drive_id, encoded_site_url, encoded_drive_name
    );
    show_drive_window_internal(app, "Reauthorize Drive", &get_url_with_lang(&url_path));
}

/// Internal function to show or create the add-drive/reauthorize window
fn show_drive_window_internal(app: &AppHandle, title: &str, url_path: &str) {
    // Check if window already exists
    if let Some(window) = app.get_webview_window("add-drive") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        #[cfg(target_os = "macos")]
        {
            refresh_traffic_light_tracking(&window);
            crate::update_dock_visibility(app);
        }
        return;
    }

    // Create new window with mica effect on Windows only.
    #[cfg(windows)]
    let effects = WindowEffectsConfig {
        effects: vec![WindowEffect::Mica, WindowEffect::Acrylic],
        state: None,
        radius: None,
        color: None,
    };

    let builder = WebviewWindowBuilder::new(app, "add-drive", WebviewUrl::App(url_path.into()))
        .title(title)
        .inner_size(470.0, 630.0)
        .resizable(false)
        .visible(false)
        .decorations(false)
        .minimizable(false);

    #[cfg(any(target_os = "macos", windows))]
    let builder = builder.transparent(true);

    // Platform-specific: title_bar_style and hidden_title are macOS-only.
    #[cfg(target_os = "macos")]
    let builder = builder
        .decorations(true)
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .minimizable(false)
        .maximizable(false)
        .traffic_light_position(LogicalPosition::new(16.0, 25.0));

    let Some(builder) = apply_default_window_icon(builder, app, "add-drive") else {
        return;
    };

    match builder.build() {
        Ok(window) => {
            #[cfg(target_os = "macos")]
            update_dock_on_window_close(&window);

            #[cfg(windows)]
            {
                let _ = window.set_effects(effects);
            }

            move_window_safely(&window, Position::Center, "add-drive");
            #[cfg(windows)]
            let _ = window.create_overlay_titlebar();
            let _ = window.show();
            let _ = window.set_focus();
            #[cfg(target_os = "macos")]
            {
                refresh_traffic_light_tracking(&window);
                crate::update_dock_visibility(app);
            }
        }
        Err(e) => {
            tracing::error!(target: "main", error = %e, "Failed to create window: {}", title);
        }
    }
}

/// Command to show the settings window
#[tauri::command]
pub async fn show_settings_window(app: AppHandle) -> CommandResult<()> {
    show_settings_window_impl(&app);
    Ok(())
}

/// Show or create the settings window
pub fn show_settings_window_impl(app: &AppHandle) {
    // Check if window already exists
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        #[cfg(target_os = "macos")]
        {
            refresh_traffic_light_tracking(&window);
            crate::update_dock_visibility(app);
        }
        return;
    }

    // Create new window with mica effect on Windows only.
    #[cfg(windows)]
    let effects = WindowEffectsConfig {
        effects: vec![WindowEffect::Mica, WindowEffect::Acrylic],
        state: None,
        radius: None,
        color: None,
    };

    let builder = WebviewWindowBuilder::new(
        app,
        "settings",
        WebviewUrl::App(get_url_with_lang("index.html/#/settings").into()),
    )
    .title("Settings")
    .inner_size(700.0, 500.0)
    .min_inner_size(600.0, 400.0)
    .visible(false)
    .resizable(true)
    .decorations(false)
    .minimizable(true);

    #[cfg(windows)]
    let builder = builder.transparent(true);

    #[cfg(target_os = "macos")]
    let builder = builder
        .transparent(true)
        .decorations(true)
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .minimizable(false)
        .maximizable(false)
        .traffic_light_position(LogicalPosition::new(16.0, 25.0));

    let Some(builder) = apply_default_window_icon(builder, app, "settings") else {
        return;
    };

    match builder.build() {
        Ok(window) => {
            #[cfg(target_os = "macos")]
            update_dock_on_window_close(&window);

            #[cfg(windows)]
            {
                let _ = window.set_effects(effects);
            }

            move_window_safely(&window, Position::Center, "settings");
            #[cfg(windows)]
            let _ = window.create_overlay_titlebar();
            let _ = window.show();
            let _ = window.set_focus();
            #[cfg(target_os = "macos")]
            {
                refresh_traffic_light_tracking(&window);
                crate::update_dock_visibility(app);
            }
        }
        Err(e) => {
            tracing::error!(target: "main", error = %e, "Failed to create settings window");
        }
    }
}

/// The TaskId defined in AppxManifest.xml for the startup task
#[cfg(windows)]
const STARTUP_TASK_ID: &str = "cloudreve";
#[cfg(target_os = "macos")]
const MACOS_LAUNCH_AGENT_FILE: &str = "cloudreve.desktop.dev.plist";
#[cfg(target_os = "macos")]
const MACOS_LAUNCH_AGENT_LABEL: &str = "cloudreve.desktop.dev";

#[cfg(target_os = "macos")]
fn macos_launch_agent_path() -> CommandResult<std::path::PathBuf> {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .ok_or_else(|| "Unable to determine home directory".to_string())?;
    Ok(home
        .join("Library")
        .join("LaunchAgents")
        .join(MACOS_LAUNCH_AGENT_FILE))
}

#[cfg(target_os = "macos")]
fn macos_plist_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
        .replace('\n', "")
        .replace('\r', "")
}

#[cfg(target_os = "macos")]
fn macos_launch_agent_entry() -> CommandResult<String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("Failed to get current executable path: {}", e))?;
    let exe = macos_plist_escape(&exe.display().to_string());
    let label = macos_plist_escape(MACOS_LAUNCH_AGENT_LABEL);

    Ok(format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
"#,
        label, exe
    ))
}

#[cfg(target_os = "macos")]
fn macos_get_auto_start_enabled() -> CommandResult<bool> {
    let path = macos_launch_agent_path()?;
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(err) => return Err(format!("Failed to read LaunchAgent: {}", err)),
    };

    // Verify the plist is ours and configured to start at login.
    let has_label = content.contains(&format!("<string>{}</string>", MACOS_LAUNCH_AGENT_LABEL));
    let run_at_load = content.contains("<key>RunAtLoad</key>") && content.contains("<true/>");
    Ok(has_label && run_at_load)
}

#[cfg(target_os = "macos")]
fn macos_set_auto_start(enabled: bool) -> CommandResult<bool> {
    let path = macos_launch_agent_path()?;

    if enabled {
        let parent = path
            .parent()
            .ok_or_else(|| "Invalid LaunchAgent path".to_string())?;
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create LaunchAgents directory: {}", e))?;
        std::fs::write(&path, macos_launch_agent_entry()?)
            .map_err(|e| format!("Failed to write LaunchAgent: {}", e))?;

        // Load the agent so it applies to the current session and is enabled
        // for future logins. Ignore errors: launchctl may fail if the agent is
        // already loaded, which still leaves the plist in place for next boot.
        let path_str = path.display().to_string();
        let _ = std::process::Command::new("/bin/launchctl")
            .args(["load", "-w", &path_str])
            .output();

        Ok(true)
    } else {
        // Only remove the plist. We intentionally do not `launchctl unload`
        // because if the current process was launched by this agent, unload
        // would terminate the running app. The agent will not be started on
        // the next login since the plist is gone.
        match std::fs::remove_file(&path) {
            Ok(_) => Ok(false),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(err) => Err(format!("Failed to remove LaunchAgent: {}", err)),
        }
    }
}

/// Get whether auto-start is enabled using Windows StartupTask API
#[tauri::command]
pub async fn get_auto_start_enabled() -> CommandResult<bool> {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(macos_get_auto_start_enabled)
            .await
            .map_err(|e| format!("Task join error: {}", e))?;
    }

    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Ok(false)
    }

    #[cfg(windows)]
    {
        tokio::task::spawn_blocking(|| {
            let task_id: windows::core::HSTRING = STARTUP_TASK_ID.into();
            let task = StartupTask::GetAsync(&task_id)
                .map_err(|e| format!("Failed to get startup task: {}", e))?
                .get()
                .map_err(|e| format!("Failed to get startup task: {}", e))?;

            let state = task
                .State()
                .map_err(|e| format!("Failed to get task state: {}", e))?;

            Ok(matches!(
                state,
                StartupTaskState::Enabled | StartupTaskState::EnabledByPolicy
            ))
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }
}

/// Set auto-start configuration using Windows StartupTask API
#[tauri::command]
pub async fn set_auto_start(enabled: bool) -> CommandResult<bool> {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(move || macos_set_auto_start(enabled))
            .await
            .map_err(|e| format!("Task join error: {}", e))?;
    }

    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Err("Auto-start configuration is not supported on this platform yet".to_string())
    }

    #[cfg(windows)]
    {
        tokio::task::spawn_blocking(move || {
            let task_id: windows::core::HSTRING = STARTUP_TASK_ID.into();
            let task = StartupTask::GetAsync(&task_id)
                .map_err(|e| format!("Failed to get startup task: {}", e))?
                .get()
                .map_err(|e| format!("Failed to get startup task: {}", e))?;

            if enabled {
                // Request enable - may prompt user for consent
                let new_state = task
                    .RequestEnableAsync()
                    .map_err(|e| format!("Failed to request enable: {}", e))?
                    .get()
                    .map_err(|e| format!("Failed to enable startup task: {}", e))?;

                Ok(matches!(
                    new_state,
                    StartupTaskState::Enabled | StartupTaskState::EnabledByPolicy
                ))
            } else {
                task.Disable()
                    .map_err(|e| format!("Failed to disable startup task: {}", e))?;
                Ok(false)
            }
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }
}

/// Set notification settings for credential expiry
#[tauri::command]
pub async fn set_notify_credential_expired(enabled: bool) -> CommandResult<()> {
    ConfigManager::get()
        .set_notify_credential_expired(enabled)
        .map_err(|e| e.to_string())
}

/// Set notification settings for file conflicts
#[tauri::command]
pub async fn set_notify_file_conflict(enabled: bool) -> CommandResult<()> {
    ConfigManager::get()
        .set_notify_file_conflict(enabled)
        .map_err(|e| e.to_string())
}

/// Set fast popup launch setting
#[tauri::command]
pub async fn set_fast_popup_launch(enabled: bool) -> CommandResult<()> {
    ConfigManager::get()
        .set_fast_popup_launch(enabled)
        .map_err(|e| e.to_string())
}

/// Get all general settings
#[tauri::command]
pub async fn get_general_settings() -> CommandResult<GeneralSettings> {
    let config = ConfigManager::get().get_config();
    Ok(GeneralSettings {
        notify_credential_expired: config.notify_credential_expired,
        notify_file_conflict: config.notify_file_conflict,
        fast_popup_launch: config.fast_popup_launch,
        log_to_file: config.log_to_file,
        log_level: config.log_level.as_str().to_string(),
        log_max_files: config.log_max_files,
        log_dir: ConfigManager::get_log_dir().display().to_string(),
        language: config.language,
    })
}

#[derive(serde::Serialize)]
pub struct GeneralSettings {
    pub notify_credential_expired: bool,
    pub notify_file_conflict: bool,
    pub fast_popup_launch: bool,
    pub log_to_file: bool,
    pub log_level: String,
    pub log_max_files: usize,
    pub log_dir: String,
    pub language: Option<String>,
}

/// Set log to file setting
#[tauri::command]
pub async fn set_log_to_file(enabled: bool) -> CommandResult<()> {
    ConfigManager::get()
        .set_log_to_file(enabled)
        .map_err(|e| e.to_string())
}

/// Set log level setting
#[tauri::command]
pub async fn set_log_level(level: String) -> CommandResult<()> {
    let log_level = LogLevel::from_str(&level);

    // Update config (requires restart to take effect)
    ConfigManager::get()
        .set_log_level(log_level)
        .map_err(|e| e.to_string())
}

/// Set max log files setting
#[tauri::command]
pub async fn set_log_max_files(max_files: usize) -> CommandResult<()> {
    ConfigManager::get()
        .set_log_max_files(max_files)
        .map_err(|e| e.to_string())
}

/// Set language setting and update rust_i18n locale
#[tauri::command]
pub async fn set_language(app: AppHandle, language: Option<String>) -> CommandResult<()> {
    // Update the config
    ConfigManager::get()
        .set_language(language.clone())
        .map_err(|e| e.to_string())?;

    // Update rust_i18n locale to the effective locale (config setting or
    // normalized system locale).
    rust_i18n::set_locale(&crate::get_effective_locale());

    // Rebuild the tray context menu with the new locale so it doesn't show
    // raw i18n keys.
    if let Err(e) = crate::rebuild_tray_menu(&app) {
        tracing::warn!(target: "main", error = %e, "Failed to rebuild tray menu after language change");
    }

    // Close main window to force reload with new language
    // Check if window already exists
    if let Some(window) = app.get_webview_window("main_popup") {
        let _ = window.close();
        let _ = window.destroy();
    }

    Ok(())
}

/// Open the log folder in file explorer
#[tauri::command]
pub async fn open_log_folder() -> CommandResult<()> {
    let log_dir = ConfigManager::get_log_dir();

    // Create the directory if it doesn't exist
    if !log_dir.exists() {
        std::fs::create_dir_all(&log_dir).map_err(|e| e.to_string())?;
    }

    showfile::show_path_in_file_manager(format!("{}\\", log_dir.display()));
    Ok(())
}
