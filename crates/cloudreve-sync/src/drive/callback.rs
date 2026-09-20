use std::{sync::Arc, time::Duration};

use crate::{
    cfapi::{
        error::{CResult, CloudErrorKind},
        filter::{Request, SyncFilter, info, ticket},
        placeholder_file::PlaceholderFile,
    },
    drive::{
        commands::MountCommand,
        mounts::DeletedShareShortcutTombstones,
        sync::{cloud_file_to_metadata_entry, cloud_file_to_placeholder},
    },
    inventory::{InventoryDb, MetadataEntry},
};
use cloudreve_api::models::explorer::metadata;
use tokio::sync::mpsc;
use uuid::Uuid;

#[derive(Clone)]
pub struct CallbackHandler {
    command_tx: mpsc::UnboundedSender<MountCommand>,
    id: String,
    inventory: Arc<InventoryDb>,
    deleted_share_shortcuts: DeletedShareShortcutTombstones,
}

impl CallbackHandler {
    pub(crate) fn new(
        command_tx: mpsc::UnboundedSender<MountCommand>,
        id: String,
        inventory: Arc<InventoryDb>,
        deleted_share_shortcuts: DeletedShareShortcutTombstones,
    ) -> Self {
        Self {
            command_tx,
            id,
            inventory,
            deleted_share_shortcuts,
        }
    }

