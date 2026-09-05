use crate::{
    commands::{get_share_mount, validate_share_uri},
    AppStateHandle,
};
use cloudreve_api::{
    api::{ExplorerApi, ShareApi},
    models::{
        explorer::{GetFileInfoService, ListFileService, Share},
        share::ListShareService,
    },
};
use std::collections::{HashMap, HashSet};
use tauri::State;

#[derive(serde::Serialize)]
pub struct SavedItem {
    uri: String,
    name: String,
    is_folder: bool,
    share_url: Option<String>,
    share_id: Option<String>,
    share_count: usize,
    expired: bool,
}

#[cfg(target_os = "macos")]
fn provider_state() -> Result<std::path::PathBuf, String> {
    Ok(dirs::home_dir().ok_or("Home directory unavailable")?.join(
        "Library/Containers/cloudreve.desktop.dev.fileprovider/Data/Library/Application Support/CloudreveFileProvider"))
}

#[cfg(target_os = "macos")]
fn read_state<T: serde::de::DeserializeOwned + Default>(name: &str) -> Result<T, String> {
    match std::fs::read(provider_state()?.join(name)) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub async fn list_saved_items(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    kind: String,
) -> Result<Vec<SavedItem>, String> {
    let (mount, config) = get_share_mount(&state, &drive_id).await?;
    if kind == "pinned" {
        #[cfg(target_os = "macos")]
        {
            let pins: Vec<String> = read_state(&format!("pinned-{drive_id}.json"))?;
            let identities: HashMap<String, String> =
                read_state(&format!("identities-{drive_id}.json"))?;
            let root = cloudreve_sync::fileprovider::user_visible_url(
                &cloudreve_sync::fileprovider::domain_identifier(&drive_id),
                &config.name,
            )
            .await;
            let mut items = Vec::new();
            for id in pins {
                let uri = if id == "NSFileProviderRootContainerItemIdentifier" {
                    config.remote_path.clone()
                } else {
                    identities.get(&id).cloned().unwrap_or(id)
                };
                let Ok(uri) = validate_share_uri(&uri, &config.remote_path, &config.user_id) else {
                    continue;
                };
                let relative = relative_path(&uri, &config.remote_path)?;
                let is_folder = root
                    .as_ref()
                    .map(|r| std::path::Path::new(r).join(&relative).is_dir())
                    .unwrap_or(false);
                let name = if relative.is_empty() {
                    config.name.clone()
                } else {
                    relative.rsplit('/').next().unwrap_or(&relative).to_string()
                };
                items.push(SavedItem {
                    uri,
                    name,
                    is_folder,
                    share_url: None,
                    share_id: None,
                    share_count: 0,
                    expired: false,
                });
            }
            items.sort_by_key(|i| i.name.to_lowercase());
            return Ok(items);
        }
        #[cfg(not(target_os = "macos"))]
        return Err("Keep Downloaded is available on macOS".into());
    }
    if kind != "shared" {
        return Err("Unknown saved item view".into());
    }
    let mut items = Vec::new();
    let mut token = None;
    let mut tokens = HashSet::new();
    loop {
        let response = mount
            .cr_client
            .list_share_links(&ListShareService {
                page_size: 100,
                order_by: None,
                order_direction: None,
                next_page_token: token,
            })
            .await
            .map_err(|e| e.to_string())?;
        for share in response.shares {
            if share.owner.id != config.user_id {
                continue;
            }
            let source = match share.source_uri.clone() {
                Some(source) => Some(source),
                None => find_share_source(&mount.cr_client, &share, &config.remote_path).await?,
            };
            let Some(source) = source else {
                continue;
            };
            let Ok(uri) = validate_share_uri(&source, &config.remote_path, &config.user_id) else {
                continue;
            };
            let name = share
                .name
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| uri.rsplit('/').next().unwrap_or(&uri).to_string());
            items.push(SavedItem {
                uri,
                name,
                is_folder: share.source_type == Some(1),
                share_url: Some(share.url),
                share_id: Some(share.id),
                share_count: 1,
                expired: share.expired.unwrap_or(false),
            });
        }
        token = response.pagination.next_token.filter(|s| !s.is_empty());
        match &token {
            None => break,
            Some(t) if !tokens.insert(t.clone()) => {
                return Err("Share pagination did not advance".into())
            }
            _ => {}
        }
    }
    items.extend(
        received_share_items(&mount.cr_client, &config.remote_path, &config.user_id).await?,
    );
    let mut grouped: HashMap<String, SavedItem> = HashMap::new();
    let mut links = HashSet::new();
    for item in items {
        if !links.insert(item.share_id.clone()) {
            continue;
        }
        if let Some(existing) = grouped.get_mut(&item.uri) {
            existing.share_count += 1;
            existing.expired &= item.expired;
        } else {
            grouped.insert(item.uri.clone(), item);
        }
    }
    let mut items: Vec<_> = grouped.into_values().collect();
    items.sort_by_key(|i| i.name.to_lowercase());
    Ok(items)
}

