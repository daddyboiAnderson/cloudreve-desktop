use anyhow::{Context, Result};
use cloudreve_api::{
    Client,
    api::{ExplorerApi, explorer::ExplorerApiExt},
    models::{
        explorer::{FileResponse, GetFileInfoService, file_type, metadata},
        uri::CrUri,
    },
};
use std::{collections::HashSet, future::Future};

use crate::inventory::FileMetadata;

/// Local-only metadata used to remember the real content location of an item
/// presented below a received-share shortcut. It is never sent to Cloudreve.
pub const PRESENTED_CONTENT_URI: &str = "sys:cloudreve_desktop:presented_content_uri";
const PRESENTED_CONTENT_URI_PROP: &str = "presented_content_uri";
const OWNED_PROP: &str = "owned";

const MAX_REDIRECTS: usize = 32;

/// Separate server metadata from local presentation state before persisting an
/// inventory row. This guarantees the local target URI can never be sent back
/// as Cloudreve metadata by a future mutation path.
pub fn inventory_fields(
    file: &FileResponse,
) -> (
    std::collections::HashMap<String, String>,
    Option<serde_json::Value>,
) {
    let mut metadata = file.metadata.clone().unwrap_or_default();
    let content_uri = metadata.remove(PRESENTED_CONTENT_URI);
    let mut props = serde_json::Map::new();
    if let Some(owned) = file.owned {
        props.insert(OWNED_PROP.into(), owned.into());
    }
    if let Some(content_uri) = content_uri {
        props.insert(PRESENTED_CONTENT_URI_PROP.into(), content_uri.into());
    }
    let props = (!props.is_empty()).then(|| serde_json::Value::Object(props));
    (metadata, props)
}

pub fn inventory_content_uri(file: &FileMetadata) -> Option<&str> {
    file.props
        .as_ref()
        .and_then(|props| props.get(PRESENTED_CONTENT_URI_PROP))
        .and_then(serde_json::Value::as_str)
        // Accept rows created by development builds before this state moved
        // from metadata into props.
        .or_else(|| file.metadata.get(PRESENTED_CONTENT_URI).map(String::as_str))
}

/// Whether an inventory row represents content received from another user.
/// Redirect leaves themselves are handled separately because deleting one is
/// allowed to remove only the local shortcut identity.
pub fn is_received_inventory_entry(file: &FileMetadata) -> bool {
    inventory_content_uri(file).is_some()
        || file
            .props
            .as_ref()
            .and_then(|props| props.get(OWNED_PROP))
            .and_then(serde_json::Value::as_bool)
            == Some(false)
}

pub fn set_inventory_content_uri(file: &mut FileMetadata, uri: String) -> Result<()> {
    let props = file
        .props
        .get_or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .context("invalid received-share inventory properties")?;
    props.insert(PRESENTED_CONTENT_URI_PROP.into(), uri.into());
    file.metadata.remove(PRESENTED_CONTENT_URI);
    Ok(())
}

pub fn clear_inventory_content_uri(file: &mut FileMetadata) -> Result<()> {
    let empty = if let Some(props) = file.props.as_mut() {
        let props = props
            .as_object_mut()
            .context("invalid received-share inventory properties")?;
        props.remove(PRESENTED_CONTENT_URI_PROP);
        props.is_empty()
    } else {
        false
    };
    if empty {
        file.props = None;
    }
    file.metadata.remove(PRESENTED_CONTENT_URI);
    Ok(())
}

pub fn set_inventory_owned(file: &mut FileMetadata, owned: bool) -> Result<()> {
    let props = file
        .props
        .get_or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .context("invalid received-share inventory properties")?;
    props.insert(OWNED_PROP.into(), owned.into());
    Ok(())
}

/// Move a remembered content URI from one remote subtree to another.
///
/// The boundary check is important: moving `.../folder` must not rewrite an
/// unrelated sibling such as `.../folder-old`.
pub fn rebase_content_uri(uri: &str, old_root: &str, new_root: &str) -> Option<String> {
    if uri == old_root {
        return Some(new_root.to_string());
    }

    uri.strip_prefix(old_root)
        .filter(|suffix| suffix.starts_with('/'))
        .map(|suffix| format!("{new_root}{suffix}"))
}

/// Whether a content URI belongs to an incoming-share presentation. Direct
/// `share` drives are incoming even though their visible and content URIs are
/// identical.
pub fn is_received_content_location(visible_uri: &str, content_uri: &str) -> Result<bool> {
    let visible = CrUri::new(visible_uri)?;
    let content = CrUri::new(content_uri)?;
    Ok(visible.to_string() != content.to_string()
        || matches!(content.fs().as_str(), "share" | "shared_with_me"))
}

fn redirect_target(file: &FileResponse) -> Option<&str> {
    file.metadata
        .as_ref()
        .and_then(|metadata| metadata.get(metadata::SHARE_REDIRECT))
        .map(String::as_str)
        .filter(|target| !target.is_empty())
}

