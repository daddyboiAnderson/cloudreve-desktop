use super::InventoryDb;
use crate::inventory::{ConflictState, FileMetadata, MetadataEntry};
use anyhow::{Context, Result};
use diesel::prelude::*;
use diesel::sql_types::Text;
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[cfg(target_os = "macos")]
use crate::inventory::schema::fileprovider_remote_items;
use crate::inventory::schema::{
    drive_props,
    file_metadata::{self, dsl as file_metadata_dsl},
    task_queue, upload_sessions,
};

impl InventoryDb {
    pub fn batch_insert(&self, entries: &[MetadataEntry]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }

        let rows: Vec<NewFileMetadata> = entries
            .iter()
            .map(NewFileMetadata::try_from)
            .collect::<Result<_>>()?;

        let changesets: Vec<FileMetadataChangeset> = entries
            .iter()
            .map(FileMetadataChangeset::from_entry)
            .collect::<Result<_>>()?;

        let mut conn = self.connection()?;
        (&mut *conn)
            .transaction::<(), diesel::result::Error, _>(|tx_conn| {
                for (row, changeset) in rows.iter().zip(changesets.iter()) {
                    diesel::insert_into(file_metadata::table)
                        .values(row)
                        .on_conflict(file_metadata::local_path)
                        .do_update()
                        .set(changeset)
                        .execute(tx_conn)?;
                }
                Ok(())
            })
            .context("Failed to batch upsert inventory metadata")?;
        Ok(())
    }

    pub fn nuke_drive(&self, drive: &str) -> Result<()> {
        let mut conn = self.connection()?;
        (&mut *conn)
            .transaction::<(), diesel::result::Error, _>(|tx_conn| {
                // A removed drive must not leave resumable uploads or status
                // rows behind. Delete dependent records before its metadata.
                diesel::delete(upload_sessions::table.filter(upload_sessions::drive_id.eq(drive)))
                    .execute(tx_conn)?;
                diesel::delete(task_queue::table.filter(task_queue::drive_id.eq(drive)))
                    .execute(tx_conn)?;
                diesel::delete(drive_props::table.filter(drive_props::drive_id.eq(drive)))
                    .execute(tx_conn)?;
                #[cfg(target_os = "macos")]
                diesel::delete(
                    fileprovider_remote_items::table
                        .filter(fileprovider_remote_items::drive_id.eq(drive)),
                )
                .execute(tx_conn)?;
                diesel::delete(
                    file_metadata_dsl::file_metadata.filter(file_metadata_dsl::drive_id.eq(drive)),
                )
                .execute(tx_conn)?;
                Ok(())
            })
            .context("Failed to delete inventory rows for drive")?;
        Ok(())
    }

    /// Insert a new file metadata entry
    pub fn insert(&self, entry: &MetadataEntry) -> Result<usize> {
        let mut conn = self.connection()?;
        let new_entry = NewFileMetadata::try_from(entry)?;
        diesel::insert_into(file_metadata::table)
            .values(&new_entry)
            .execute(&mut conn)
            .context("Failed to insert inventory metadata")
    }

    /// Update an existing file metadata entry by local path
    pub fn update(&self, entry: &MetadataEntry) -> Result<bool> {
        let mut conn = self.connection()?;
        let changeset = FileMetadataChangeset::from_entry(entry)?;
        let rows_affected = diesel::update(
            file_metadata_dsl::file_metadata
                .filter(file_metadata_dsl::local_path.eq(&entry.local_path)),
        )
        .set(changeset)
        .execute(&mut conn)
        .context("Failed to update inventory metadata")?;
        Ok(rows_affected > 0)
    }

    /// Insert or update a file metadata entry (upsert based on local_path)
    pub fn upsert(&self, entry: &MetadataEntry) -> Result<usize> {
        let mut conn = self.connection()?;
        let insert_data = NewFileMetadata::try_from(entry)?;
        let update_data = FileMetadataChangeset::from_entry(entry)?;

        diesel::insert_into(file_metadata::table)
            .values(&insert_data)
            .on_conflict(file_metadata::local_path)
            .do_update()
            .set(update_data)
            .execute(&mut conn)
            .context("Failed to upsert inventory metadata")
    }

    /// Query file metadata by local path
    pub fn query_by_path(&self, path: &str) -> Result<Option<FileMetadata>> {
        let mut conn = self.connection()?;
        let row = file_metadata_dsl::file_metadata
            .filter(file_metadata_dsl::local_path.eq(path))
            .first::<FileMetadataRow>(&mut conn)
            .optional()
            .context("Failed to query inventory metadata by path")?;

        row.map(FileMetadata::try_from).transpose()
    }

    /// Query every known item for one configured drive.
    ///
    /// This is primarily used by platform integrations that need to inspect
    /// native state (for example Windows Cloud Files pin state) while keeping
    /// the result strictly scoped to Cloudreve-owned sync roots.
    pub fn query_by_drive(&self, drive: &str) -> Result<Vec<FileMetadata>> {
        let mut conn = self.connection()?;
        file_metadata_dsl::file_metadata
            .filter(file_metadata_dsl::drive_id.eq(drive))
            .order(file_metadata_dsl::local_path.asc())
            .load::<FileMetadataRow>(&mut conn)
            .context("Failed to query inventory metadata by drive")?
            .into_iter()
            .map(FileMetadata::try_from)
            .collect()
    }

    /// Query file metadata by id
    pub fn query_by_id(&self, id: i64) -> Result<Option<FileMetadata>> {
        let mut conn = self.connection()?;
        let row = file_metadata_dsl::file_metadata
            .filter(file_metadata_dsl::id.eq(id))
            .first::<FileMetadataRow>(&mut conn)
            .optional()
            .context("Failed to query inventory metadata by id")?;

        row.map(FileMetadata::try_from).transpose()
    }

    /// List all distinct drive IDs present anywhere in the inventory.
    ///
    /// Including task/session/property tables lets startup cleanup find drives
    /// whose file metadata was already removed by an older app version.
    pub fn list_drive_ids(&self) -> Result<Vec<String>> {
        let mut conn = self.connection()?;
        let mut ids = HashSet::new();
        ids.extend(
            file_metadata_dsl::file_metadata
                .select(file_metadata_dsl::drive_id)
                .distinct()
                .load::<String>(&mut conn)
                .context("Failed to list file metadata drive IDs")?,
        );
        ids.extend(
            task_queue::table
                .select(task_queue::drive_id)
                .distinct()
                .load::<String>(&mut conn)
                .context("Failed to list task queue drive IDs")?,
        );
        ids.extend(
            upload_sessions::table
                .select(upload_sessions::drive_id)
                .distinct()
                .load::<String>(&mut conn)
                .context("Failed to list upload session drive IDs")?,
        );
        ids.extend(
            drive_props::table
                .select(drive_props::drive_id)
                .distinct()
                .load::<String>(&mut conn)
                .context("Failed to list drive property IDs")?,
        );
        #[cfg(target_os = "macos")]
        ids.extend(
            fileprovider_remote_items::table
                .select(fileprovider_remote_items::drive_id)
                .distinct()
                .load::<String>(&mut conn)
                .context("Failed to list File Provider recovery drive IDs")?,
        );

        let mut ids = ids.into_iter().collect::<Vec<_>>();
        ids.sort();
        Ok(ids)
    }

    /// Query files that are waiting for manual conflict resolution.
    ///
    /// `drive_id` is optional because the popup can show either a single drive
    /// or the aggregate status across all configured drives.
    pub fn query_pending_conflicts(&self, drive_id: Option<&str>) -> Result<Vec<FileMetadata>> {
        let mut conn = self.connection()?;
        let mut query = file_metadata_dsl::file_metadata
            .filter(
                file_metadata_dsl::conflict_state
                    .eq(Some(ConflictState::Pending.as_str().to_string())),
            )
            .into_boxed();

        if let Some(drive_id) = drive_id {
            query = query.filter(file_metadata_dsl::drive_id.eq(drive_id));
        }

        query
            .order(file_metadata_dsl::updated_at.desc())
            .load::<FileMetadataRow>(&mut conn)
            .context("Failed to query pending conflict metadata")?
            .into_iter()
            .map(FileMetadata::try_from)
            .collect()
    }

    /// Batch delete file metadata by local path
    pub fn batch_delete_by_path(&self, paths: Vec<&str>) -> Result<bool> {
        if paths.is_empty() {
            return Ok(false);
        }

        let affected = {
            let mut conn = self.connection()?;
            (&mut *conn)
                .transaction::<i64, diesel::result::Error, _>(|tx_conn| {
                    let mut total: i64 = 0;
                    for path in &paths {
                        total += diesel::delete(
                            file_metadata_dsl::file_metadata
                                .filter(file_metadata_dsl::local_path.eq(path)),
                        )
                        .execute(tx_conn)? as i64;

                        // SQLite LIKE has no default escape character. Escape
                        // wildcard characters in user-controlled file names,
                        // and use the platform separator so Windows descendant
                        // rows (which contain backslashes) are actually removed.
                        let escaped_path = path
                            .replace('!', "!!")
                            .replace('%', "!%")
                            .replace('_', "!_");
                        let prefix = format!("{}{}%", escaped_path, std::path::MAIN_SEPARATOR);
                        total += diesel::delete(
                            file_metadata_dsl::file_metadata
                                .filter(file_metadata_dsl::local_path.like(&prefix).escape('!')),
                        )
                        .execute(tx_conn)? as i64;
                    }
                    Ok(total)
                })
                .context("Failed to batch delete inventory metadata")?
        }; // conn is dropped here, releasing it back to the pool

        // Delete upload sessions - now safe to acquire a new connection
        self.batch_delete_upload_session_by_path(&paths)?;
        Ok(affected > 0)
    }

    /// Get total count of entries in the database
    pub fn count(&self) -> Result<i64> {
        let mut conn = self.connection()?;
        file_metadata_dsl::file_metadata
            .count()
            .get_result(&mut conn)
            .context("Failed to count inventory metadata")
    }

    /// Clear all entries from the database
    pub fn clear(&self) -> Result<()> {
        let mut conn = self.connection()?;
        diesel::delete(file_metadata::table)
            .execute(&mut conn)
            .context("Failed to clear inventory metadata")?;
        Ok(())
    }

    /// Rename or move a file/folder and update all its descendants.
    /// Uses two UPDATE queries: one for the exact path, one for descendants.
    /// Only replaces the prefix portion to avoid issues with duplicate path segments.
    ///
    /// Returns the number of rows updated.
    pub fn rename_path(&self, old_path: &str, new_path: &str) -> Result<usize> {
        if old_path == new_path {
            return Ok(0);
        }

        let mut conn = self.connection()?;
        let old_prefix = format!("{}{}", old_path, std::path::MAIN_SEPARATOR);
        let new_prefix = format!("{}{}", new_path, std::path::MAIN_SEPARATOR);
        let descendant_like = format!("{}%", old_prefix);

        let total = (&mut *conn)
            .transaction::<usize, diesel::result::Error, _>(|tx_conn| {
                let exact = diesel::update(
                    file_metadata_dsl::file_metadata
                        .filter(file_metadata_dsl::local_path.eq(old_path)),
                )
                .set((file_metadata_dsl::local_path.eq(new_path),))
                .execute(tx_conn)?;

                let descendants = diesel::sql_query(
                    "UPDATE file_metadata \
                     SET local_path = ? || substr(local_path, length(?) + 1) \
                     WHERE local_path LIKE ?",
                )
                .bind::<Text, _>(&new_prefix)
                .bind::<Text, _>(&old_prefix)
                .bind::<Text, _>(&descendant_like)
                .execute(tx_conn)?;

                Ok(exact + descendants)
            })
            .context("Failed to rename metadata path")?;

        Ok(total)
    }

    /// Mark a file as conflicted by setting its conflict_state.
    /// Pass `None` to clear the conflict state.
    ///
    /// Returns true if a row was updated.
    pub fn mark_as_conflicted(&self, path: &str, state: Option<ConflictState>) -> Result<bool> {
        let mut conn = self.connection()?;
        let state_str = state.map(|s| s.as_str().to_string());
        let rows_affected = diesel::update(
            file_metadata_dsl::file_metadata.filter(file_metadata_dsl::local_path.eq(path)),
        )
        .set(file_metadata_dsl::conflict_state.eq(state_str))
        .execute(&mut conn)
        .context("Failed to update conflict state")?;
        Ok(rows_affected > 0)
    }
}