async fn search_items(
    client: &cloudreve_api::Client,
    uri: String,
) -> Result<Vec<cloudreve_api::models::explorer::FileResponse>, String> {
    let mut files = Vec::new();
    let mut token = None;
    let mut seen = HashSet::new();
    let mut page = 0;
    loop {
        let result = client
            .list_files(&ListFileService {
                uri: uri.clone(),
                page: Some(page),
                page_size: Some(100),
                order_by: None,
                order_direction: None,
                next_page_token: token,
            })
            .await
            .map_err(|e| e.to_string())?;
        let count = result.files.len();
        files.extend(result.files);
        if result.recursion_limit_reached == Some(true) {
            return Err("Cloudreve's search limit prevented locating all shared items".into());
        }
        token = result.pagination.next_token.filter(|t| !t.is_empty());
        if let Some(t) = &token {
            if !seen.insert(t.clone()) {
                return Err("File pagination did not advance".into());
            }
        } else if result.pagination.is_cursor == Some(true)
            || count == 0
            || result
                .pagination
                .total_items
                .map(|n| files.len() as i64 >= n)
                .unwrap_or(count < 100)
        {
            break;
        }
        page += 1;
    }
    Ok(files)
}

async fn received_share_items(
    client: &cloudreve_api::Client,
    root: &str,
    user: &str,
) -> Result<Vec<SavedItem>, String> {
    use cloudreve_api::models::uri::CrUri;
    let mut roots = Vec::new();
    let parsed = CrUri::new(root).map_err(|e| e.to_string())?;
    if matches!(parsed.fs().as_str(), "share" | "shared_with_me") {
        roots.push((root.to_string(), root.to_string(), true));
    } else {
        for file in search_items(client, format!("{root}?meta_sys%3Ashared_redirect=")).await? {
            if let Some(target) = file
                .metadata
                .and_then(|m| m.get("sys:shared_redirect").cloned())
            {
                roots.push((file.path, target, file.file_type == 1));
            }
        }
    }
    let mut items = Vec::new();
    for (local, remote, folder) in roots {
        let mut candidates = Vec::new();
        if folder {
            for kind in ["file", "folder"] {
                candidates.extend(search_items(client, format!("{remote}?type={kind}")).await?);
            }
        } else {
            candidates.push(
                client
                    .get_file_info(&GetFileInfoService {
                        uri: Some(remote.clone()),
                        id: None,
                        extended: Some(true),
                        folder_summary: None,
                    })
                    .await
                    .map_err(|e| e.to_string())?,
            );
        }
        for candidate in candidates {
            let file = client
                .get_file_info(&GetFileInfoService {
                    uri: Some(candidate.path.clone()),
                    id: None,
                    extended: Some(true),
                    folder_summary: None,
                })
                .await
                .map_err(|e| e.to_string())?;
            let mut visible = CrUri::new(&local).map_err(|e| e.to_string())?;
            let remote_root = CrUri::new(&remote).map_err(|e| e.to_string())?;
            let path = CrUri::new(&candidate.path).map_err(|e| e.to_string())?;
            for part in path.elements().iter().skip(remote_root.elements().len()) {
                visible.join(&[part]);
            }
            let uri = validate_share_uri(&visible.to_string(), root, user)?;
            for share in file
                .extended_info
                .and_then(|i| i.shares)
                .unwrap_or_default()
            {
                if !crate::share_shortcuts::can_manage_share(&share, user, &remote) {
                    continue;
                }
                items.push(SavedItem {
                    uri: uri.clone(),
                    name: file.name.clone(),
                    is_folder: file.file_type == 1,
                    share_url: Some(share.url),
                    share_id: Some(share.id),
                    share_count: 1,
                    expired: share.expired.unwrap_or(false),
                });
            }
        }
    }
    Ok(items)
}

