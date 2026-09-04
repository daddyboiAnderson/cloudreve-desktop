#![cfg(target_os = "macos")]

use crate::upload_conflict::UploadConflictRecord;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

#[derive(Clone, Debug, Deserialize)]
struct PendingSnapshot {
    drive_id: String,
    drive_name: String,
    updated_at: i64,
    items: Vec<PendingRecord>,
}

#[derive(Clone, Debug, Deserialize)]
struct PendingRecord {
    item_identifier: String,
    filename: String,
    is_folder: bool,
    operation: String,
    error_domain: String,
    error_code: i64,
    message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FileProviderIssue {
    pub id: String,
    pub drive_id: String,
    pub drive_name: String,
    pub item_identifier: String,
    pub filename: String,
    pub is_folder: bool,
    pub operation: String,
    pub source: String,
    pub kind: Option<String>,
    pub application: Option<String>,
    pub message: String,
    pub error_domain: Option<String>,
    pub error_code: Option<i64>,
    pub conflict_id: Option<String>,
    pub updated_at: i64,
}

pub fn list(known_drive_ids: &HashSet<String>) -> Result<Vec<FileProviderIssue>> {
    let home = dirs::home_dir().context("Could not find the home directory")?;
    let snapshots = read_pending_snapshots(&home.join(".cloudreve/fileprovider-pending"))?;
    let conflicts = crate::upload_conflict::list()?;
    Ok(merge(snapshots, conflicts, known_drive_ids))
}

fn read_pending_snapshots(directory: &Path) -> Result<Vec<PendingSnapshot>> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };

    let mut snapshots = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        match fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
        {
            Some(snapshot) => snapshots.push(snapshot),
            None => tracing::warn!(
                target: "fileprovider",
                path = %path.display(),
                "Ignoring an invalid pending-item snapshot"
            ),
        }
    }
    Ok(snapshots)
}

fn merge(
    snapshots: Vec<PendingSnapshot>,
    conflicts: Vec<UploadConflictRecord>,
    known_drive_ids: &HashSet<String>,
) -> Vec<FileProviderIssue> {
    let mut issues = HashMap::<(String, String), FileProviderIssue>::new();

    for snapshot in snapshots {
        if !known_drive_ids.contains(&snapshot.drive_id) {
            continue;
        }
        for item in snapshot.items {
            let key = (snapshot.drive_id.clone(), item.item_identifier.clone());
            let stable_id = uuid::Uuid::new_v5(
                &uuid::Uuid::NAMESPACE_OID,
                format!("{}\0{}", key.0, key.1).as_bytes(),
            );
            issues.insert(
                key,
                FileProviderIssue {
                    id: format!("pending:{stable_id}"),
                    drive_id: snapshot.drive_id.clone(),
                    drive_name: snapshot.drive_name.clone(),
                    item_identifier: item.item_identifier,
                    filename: item.filename,
                    is_folder: item.is_folder,
                    operation: item.operation,
                    source: "pending".to_string(),
                    kind: None,
                    application: None,
                    message: item.message,
                    error_domain: Some(item.error_domain),
                    error_code: Some(item.error_code),
                    conflict_id: None,
                    updated_at: snapshot.updated_at,
                },
            );
        }
    }

    for conflict in conflicts {
        if !known_drive_ids.contains(&conflict.drive_id) {
            continue;
        }
        let key = (conflict.drive_id.clone(), conflict.item_identifier.clone());
        if conflict.action.is_some() {
            issues.remove(&key);
            continue;
        }
        let message = match conflict.kind.as_str() {
            "locked" => "Someone has this file open online.".to_string(),
            "stale" => "The online file changed before your edit could be uploaded.".to_string(),
            _ => "Cloudreve could not verify which online version you edited.".to_string(),
        };
        issues.insert(
            key,
            FileProviderIssue {
                id: format!("conflict:{}", conflict.id),
                drive_id: conflict.drive_id,
                drive_name: conflict.drive_name,
                item_identifier: conflict.item_identifier,
                filename: conflict.filename,
                is_folder: false,
                operation: "upload".to_string(),
                source: "upload_conflict".to_string(),
                kind: Some(conflict.kind),
                application: conflict.application,
                message,
                error_domain: Some("NSFileProviderErrorDomain".to_string()),
                error_code: Some(-2005),
                conflict_id: Some(conflict.id),
                updated_at: conflict.updated_at,
            },
        );
    }

    let mut issues = issues.into_values().collect::<Vec<_>>();
    issues.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.drive_name.cmp(&right.drive_name))
            .then_with(|| left.filename.cmp(&right.filename))
            .then_with(|| left.item_identifier.cmp(&right.item_identifier))
    });
    issues
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending_snapshot() -> PendingSnapshot {
        PendingSnapshot {
            drive_id: "drive-1".to_string(),
            drive_name: "My Files".to_string(),
            updated_at: 10,
            items: vec![PendingRecord {
                item_identifier: "cloudreve-item:/abc".to_string(),
                filename: "report.docx".to_string(),
                is_folder: false,
                operation: "upload".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -2005,
                message: "Could not synchronize".to_string(),
            }],
        }
    }

    fn conflict() -> UploadConflictRecord {
        UploadConflictRecord {
            id: "0123456789abcdef".to_string(),
            drive_id: "drive-1".to_string(),
            drive_name: "My Files".to_string(),
            uri: "cloudreve://my/report.docx".to_string(),
            item_identifier: "cloudreve-item:/abc".to_string(),
            filename: "report.docx".to_string(),
            kind: "locked".to_string(),
            application: Some("OnlyOffice".to_string()),
            owner_id: Some("user-1".to_string()),
            owner_name: None,
            previous_version: None,
            action: None,
            presented_at: 0,
            updated_at: 20,
        }
    }

    #[test]
    fn managed_conflict_replaces_the_matching_pending_error() {
        let known = HashSet::from(["drive-1".to_string()]);
        let issues = merge(vec![pending_snapshot()], vec![conflict()], &known);
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].source, "upload_conflict");
        assert_eq!(issues[0].application.as_deref(), Some("OnlyOffice"));
    }

    #[test]
    fn ignores_snapshots_for_removed_drives() {
        let issues = merge(vec![pending_snapshot()], Vec::new(), &HashSet::new());
        assert!(issues.is_empty());
    }

    #[test]
    fn hides_a_conflict_while_its_resolution_is_pending() {
        let known = HashSet::from(["drive-1".to_string()]);
        let mut conflict = conflict();
        conflict.action = Some("retry".to_string());
        let issues = merge(vec![pending_snapshot()], vec![conflict], &known);
        assert!(issues.is_empty());
    }

    #[test]
    fn pending_items_with_the_same_timestamp_have_a_stable_order() {
        let known = HashSet::from(["drive-1".to_string()]);
        let mut snapshot = pending_snapshot();
        snapshot.items = vec![
            PendingRecord {
                item_identifier: "cloudreve-item:/two".to_string(),
                filename: "zebra.docx".to_string(),
                is_folder: false,
                operation: "download".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -1004,
                message: "Could not synchronize".to_string(),
            },
            PendingRecord {
                item_identifier: "cloudreve-item:/one".to_string(),
                filename: "alpha.docx".to_string(),
                is_folder: false,
                operation: "download".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -1004,
                message: "Could not synchronize".to_string(),
            },
        ];

        let issues = merge(vec![snapshot], Vec::new(), &known);
        let filenames = issues
            .iter()
            .map(|issue| issue.filename.as_str())
            .collect::<Vec<_>>();
        assert_eq!(filenames, vec!["alpha.docx", "zebra.docx"]);
    }
}