// =========================================================================
// Row Types
// =========================================================================

#[derive(Queryable)]
struct FileMetadataRow {
    id: i64,
    drive_id: String,
    is_folder: bool,
    local_path: String,
    created_at: i64,
    updated_at: i64,
    etag: String,
    metadata: String,
    props: Option<String>,
    permissions: String,
    shared: bool,
    size: i64,
    conflict_state: Option<String>,
    local_updated_at: Option<i64>,
    local_size: Option<i64>,
}

#[derive(Insertable)]
#[diesel(table_name = file_metadata)]
struct NewFileMetadata {
    drive_id: String,
    is_folder: bool,
    local_path: String,
    created_at: i64,
    updated_at: i64,
    etag: String,
    metadata: String,
    props: Option<String>,
    permissions: String,
    shared: bool,
    size: i64,
    conflict_state: Option<String>,
    local_updated_at: Option<i64>,
    local_size: Option<i64>,
}

#[derive(AsChangeset)]
#[diesel(table_name = file_metadata)]
struct FileMetadataChangeset {
    drive_id: String,
    is_folder: bool,
    updated_at: i64,
    etag: String,
    metadata: String,
    /// Nested option is required so an entry without props clears stale
    /// local-only presentation data instead of Diesel skipping the column.
    props: Option<Option<String>>,
    permissions: String,
    shared: bool,
    size: i64,
    /// Use Option<Option<String>> so that:
    /// - Some(None) explicitly sets conflict_state to NULL
    /// - Some(Some(value)) sets it to a value
    conflict_state: Option<Option<String>>,
    /// Local snapshots are only overwritten when the new entry carries one;
    /// entries built without snapshot info leave the stored value untouched.
    local_updated_at: Option<Option<i64>>,
    local_size: Option<Option<i64>>,
}

