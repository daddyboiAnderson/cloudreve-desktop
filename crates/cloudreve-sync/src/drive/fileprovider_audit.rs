use super::mounts::Mount;
use crate::inventory::{FileProviderRemoteItem, NewFileProviderRemoteItem};
use anyhow::{Context, Result};
use cloudreve_api::{
    api::explorer::ExplorerApiExt,
    models::explorer::{FileEventData, FileEventType, FileResponse, file_type},
};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::Arc,
    time::Duration,
};

const PAGE_SIZE: i32 = 200;
const DIRECTORY_DELAY: Duration = Duration::from_millis(20);
const EVENT_BATCH_SIZE: usize = 100;

fn canonical_uri(uri: &str) -> String {
    urlencoding::decode(uri)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| uri.to_string())
        .trim_end_matches('/')
        .to_string()
}

fn parent_uri(uri: &str) -> String {
    let uri = canonical_uri(uri);
    uri.rsplit_once('/')
        .map(|(parent, _)| parent.to_string())
        .unwrap_or_default()
}

fn ignored(name: &str) -> bool {
    name == ".DS_Store" || name == "Icon\r" || name.starts_with("._")
}

fn version(file: &FileResponse) -> String {
    format!("{}:{}:{}", file.updated_at, file.size, file.file_type)
}

fn is_received_share(file: &FileResponse) -> bool {
    file.metadata
        .as_ref()
        .and_then(|metadata| metadata.get("sys:shared_redirect"))
        .is_some()
}

impl Mount {
    /// Start one metadata-only recovery pass if another pass is not running.
    /// The SSE listener remains active while this task walks the remote tree.
    pub(crate) async fn schedule_fileprovider_recovery(self: &Arc<Self>) {
        let mut slot = self.fileprovider_audit_handle.lock().await;
        if slot.as_ref().is_some_and(|handle| !handle.is_finished()) {
            tracing::debug!(target: "fileprovider_audit", id=%self.id, "Recovery audit already running");
            return;
        }
        let mount = Arc::clone(self);
        *slot = Some(tokio::spawn(async move {
            if let Err(error) = mount.run_fileprovider_recovery().await {
                tracing::warn!(target: "fileprovider_audit", id=%mount.id, %error, "File Provider recovery audit failed; it will retry after the next reconnect");
            }
        }));
    }

    async fn run_fileprovider_recovery(&self) -> Result<()> {
        let (drive_id, drive_name, root_uri) = {
            let config = self.config.read().await;
            (
                config.id.clone(),
                config.name.clone(),
                canonical_uri(&config.remote_path),
            )
        };
        let generation = chrono::Utc::now().timestamp_millis();
        let previous = self
            .inventory
            .fileprovider_remote_items(&drive_id)?
            .into_iter()
            .map(|item| (item.remote_id.clone(), item))
            .collect::<HashMap<_, _>>();

        tracing::info!(target: "fileprovider_audit", id=%drive_id, known=previous.len(), "Starting metadata-only File Provider recovery audit");
        let mut queue = VecDeque::from([root_uri]);
        let mut visited = HashSet::new();
        let mut events = Vec::new();
        let mut seen = 0usize;

        while let Some(directory) = queue.pop_front() {
            if !visited.insert(directory.clone()) {
                continue;
            }
            let mut page = None;
            loop {
                let response = self
                    .cr_client
                    .list_files_all(page.as_ref(), &directory, PAGE_SIZE)
                    .await
                    .with_context(|| format!("could not list {directory}"))?;
                let more = response.more;
                let files = response.res.files.clone();
                let mut rows = Vec::with_capacity(files.len());
                for file in files.into_iter().filter(|file| !ignored(&file.name)) {
                    let uri = canonical_uri(&file.path);
                    let item_version = version(&file);
                    let old = previous.get(&file.id);
                    let event_type = match old {
                        None => Some(FileEventType::Create),
                        Some(old) if canonical_uri(&old.uri) != uri => Some(FileEventType::Rename),
                        Some(old) if old.version != item_version => Some(FileEventType::Modify),
                        _ => None,
                    };
                    if let Some(event_type) = event_type {
                        events.push(FileEventData {
                            event_type,
                            file_id: file.id.clone(),
                            from: old
                                .map(|item| canonical_uri(&item.uri))
                                .unwrap_or_else(|| uri.clone()),
                            to: if event_type == FileEventType::Rename {
                                uri.clone()
                            } else {
                                String::new()
                            },
                        });
                    }
                    rows.push(NewFileProviderRemoteItem {
                        drive_id: drive_id.clone(),
                        remote_id: file.id.clone(),
                        uri: uri.clone(),
                        parent_uri: parent_uri(&uri),
                        is_folder: file.file_type == file_type::FOLDER,
                        version: item_version,
                        seen_generation: generation,
                    });
                    if file.file_type == file_type::FOLDER && !is_received_share(&file) {
                        queue.push_back(uri);
                    }
                    seen += 1;
                }
                self.inventory.upsert_fileprovider_remote_items(&rows)?;
                self.flush_fileprovider_audit_events(&drive_id, &drive_name, &mut events)?;
                if !more {
                    break;
                }
                page = Some(response);
            }
            tokio::time::sleep(DIRECTORY_DELAY).await;
        }

        let missing = self
            .inventory
            .finish_fileprovider_remote_generation(&drive_id, generation)?;
        for item in collapse_missing_items(missing) {
            events.push(FileEventData {
                event_type: FileEventType::Delete,
                file_id: item.remote_id,
                from: canonical_uri(&item.uri),
                to: String::new(),
            });
        }
        flush_events(&drive_id, &drive_name, &mut events)?;
        tracing::info!(target: "fileprovider_audit", id=%drive_id, seen, "Metadata-only File Provider recovery audit completed");
        Ok(())
    }