async fn find_share_source(
    client: &cloudreve_api::client::Client,
    share: &Share,
    root: &str,
) -> Result<Option<String>, String> {
    let Some(name) = share.name.as_deref().filter(|name| !name.is_empty()) else {
        return Err("Cloudreve returned a share without a name or location".into());
    };
    let mut page = 0;
    let mut token = None;
    let mut seen = HashSet::new();
    loop {
        let response = client
            .list_files(&ListFileService {
                uri: format!(
                    "{}?name={}",
                    root.trim_end_matches('/'),
                    urlencoding::encode(name)
                ),
                page: Some(page),
                page_size: Some(100),
                order_by: None,
                order_direction: None,
                next_page_token: token,
            })
            .await
            .map_err(|e| e.to_string())?;
        let count = response.files.len();
        for candidate in response.files {
            if candidate.name != name {
                continue;
            }
            // Names can repeat; only a matching share ID identifies the source.
            let file = client
                .get_file_info(&GetFileInfoService {
                    uri: Some(candidate.path),
                    id: None,
                    extended: Some(true),
                    folder_summary: None,
                })
                .await
                .map_err(|e| e.to_string())?;
            if file
                .extended_info
                .and_then(|info| info.shares)
                .unwrap_or_default()
                .iter()
                .any(|link| link.id == share.id)
            {
                return Ok(Some(file.path));
            }
        }
        if response.recursion_limit_reached == Some(true) {
            return Err("Cloudreve's search limit prevented locating all shared items".into());
        }
        token = response.pagination.next_token.filter(|t| !t.is_empty());
        if let Some(t) = &token {
            if !seen.insert(t.clone()) {
                return Err("File pagination did not advance".into());
            }
        } else if response.pagination.is_cursor == Some(true)
            || count == 0
            || response
                .pagination
                .total_items
                .map(|total| {
                    ((page + 1) as i64 * response.pagination.page_size.max(1) as i64) >= total
                })
                .unwrap_or(count < response.pagination.page_size.max(1) as usize)
        {
            return Ok(None);
        }
        page += 1;
    }
}

fn relative_path(uri: &str, root: &str) -> Result<String, String> {
    use cloudreve_api::models::uri::CrUri;
    let item = CrUri::new(uri).map_err(|e| e.to_string())?;
    let root = CrUri::new(root).map_err(|e| e.to_string())?;
    let path = item
        .elements()
        .into_iter()
        .skip(root.elements().len())
        .collect::<Vec<_>>()
        .join("/");
    if std::path::Path::new(&path)
        .components()
        .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err("Invalid item path".into());
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_encoded_names_under_a_nested_drive() {
        assert_eq!(
            relative_path(
                "cloudreve://my/Work/Test%20folder/report.txt",
                "cloudreve://my/Work"
            )
            .unwrap(),
            "Test folder/report.txt"
        );
        assert_eq!(
            relative_path("cloudreve://my/Work", "cloudreve://my/Work").unwrap(),
            ""
        );
    }

    #[test]
    fn rejects_traversal_hidden_in_a_segment() {
        assert!(relative_path("cloudreve://my/%2F..%2Fsecret", "cloudreve://my").is_err());
    }

    #[test]
    fn rejects_shares_outside_the_drive() {
        assert!(validate_share_uri(
            "cloudreve://my/Elsewhere/file.txt",
            "cloudreve://my/Work",
            "user"
        )
        .is_err());
        assert!(validate_share_uri(
            "cloudreve://incoming@shared_with_me/file.txt",
            "cloudreve://my",
            "user"
        )
        .is_err());
    }
}

#[tauri::command]
pub async fn reveal_saved_item(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    uri: String,
) -> Result<(), String> {
    let (_, config) = get_share_mount(&state, &drive_id).await?;
    let uri = validate_share_uri(&uri, &config.remote_path, &config.user_id)?;
    #[cfg(target_os = "macos")]
    let root = cloudreve_sync::fileprovider::user_visible_url(
        &cloudreve_sync::fileprovider::domain_identifier(&drive_id),
        &config.name,
    )
    .await
    .ok_or("Drive is unavailable in Finder")?;
    #[cfg(not(target_os = "macos"))]
    let root = config.sync_path.clone();
    let path = std::path::Path::new(&root).join(relative_path(&uri, &config.remote_path)?);
    if !path.exists() {
        return Err(
            "This item is not available locally. Open its parent folder in Finder first.".into(),
        );
    }
    showfile::show_path_in_file_manager(path);
    Ok(())
}

#[tauri::command]
pub async fn remove_saved_pin(
    state: State<'_, AppStateHandle>,
    drive_id: String,
    uri: String,
) -> Result<(), String> {
    let (_, config) = get_share_mount(&state, &drive_id).await?;
    let uri = validate_share_uri(&uri, &config.remote_path, &config.user_id)?;
    #[cfg(target_os = "macos")]
    {
        let directory = dirs::home_dir()
            .ok_or("Home directory unavailable")?
            .join(".cloudreve/pin-requests");
        std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let path = directory.join(format!("{}.json", uuid::Uuid::new_v4()));
        let temporary = path.with_extension("tmp");
        let request = serde_json::json!({"drive_id":drive_id,"uri":uri});
        std::fs::write(&temporary, request.to_string()).map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, &path).map_err(|e| e.to_string())?;
        cloudreve_sync::fileprovider::signal_metadata_refresh(&drive_id, &config.name, &[uri]);
        for _ in 0..40 {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            if !path.exists() {
                return Ok(());
            }
        }
        return Err(
            "Finder has not applied the change yet. It will update when the drive reconnects."
                .into(),
        );
    }
    #[cfg(not(target_os = "macos"))]
    Err("Keep Downloaded is available on macOS".into())
}