impl TryFrom<FileMetadataRow> for FileMetadata {
    type Error = anyhow::Error;

    fn try_from(row: FileMetadataRow) -> Result<Self> {
        let metadata_map: HashMap<String, String> =
            serde_json::from_str(&row.metadata).context("Failed to deserialize metadata column")?;
        let props_value = match row.props {
            Some(json) => {
                Some(serde_json::from_str(&json).context("Failed to deserialize props column")?)
            }
            None => None,
        };
        let conflict_state = row
            .conflict_state
            .as_deref()
            .and_then(ConflictState::from_str);

        Ok(FileMetadata {
            id: row.id,
            drive_id: Uuid::parse_str(&row.drive_id).context("Failed to parse drive_id column")?,
            is_folder: row.is_folder,
            local_path: row.local_path,
            created_at: row.created_at,
            updated_at: row.updated_at,
            etag: row.etag,
            metadata: metadata_map,
            props: props_value,
            permissions: row.permissions,
            shared: row.shared,
            size: row.size,
            conflict_state,
            local_updated_at: row.local_updated_at,
            local_size: row.local_size,
        })
    }
}

impl TryFrom<&MetadataEntry> for NewFileMetadata {
    type Error = anyhow::Error;

    fn try_from(entry: &MetadataEntry) -> Result<Self> {
        Ok(Self {
            drive_id: entry.drive_id.to_string(),
            is_folder: entry.is_folder,
            local_path: entry.local_path.clone(),
            created_at: entry.created_at,
            updated_at: entry.updated_at,
            etag: entry.etag.clone(),
            metadata: serde_json::to_string(&entry.metadata)
                .context("Failed to serialize metadata map")?,
            props: entry
                .props
                .as_ref()
                .map(serde_json::to_string)
                .transpose()
                .context("Failed to serialize props field")?,
            permissions: entry.permissions.clone(),
            shared: entry.shared,
            size: entry.size,
            conflict_state: entry.conflict_state.map(|s| s.as_str().to_string()),
            local_updated_at: entry.local_updated_at,
            local_size: entry.local_size,
        })
    }
}

