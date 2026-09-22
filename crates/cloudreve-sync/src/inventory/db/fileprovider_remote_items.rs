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
        self.upsert_fileprovider_remote_items_with_events(items, &[])
    }

    pub fn upsert_fileprovider_remote_items_with_events(
        &self,
        items: &[NewFileProviderRemoteItem],
        events: &[crate::fileprovider::FpEventRecord],
    ) -> Result<()> {
        if items.is_empty() {
            return Ok(());
        }
        let mut conn = self.connection()?;
        (&mut *conn)
            .transaction::<(), anyhow::Error, _>(|tx| {
                enqueue_events(tx, &items[0].drive_id, events)?;
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
            .transaction::<Vec<FileProviderRemoteItem>, anyhow::Error, _>(|tx| {
                let missing = fileprovider_remote_items::table
                    .filter(fileprovider_remote_items::drive_id.eq(drive))
                    .filter(fileprovider_remote_items::seen_generation.ne(generation))
                    .select(FileProviderRemoteItem::as_select())
                    .load::<FileProviderRemoteItem>(tx)?;
                let events =
                    crate::drive::fileprovider_audit::collapse_missing_items(missing.clone())
                        .into_iter()
                        .map(|item| crate::fileprovider::FpEventRecord {
                            ts: 0,
                            event_type: "delete".into(),
                            from: item.uri,
                            to: String::new(),
                            local_echo: false,
                        })
                        .collect::<Vec<_>>();
                enqueue_events(tx, drive, &events)?;
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

    /// A crash after delivery but before acknowledgement replays the same ID;
    /// the shared journal deduplicates it in the event insertion transaction.
    pub fn deliver_fileprovider_outbox(&self, drive: &str) -> Result<()> {
        use diesel::sql_types::Text;
        #[derive(QueryableByName)]
        struct Delivery {
            #[diesel(sql_type = Text)]
            id: String,
            #[diesel(sql_type = Text)]
            payload: String,
        }
        let mut conn = self.connection()?;
        let deliveries = diesel::sql_query(
            "SELECT id,payload FROM fileprovider_outbox WHERE drive=? ORDER BY rowid",
        )
        .bind::<Text, _>(drive)
        .load::<Delivery>(&mut conn)?;
        if deliveries.is_empty() {
            return Ok(());
        }
        let mut db = crate::fileprovider_db::StateDb::open()?;
        for delivery in deliveries {
            let mut events =
                serde_json::from_str::<Vec<crate::fileprovider::FpEventRecord>>(&delivery.payload)?;
            db.append_delivery(drive, &mut events, Some(&delivery.id))?;
            diesel::sql_query("DELETE FROM fileprovider_outbox WHERE id=?")
                .bind::<Text, _>(&delivery.id)
                .execute(&mut conn)?;
            // Once the outbox row is gone no replay is possible. A crash here
            // can leave a harmless deduplication token, never duplicate events.
            db.acknowledge_delivery(&delivery.id)?;
        }
        Ok(())
    }
}

fn enqueue_events(
    tx: &mut SqliteConnection,
    drive: &str,
    events: &[crate::fileprovider::FpEventRecord],
) -> Result<()> {
    use diesel::sql_types::Text;
    if events.is_empty() {
        return Ok(());
    }
    diesel::sql_query("INSERT INTO fileprovider_outbox(id,drive,payload) VALUES(?,?,?)")
        .bind::<Text, _>(uuid::Uuid::new_v4().to_string())
        .bind::<Text, _>(drive)
        .bind::<Text, _>(serde_json::to_string(events)?)
        .execute(tx)?;
    Ok(())
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

    #[test]
    fn inventory_and_outbox_commit_or_rollback_together() {
        let temp = tempfile::tempdir().unwrap();
        let inventory = InventoryDb::with_path(temp.path().join("inventory.db")).unwrap();
        let event = crate::fileprovider::FpEventRecord {
            ts: 0,
            event_type: "create".into(),
            from: "/new".into(),
            to: String::new(),
            local_echo: false,
        };
        {
            use diesel::connection::SimpleConnection;
            inventory.connection().unwrap().batch_execute("CREATE TRIGGER fail_outbox BEFORE INSERT ON fileprovider_outbox BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;").unwrap();
        }
        assert!(
            inventory
                .upsert_fileprovider_remote_items_with_events(&[row("new", 1)], &[event])
                .is_err()
        );
        assert!(
            inventory
                .fileprovider_remote_items("drive")
                .unwrap()
                .is_empty()
        );
    }
}