    pub async fn sleep(&self) {
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

impl SyncFilter for CallbackHandler {
    fn fetch_data(
        &self,
        request: Request,
        ticket: ticket::FetchData,
        info: info::FetchData,
    ) -> crate::cfapi::error::CResult<()> {
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        let command = MountCommand::FetchData {
            path: request.path().to_path_buf(),
            ticket,
            range: info.required_file_range(),
            response: response_tx,
        };
        if let Err(e) = self.command_tx.send(command) {
            tracing::error!(target: "drive::mounts", id = %self.id, error = %e, "Failed to send FetchData command");
            return Err(CloudErrorKind::NotSupported);
        }

        match response_rx.blocking_recv() {
            Ok(Ok(())) => Ok(()),
            _ => Err(CloudErrorKind::Unsuccessful),
        }
    }

    fn deleted(&self, request: Request, _info: info::Deleted) {
        tracing::debug!(target: "drive::mounts", id = %self.id, path = %request.path().display(), "Deleted");
    }

    fn delete(&self, request: Request, ticket: ticket::Delete, info: info::Delete) -> CResult<()> {
        let path = request.path();
        tracing::debug!(target: "drive::mounts", id = %self.id, path = %path.display(), "Delete");

        // Record the redirect root before allowing Windows to recurse into it.
        // The filesystem watcher can otherwise see child removals before the
        // root event and resolve them to the sender's real shared content.
        if !info.is_undelete() {
            let Some(path_str) = path.to_str() else {
                tracing::error!(target: "drive::mounts", id = %self.id, path = %path.display(), "Refusing to delete a non-Unicode placeholder path");
                return Err(CloudErrorKind::Unsuccessful);
            };
            match self.inventory.query_by_path(path_str) {
                Ok(Some(entry)) if entry.metadata.contains_key(metadata::SHARE_REDIRECT) => {
                    self.deleted_share_shortcuts.remember(path.clone());
                }
                Ok(_) => {}
                Err(error) => {
                    tracing::error!(target: "drive::mounts", id = %self.id, path = %path.display(), error = %error, "Refusing deletion because received-share state could not be checked");
                    return Err(CloudErrorKind::Unsuccessful);
                }
            }
        }

        let _ = ticket.pass();
        Ok(())
    }

    fn rename(&self, request: Request, ticket: ticket::Rename, info: info::Rename) -> CResult<()> {
        let src = request.path();
        let dest = info.target_path();
        tracing::debug!(target: "drive::mounts", id = %self.id, source_path = %src.display(), target_path = %dest.display(), "Rename");
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        let command = MountCommand::Rename {
            source: src.to_path_buf(),
            target: dest.to_path_buf(),
            response: response_tx,
        };
        if let Err(e) = self.command_tx.send(command) {
            tracing::error!(target: "drive::mounts", id = %self.id, error = %e, "Failed to send rename command");
            return Err(CloudErrorKind::NotSupported);
        }

        match response_rx.blocking_recv() {
            Ok(Ok(())) => {
                let _ = ticket.pass();
                Ok(())
            }
            _ => Err(CloudErrorKind::Unsuccessful),
        }
        // TODO: delete sometimes trigger rename callback
    }

    fn fetch_placeholders(
        &self,
        request: Request,
        ticket: ticket::FetchPlaceholders,
        _info: info::FetchPlaceholders,
    ) -> CResult<()> {
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        let command = MountCommand::FetchPlaceholders {
            path: request.path().to_path_buf(),
            response: response_tx,
        };
        if let Err(e) = self.command_tx.send(command) {
            tracing::error!(target: "drive::mounts", id = %self.id, error = %e, "Failed to send FetchPlaceholders command");
            return Err(CloudErrorKind::NotSupported);
        }

        match response_rx.blocking_recv() {
            Ok(Ok(files)) => {
                tracing::debug!(target: "drive::mounts", id = %self.id, files = %files.files.len(), "Received placeholders");
                let drive_id = match Uuid::parse_str(&self.id) {
                    Ok(drive_id) => drive_id,
                    Err(error) => {
                        tracing::error!(target: "drive::mounts", id = %self.id, error = %error, "Failed to parse drive ID");
                        return Err(CloudErrorKind::Unsuccessful);
                    }
                };
                let mut placeholders = Vec::<PlaceholderFile>::new();
                let mut entries = Vec::<MetadataEntry>::new();
                for file in &files.files {
                    let placeholder =
                        cloud_file_to_placeholder(file, &files.local_path, &files.remote_path);
                    let entry = cloud_file_to_metadata_entry(file, &drive_id, &files.local_path);
                    match (placeholder, entry) {
                        (Ok(placeholder), Ok(entry)) => {
                            placeholders.push(placeholder);
                            entries.push(entry);
                        }
                        (Err(error), _) => {
                            tracing::error!(target: "drive::mounts", id = %self.id, error = %error, "Failed to convert cloud file to placeholder")
                        }
                        (_, Err(error)) => {
                            tracing::error!(target: "drive::mounts", id = %self.id, error = %error, "Failed to convert cloud file to metadata entry")
                        }
                    }
                }
                if let Err(e) = ticket.pass_with_placeholder(&mut placeholders) {
                    tracing::error!(target: "drive::mounts", id = %self.id, error = %e, "Failed to pass placeholders");
                    return Err(CloudErrorKind::Unsuccessful);
                }
                tracing::debug!(target: "drive::mounts", id = %self.id, placeholders = %placeholders.len(), "Passed placeholders");

                // Insert exactly the entries that were passed to CFAPI.
                if let Err(e) = self.inventory.batch_insert(&entries) {
                    tracing::error!(target: "drive::mounts", id = %self.id, error = ?e, "Failed to insert placeholders into inventory");
                }
                return Ok(());
            }
            _ => {}
        }

        Err(CloudErrorKind::Unsuccessful)
    }

    fn closed(&self, request: Request, info: info::Closed) {
        tracing::debug!(target: "drive::mounts", id = %self.id, path = %request.path().display(), deleted = %info.deleted(), "Closed");
    }

    fn cancel_fetch_data(&self, _request: Request, _info: info::CancelFetchData) {
        tracing::debug!(target: "drive::mounts", id = %self.id, "CancelFetchData");
    }

    fn validate_data(
        &self,
        _request: Request,
        _ticket: ticket::ValidateData,
        _info: info::ValidateData,
    ) -> CResult<()> {
        tracing::debug!(target: "drive::mounts", id = %self.id, "ValidateData");
        Err(CloudErrorKind::NotSupported)
    }

    fn cancel_fetch_placeholders(&self, _request: Request, _info: info::CancelFetchPlaceholders) {
        tracing::debug!(target: "drive::mounts", id = %self.id, "CancelFetchPlaceholders");
    }

    fn opened(&self, request: Request, _info: info::Opened) {
        tracing::debug!(target: "drive::mounts", id = %self.id, path = %request.path().display(), "Opened");
    }

    fn dehydrate(
        &self,
        _request: Request,
        _ticket: ticket::Dehydrate,
        info: info::Dehydrate,
    ) -> CResult<()> {
        tracing::debug!(
            target: "drive::mounts",
            id = %self.id,
            reason = ?info.reason(),
            "Dehydrate"
        );
        Err(CloudErrorKind::NotSupported)
    }

    fn dehydrated(&self, _request: Request, info: info::Dehydrated) {
        tracing::debug!(
            target: "drive::mounts",
            id = %self.id,
            reason = ?info.reason(),
            "Dehydrated"
        );
    }

    fn renamed(&self, request: Request, info: info::Renamed) {
        let dest = request.path();
        tracing::debug!(target: "drive::mounts", id = %self.id, dest_path = %dest.display(), "Renamed");
        let command: MountCommand = MountCommand::Renamed {
            source: info.source_path(),
            destination: dest,
        };
        if let Err(e) = self.command_tx.send(command) {
            tracing::error!(target: "drive::mounts", id = %self.id, error = %e, "Failed to send Renamed command");
            return;
        }
    }
}
