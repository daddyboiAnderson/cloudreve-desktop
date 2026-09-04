#![cfg(target_os = "macos")]

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UploadConflictRecord {
    pub id: String,
    pub drive_id: String,
    pub drive_name: String,
    pub uri: String,
    pub item_identifier: String,
    pub filename: String,
    pub kind: String,
    pub application: Option<String>,
    pub owner_id: Option<String>,
    pub owner_name: Option<String>,
    pub previous_version: Option<String>,
    pub action: Option<String>,
    pub presented_at: i64,
    pub updated_at: i64,
}

fn validate_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(anyhow!("Invalid upload conflict identifier"))
    }
}

fn conflict_dir() -> Result<PathBuf> {
    let home = dirs::home_dir().context("Could not find the home directory")?;
    Ok(home.join(".cloudreve").join("upload-conflicts"))
}

fn conflict_path(id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    Ok(conflict_dir()?.join(format!("{id}.json")))
}

pub fn get(id: &str) -> Result<UploadConflictRecord> {
    let path = conflict_path(id)?;
    let data = fs::read(&path)
        .with_context(|| format!("Upload conflict {} is no longer available", path.display()))?;
    serde_json::from_slice(&data).context("Could not read the upload conflict")
}

pub fn list() -> Result<Vec<UploadConflictRecord>> {
    let dir = conflict_dir()?;
    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };

    let mut records = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        match fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
        {
            Some(record) => records.push(record),
            None => tracing::warn!(
                target: "upload_conflict",
                path = %path.display(),
                "Ignoring an invalid upload conflict record"
            ),
        }
    }
    Ok(records)
}

pub fn set_action(id: &str, action: &str) -> Result<UploadConflictRecord> {
    if !matches!(action, "save_copy" | "retry" | "discard") {
        return Err(anyhow!("Invalid upload conflict action"));
    }

    let mut record = get(id)?;
    record.action = Some(action.to_string());
    record.presented_at = 0;
    record.updated_at = chrono::Utc::now().timestamp_millis();

    let dir = conflict_dir()?;
    fs::create_dir_all(&dir)?;
    let path = conflict_path(id)?;
    let temporary = dir.join(format!(".{id}-{}.tmp", uuid::Uuid::new_v4()));
    fs::write(&temporary, serde_json::to_vec(&record)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&temporary, &path)?;
    Ok(record)
}