/// Resolve shortcut ancestors while optionally leaving the leaf itself
/// addressable. The latter matters for operations such as renaming/removing a
/// shortcut, while reads and directory enumeration follow the leaf.
pub async fn resolve_with_lookup<F, Fut>(
    uri: &str,
    follow_leaf: bool,
    mut lookup: F,
) -> Result<String>
where
    F: FnMut(String) -> Fut,
    Fut: Future<Output = Result<Option<String>>>,
{
    let mut current = CrUri::new(uri)?;
    let mut visited = HashSet::new();

    for _ in 0..MAX_REDIRECTS {
        if !visited.insert(current.to_string()) {
            anyhow::bail!("circular received-share shortcut");
        }

        let elements = current.elements();
        let inspect_count = if follow_leaf {
            elements.len()
        } else {
            elements.len().saturating_sub(1)
        };
        let mut prefix = current.clone();
        prefix.set_path("");
        let mut redirected = false;

        for (index, element) in elements.iter().take(inspect_count).enumerate() {
            prefix.join(&[element]);
            let Some(target) = lookup(prefix.to_string()).await? else {
                continue;
            };
            let mut target = CrUri::new(&target).context("invalid received-share target")?;
            if target.is_search() {
                anyhow::bail!("received-share target cannot be a search URI");
            }
            for child in &elements[index + 1..] {
                target.join(&[child]);
            }
            current = target;
            redirected = true;
            break;
        }

        if !redirected {
            return Ok(current.to_string());
        }
    }

    anyhow::bail!("too many received-share shortcut redirects")
}

/// Resolve a visible Cloudreve URI to the server URI that owns its content.
pub async fn resolve_uri(client: &Client, uri: &str, follow_leaf: bool) -> Result<String> {
    resolve_with_lookup(uri, follow_leaf, |candidate| async move {
        let file = client
            .get_file_info(&GetFileInfoService {
                uri: Some(candidate),
                id: None,
                extended: None,
                folder_summary: None,
            })
            .await?;
        Ok(redirect_target(&file).map(ToOwned::to_owned))
    })
    .await
}

fn child_uri(parent: &str, name: &str) -> Result<String> {
    let mut uri = CrUri::new(parent)?;
    uri.join(&[name]);
    Ok(uri.to_string())
}

pub fn present_at(file: &mut FileResponse, visible_uri: String, content_uri: String) {
    file.path = visible_uri;
    file.metadata
        .get_or_insert_with(Default::default)
        .insert(PRESENTED_CONTENT_URI.into(), content_uri);
    // A target reached through another user's share is presented as received
    // even when the target API response itself omits those optional flags.
    file.shared = Some(true);
    file.owned = Some(false);
}

async fn prepare_listed_file(
    client: &Client,
    mut file: FileResponse,
    visible_uri: String,
    inherited_share: bool,
) -> Result<FileResponse> {
    let listed_uri = file.path.clone();
    if redirect_target(&file).is_some() {
        let content_uri = resolve_uri(client, &listed_uri, true).await?;
        if file.file_type != file_type::FOLDER {
            let content = client
                .get_file_info(&GetFileInfoService {
                    uri: Some(content_uri.clone()),
                    id: None,
                    extended: None,
                    folder_summary: None,
                })
                .await?;

            // Keep the shortcut identity/name/creation data, but expose the
            // target's bytes, current entity and content modification date.
            file.size = content.size;
            file.updated_at = content.updated_at;
            file.primary_entity = content.primary_entity;
            let shortcut_metadata = file.metadata.take().unwrap_or_default();
            let shortcut_redirect = shortcut_metadata.get(metadata::SHARE_REDIRECT).cloned();
            let shortcut_owner = shortcut_metadata.get(metadata::SHARE_OWNER).cloned();
            let mut merged_metadata = shortcut_metadata;
            // Target content metadata is authoritative for hashes/thumbnails.
            merged_metadata.extend(content.metadata.unwrap_or_default());
            if let Some(redirect) = shortcut_redirect {
                merged_metadata.insert(metadata::SHARE_REDIRECT.into(), redirect);
            }
            if let Some(owner) = shortcut_owner {
                merged_metadata.insert(metadata::SHARE_OWNER.into(), owner);
            }
            file.metadata = Some(merged_metadata);
        }
        present_at(&mut file, visible_uri, content_uri);
    } else if inherited_share {
        present_at(&mut file, visible_uri, listed_uri);
    }
    Ok(file)
}