impl FileMetadataChangeset {
    fn from_entry(entry: &MetadataEntry) -> Result<Self> {
        Ok(Self {
            drive_id: entry.drive_id.to_string(),
            is_folder: entry.is_folder,
            updated_at: entry.updated_at,
            etag: entry.etag.clone(),
            metadata: serde_json::to_string(&entry.metadata)
                .context("Failed to serialize metadata map")?,
            props: Some(
                entry
                    .props
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()
                    .context("Failed to serialize props field")?,
            ),
            permissions: entry.permissions.clone(),
            shared: entry.shared,
            size: entry.size,
            // Use Some(...) to always update the column, even when clearing to NULL
            conflict_state: Some(entry.conflict_state.map(|s| s.as_str().to_string())),
            // Keep the stored snapshot when the entry carries none
            local_updated_at: entry.local_updated_at.map(Some),
            local_size: entry.local_size.map(Some),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{NewTaskRecord, TaskStatus};

    fn test_inventory() -> (tempfile::TempDir, InventoryDb) {
        let temp_dir = tempfile::tempdir().expect("create temp directory");
        let inventory =
            InventoryDb::with_path(temp_dir.path().join("inventory.db")).expect("create inventory");
        (temp_dir, inventory)
    }

    #[test]
    fn batch_insert_updates_existing_paths() {
        let (_temp_dir, inventory) = test_inventory();
        let drive_id = Uuid::new_v4();
        let path = "C:\\Cloudreve\\same-file.txt";

        inventory
            .batch_insert(&[MetadataEntry::new(drive_id, path, false)
                .with_etag("old")
                .with_size(10)])
            .expect("insert initial metadata");
        inventory
            .batch_insert(&[MetadataEntry::new(drive_id, path, false)
                .with_etag("new")
                .with_size(20)])
            .expect("upsert repeated metadata");

        let stored = inventory
            .query_by_path(path)
            .expect("query metadata")
            .expect("metadata exists");
        assert_eq!(inventory.count().expect("count metadata"), 1);
        assert_eq!(stored.etag, "new");
        assert_eq!(stored.size, 20);
    }

    #[test]
    fn batch_insert_clears_stale_props() {
        let (_temp_dir, inventory) = test_inventory();
        let drive_id = Uuid::new_v4();
        let path = "C:\\Cloudreve\\received-file.txt";

        inventory
            .batch_insert(&[MetadataEntry::new(drive_id, path, false).with_props(
                serde_json::json!({
                    "presented_content_uri": "cloudreve://sender-file@share"
                }),
            )])
            .expect("insert metadata with presentation props");
        inventory
            .batch_insert(&[MetadataEntry::new(drive_id, path, false)])
            .expect("replace metadata without props");

        let stored = inventory
            .query_by_path(path)
            .expect("query metadata")
            .expect("metadata exists");
        assert_eq!(stored.props, None);
    }

    #[test]
    fn query_by_drive_does_not_leak_other_drive_items() {
        let (_temp_dir, inventory) = test_inventory();
        let selected = Uuid::new_v4();
        let other = Uuid::new_v4();
        inventory
            .batch_insert(&[
                MetadataEntry::new(selected, "C:\\Cloudreve\\selected.txt", false),
                MetadataEntry::new(other, "D:\\OtherCloud\\other.txt", false),
            ])
            .expect("insert metadata");

        let items = inventory
            .query_by_drive(&selected.to_string())
            .expect("query selected drive");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].local_path, "C:\\Cloudreve\\selected.txt");
    }

    #[test]
    fn batch_delete_removes_descendants_with_native_separators_only() {
        let (_temp_dir, inventory) = test_inventory();
        let drive_id = Uuid::new_v4();
        let separator = std::path::MAIN_SEPARATOR;
        let root = format!("C:{separator}Cloudreve{separator}Shared_100%");
        let child = format!("{root}{separator}folder{separator}file.txt");
        let wildcard_sibling =
            format!("C:{separator}Cloudreve{separator}SharedX100Y{separator}file.txt");
        let prefix_sibling = format!("{root}-old{separator}file.txt");

        inventory
            .batch_insert(&[
                MetadataEntry::new(drive_id, &root, true),
                MetadataEntry::new(drive_id, &child, false),
                MetadataEntry::new(drive_id, &wildcard_sibling, false),
                MetadataEntry::new(drive_id, &prefix_sibling, false),
            ])
            .expect("insert metadata");

        inventory
            .batch_delete_by_path(vec![root.as_str()])
            .expect("delete subtree");

        assert!(inventory.query_by_path(&root).unwrap().is_none());
        assert!(inventory.query_by_path(&child).unwrap().is_none());
        assert!(
            inventory
                .query_by_path(&wildcard_sibling)
                .unwrap()
                .is_some()
        );
        assert!(inventory.query_by_path(&prefix_sibling).unwrap().is_some());
    }

    #[test]
    fn nuke_drive_removes_orphaned_task_rows() {
        let (_temp_dir, inventory) = test_inventory();
        let drive_id = Uuid::new_v4().to_string();
        let task = NewTaskRecord::new("task-id", &drive_id, "upload", "C:\\Cloudreve\\orphan.txt");
        inventory
            .insert_task_if_not_exist(&task)
            .expect("insert task");

        assert_eq!(
            inventory.list_drive_ids().expect("list drive ids"),
            [drive_id.clone()]
        );
        inventory.nuke_drive(&drive_id).expect("nuke drive");

        assert!(
            inventory
                .list_drive_ids()
                .expect("list drive ids")
                .is_empty()
        );
        assert!(
            inventory
                .list_tasks(Some(&drive_id), Some(&[TaskStatus::Pending]))
                .expect("list tasks")
                .is_empty()
        );
    }
}
