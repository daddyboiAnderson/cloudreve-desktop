use super::InventoryDb;
use crate::inventory::schema::fileprovider_remote_items;
use anyhow::{Context, Result};
use diesel::prelude::*;

#[derive(Debug, Clone, Queryable, Selectable)]
#[diesel(table_name = fileprovider_remote_items)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct FileProviderRemoteItem {
    pub drive_id: String,
    pub remote_id: String,
    pub uri: String,
    pub parent_uri: String,
    pub is_folder: bool,
    pub version: String,
    pub seen_generation: i64,
}

#[derive(Debug, Clone, Insertable)]
#[diesel(table_name = fileprovider_remote_items)]
pub struct NewFileProviderRemoteItem {
    pub drive_id: String,
    pub remote_id: String,
    pub uri: String,
    pub parent_uri: String,
    pub is_folder: bool,
    pub version: String,
    pub seen_generation: i64,
}

impl InventoryDb {
    pub fn fileprovider_remote_items(&self, drive: &str) -> Result<Vec<FileProviderRemoteItem>> {
        let mut conn = self.connection()?;
        fileprovider_remote_items::table
            .filter(fileprovider_remote_items::drive_id.eq(drive))
            .select(FileProviderRemoteItem::as_select())
            .load(&mut conn)
            .context("Failed to read File Provider recovery inventory")
    }

    pub fn upsert_fileprovider_remote_items(
        &self,
        items: &[NewFileProviderRemoteItem],
    ) -> Result<()> {
        if items.is_empty() {
            return Ok(());
        }
        let mut conn = self.connection()?;
        (&mut *conn)
            .transaction::<(), diesel::result::Error, _>(|tx| {
                for item in items {
                    diesel::insert_into(fileprovider_remote_items::table)
                        .values(item)
                        .on_conflict((
                            fileprovider_remote_items::drive_id,
                            fileprovider_remote_items::remote_id,
                        ))
                        .do_update()
                        .set((
                            fileprovider_remote_items::uri.eq(&item.uri),
                            fileprovider_remote_items::parent_uri.eq(&item.parent_uri),
                            fileprovider_remote_items::is_folder.eq(item.is_folder),
                            fileprovider_remote_items::version.eq(&item.version),
                            fileprovider_remote_items::seen_generation.eq(item.seen_generation),
                        ))
                        .execute(tx)?;
                }
                Ok(())
            })
            .context("Failed to update File Provider recovery inventory")
    }

    pub fn finish_fileprovider_remote_generation(
        &self,
        drive: &str,
        generation: i64,
    ) -> Result<Vec<FileProviderRemoteItem>> {
        let mut conn = self.connection()?;
        (&mut *conn)
            .transaction::<Vec<FileProviderRemoteItem>, diesel::result::Error, _>(|tx| {
                let missing = fileprovider_remote_items::table
                    .filter(fileprovider_remote_items::drive_id.eq(drive))
                    .filter(fileprovider_remote_items::seen_generation.ne(generation))
                    .select(FileProviderRemoteItem::as_select())
                    .load(tx)?;
                diesel::delete(
                    fileprovider_remote_items::table
                        .filter(fileprovider_remote_items::drive_id.eq(drive))
                        .filter(fileprovider_remote_items::seen_generation.ne(generation)),
                )
                .execute(tx)?;
                Ok(missing)
            })
            .context("Failed to finish File Provider recovery generation")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, generation: i64) -> NewFileProviderRemoteItem {
        NewFileProviderRemoteItem {
            drive_id: "drive".into(),
            remote_id: id.into(),
            uri: format!("cloudreve://my/{id}"),
            parent_uri: "cloudreve://my".into(),
            is_folder: false,
            version: format!("v{generation}"),
            seen_generation: generation,
        }
    }

    #[test]
    fn completed_generation_returns_and_removes_only_missing_items() {
        let temp = tempfile::tempdir().unwrap();
        let inventory = InventoryDb::with_path(temp.path().join("inventory.db")).unwrap();
        inventory
            .upsert_fileprovider_remote_items(&[row("kept", 1), row("missing", 1)])
            .unwrap();
        inventory
            .upsert_fileprovider_remote_items(&[row("kept", 2)])
            .unwrap();

        let missing = inventory
            .finish_fileprovider_remote_generation("drive", 2)
            .unwrap();
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].remote_id, "missing");
        assert_eq!(
            inventory.fileprovider_remote_items("drive").unwrap().len(),
            1
        );
    }
}