    fn flush_fileprovider_audit_events(
        &self,
        drive_id: &str,
        drive_name: &str,
        events: &mut Vec<FileEventData>,
    ) -> Result<()> {
        if events.len() < EVENT_BATCH_SIZE {
            return Ok(());
        }
        flush_events(drive_id, drive_name, events)
    }
}

fn flush_events(drive_id: &str, drive_name: &str, events: &mut Vec<FileEventData>) -> Result<()> {
    if events.is_empty() {
        return Ok(());
    }
    crate::fileprovider::append_domain_events(drive_id, events, &HashSet::new())?;
    events.clear();
    crate::fileprovider::signal_containers(
        &crate::fileprovider::domain_identifier(drive_id),
        drive_name,
        &[crate::fileprovider::WORKING_SET_CONTAINER.to_string()],
    );
    Ok(())
}

/// Reporting a missing folder removes its descendants too, so avoid sending
/// redundant child deletions that can confuse File Provider ordering.
fn collapse_missing_items(mut items: Vec<FileProviderRemoteItem>) -> Vec<FileProviderRemoteItem> {
    items.sort_by_key(|item| item.uri.matches('/').count());
    let mut roots: Vec<FileProviderRemoteItem> = Vec::new();
    for item in items {
        if roots.iter().any(|root| {
            root.is_folder
                && canonical_uri(&item.uri).starts_with(&(canonical_uri(&root.uri) + "/"))
        }) {
            continue;
        }
        roots.push(item);
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collapses_children_of_missing_folders() {
        let item = |id: &str, uri: &str, is_folder: bool| FileProviderRemoteItem {
            drive_id: "drive".into(),
            remote_id: id.into(),
            uri: uri.into(),
            parent_uri: parent_uri(uri),
            is_folder,
            version: "v".into(),
            seen_generation: 1,
        };
        let result = collapse_missing_items(vec![
            item("child", "cloudreve://my/folder/file.txt", false),
            item("folder", "cloudreve://my/folder", true),
            item("other", "cloudreve://my/other.txt", false),
        ]);
        assert_eq!(
            result
                .iter()
                .map(|item| item.remote_id.as_str())
                .collect::<Vec<_>>(),
            ["folder", "other"]
        );
    }

    #[test]
    fn received_share_shortcuts_are_not_recursively_audited() {
        let mut file = FileResponse::default();
        file.metadata = Some(HashMap::from([(
            "sys:shared_redirect".into(),
            "cloudreve://user/root".into(),
        )]));
        assert!(is_received_share(&file));
    }
}