/// List a directory through received-share shortcuts while keeping every
/// returned item at its user-visible path below the configured sync root.
pub async fn list_presented_children(
    client: &Client,
    visible_directory: &str,
    page_size: i32,
) -> Result<Vec<FileResponse>> {
    let visible_directory = CrUri::new(visible_directory)?;
    let content_directory = resolve_uri(client, &visible_directory.to_string(), true).await?;
    let inherited_share = content_directory != visible_directory.to_string()
        || matches!(visible_directory.fs().as_str(), "share" | "shared_with_me");
    let mut previous_response = None;
    let mut files = Vec::new();

    loop {
        let response = client
            .list_files_all(previous_response.as_ref(), &content_directory, page_size)
            .await?;

        for file in &response.res.files {
            let visible_uri = child_uri(&visible_directory.to_string(), &file.name)?;
            match prepare_listed_file(client, file.clone(), visible_uri.clone(), inherited_share)
                .await
            {
                Ok(file) => files.push(file),
                Err(error) => {
                    // Match the macOS provider: a broken/expired shortcut must
                    // not hide otherwise accessible siblings.
                    tracing::warn!(
                        target: "drive::share_shortcuts",
                        path = %file.path,
                        error = %error,
                        "Received-share target is unavailable"
                    );
                    let mut fallback = file.clone();
                    if inherited_share || redirect_target(&fallback).is_some() {
                        let content_uri = redirect_target(&fallback)
                            .map(ToOwned::to_owned)
                            .unwrap_or_else(|| fallback.path.clone());
                        present_at(&mut fallback, visible_uri, content_uri);
                    }
                    files.push(fallback);
                }
            }
        }

        let has_more = response.more;
        previous_response = Some(response);
        if !has_more {
            break;
        }
    }

    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn resolves_nested_shortcuts_and_preserves_encoded_names() {
        let resolved = resolve_with_lookup(
            "cloudreve://my/Shared/nested/file%20%23%25.txt",
            true,
            |candidate| async move {
                Ok(match candidate.as_str() {
                    "cloudreve://my/Shared" => Some("cloudreve://incoming@shared_with_me".into()),
                    "cloudreve://incoming@shared_with_me/nested" => {
                        Some("cloudreve://second@shared_with_me/sub".into())
                    }
                    _ => None,
                })
            },
        )
        .await
        .unwrap();
        assert_eq!(
            resolved,
            "cloudreve://second@shared_with_me/sub/file%20%23%25.txt"
        );
    }

    #[tokio::test]
    async fn can_leave_the_leaf_shortcut_unresolved() {
        let resolved = resolve_with_lookup(
            "cloudreve://my/Shared/file.txt",
            false,
            |candidate| async move {
                Ok(match candidate.as_str() {
                    "cloudreve://my/Shared" => Some("cloudreve://incoming@shared_with_me".into()),
                    "cloudreve://incoming@shared_with_me/file.txt" => {
                        Some("cloudreve://file@shared_with_me".into())
                    }
                    _ => None,
                })
            },
        )
        .await
        .unwrap();
        assert_eq!(resolved, "cloudreve://incoming@shared_with_me/file.txt");
    }

    #[tokio::test]
    async fn rejects_cycles() {
        let error = resolve_with_lookup("cloudreve://my/loop", true, |_| async {
            Ok(Some("cloudreve://my/loop".into()))
        })
        .await
        .unwrap_err();
        assert!(error.to_string().contains("circular"));
    }

    #[test]
    fn child_names_are_encoded_once() {
        assert_eq!(
            child_uri("cloudreve://my/Shared", "a #%.txt").unwrap(),
            "cloudreve://my/Shared/a%20%23%25.txt"
        );
    }

    #[test]
    fn rebases_only_the_selected_content_subtree() {
        let old = "cloudreve://incoming@shared_with_me/Folder%20A";
        let new = "cloudreve://incoming@shared_with_me/Renamed";
        assert_eq!(
            rebase_content_uri(
                "cloudreve://incoming@shared_with_me/Folder%20A/nested/file.txt",
                old,
                new
            )
            .as_deref(),
            Some("cloudreve://incoming@shared_with_me/Renamed/nested/file.txt")
        );
        assert_eq!(
            rebase_content_uri("cloudreve://incoming@shared_with_me/Folder%20A", old, new)
                .as_deref(),
            Some("cloudreve://incoming@shared_with_me/Renamed")
        );
        assert!(
            rebase_content_uri(
                "cloudreve://incoming@shared_with_me/Folder%20A-old/file.txt",
                old,
                new
            )
            .is_none()
        );
    }

    #[test]
    fn recognizes_redirected_and_direct_received_locations() {
        assert!(
            is_received_content_location(
                "cloudreve://my/Shared/file.txt",
                "cloudreve://incoming@shared_with_me/file.txt"
            )
            .unwrap()
        );
        assert!(
            is_received_content_location(
                "cloudreve://incoming@shared_with_me/file.txt",
                "cloudreve://incoming@shared_with_me/file.txt"
            )
            .unwrap()
        );
        assert!(
            !is_received_content_location(
                "cloudreve://my/folder/file.txt",
                "cloudreve://my/folder/file.txt"
            )
            .unwrap()
        );
    }
}
