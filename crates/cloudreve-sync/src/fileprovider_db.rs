//! Shared, versioned macOS state. SQLite transactions are the interprocess lock.
#![cfg(target_os = "macos")]

use crate::fileprovider::FpEventRecord;
use anyhow::{Context, Result, bail};
use diesel::{
    connection::SimpleConnection,
    prelude::*,
    sql_types::{BigInt, Text},
};
use std::path::{Path, PathBuf};

const SCHEMA: &str = include_str!("../../../macos/fileprovider/state-schema.sql");
const EVENT_RETENTION: i64 = 100_000;

#[derive(QueryableByName)]
struct Number {
    #[diesel(sql_type = BigInt)]
    value: i64,
}

#[derive(QueryableByName, Clone)]
pub struct Record {
    #[diesel(sql_type = Text)]
    pub key: String,
    #[diesel(sql_type = Text)]
    pub payload: String,
}

pub struct StateDb {
    connection: SqliteConnection,
    root: PathBuf,
}

impl StateDb {
    /// Only legacy metadata owned by this migration is eligible. Never recurse:
    /// user content, backups, symlinks and unknown files must survive upgrades.
    pub fn migrate_and_cleanup(&mut self) -> Result<usize> {
        let namespaces = ["fileprovider-activity", "fileprovider-download-retries",
            "fileprovider-pending", "fileprovider-upload-receipts", "fp-share-state",
            "pin-requests", "upload-conflicts", "fp-reset", "fp-health"];
        let mut removed = 0;
        for namespace in namespaces {
            let directory = self.root.join(namespace);
            let entries = match std::fs::symlink_metadata(&directory) {
                Ok(metadata) if metadata.file_type().is_dir() => std::fs::read_dir(&directory)?,
                Ok(_) => continue,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            };
            // Commit every record before removing any source. Import markers
            // mean previously consumed requests must NOT be imported again.
            self.import_records(namespace)?;
            for entry in entries {
                let entry = entry?;
                if !entry.file_type()?.is_file() { continue; }
                let name = entry.file_name();
                let Some(name) = name.to_str() else { continue; };
                let extension = entry.path().extension().and_then(|s| s.to_str()).map(str::to_owned);
                let recognized = match namespace {
                    "fp-reset" => extension.as_deref() == Some("marker"),
                    "fileprovider-download-retries" => name.len() == 16 && name.bytes().all(|b| b.is_ascii_hexdigit()),
                    "upload-conflicts" => matches!(extension.as_deref(), Some("json" | "refresh")),
                    _ => extension.as_deref() == Some("json"),
                };
                if !recognized || name.starts_with('.') { continue; }
                std::fs::remove_file(entry.path())?;
                removed += 1;
            }
            // Failure here can simply mean there are unknown files to preserve.
            let _ = std::fs::remove_dir(directory);
        }
        let directory = self.root.join("fp-events");
        if std::fs::symlink_metadata(&directory).is_ok_and(|m| m.file_type().is_dir()) {
            for entry in std::fs::read_dir(&directory)? {
                let entry = entry?;
                if !entry.file_type()?.is_file() { continue; }
                let name = entry.file_name();
                let Some(drive) = name.to_str().and_then(|n| n.strip_suffix(".jsonl")) else { continue; };
                if uuid::Uuid::parse_str(drive).is_err() { continue; }
                // Includes inactive drives, so removing old logs loses no history.
                self.append_events(drive, &mut [])?;
                std::fs::remove_file(entry.path())?;
                removed += 1;
            }
            let _ = std::fs::remove_dir(directory);
        }
        Ok(removed)
    }

    pub fn open() -> Result<Self> {
        Self::at(
            &dirs::home_dir()
                .context("Missing home directory")?
                .join(".cloudreve"),
        )
    }

    pub fn at(root: &Path) -> Result<Self> {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root)?;
        let path = root.join("fileprovider.db");
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&path)?;
        let mut connection =
            SqliteConnection::establish(path.to_str().context("Invalid state path")?)?;
        connection.batch_execute(
            "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
        )?;
        connection.immediate_transaction::<_, anyhow::Error, _>(|tx| {
            let tables = diesel::sql_query("SELECT COUNT(*) AS value FROM sqlite_master WHERE type='table'")
                .get_result::<Number>(tx)?.value;
            if tables == 0 { tx.batch_execute(SCHEMA)?; }
            let version = diesel::sql_query("SELECT version AS value FROM fp_state_schema")
                .get_result::<Number>(tx)?
                .value;
            if version != 1 {
                bail!("Unsupported File Provider state schema {version}");
            }
            Ok(())
        })?;
        Ok(Self {
            connection,
            root: root.to_owned(),
        })
    }

    /// Import once, transactionally. Keep originals for recovery; the import
    /// marker prevents consumed records from reappearing on subsequent launches.
    pub fn import_records(&mut self, namespace: &str) -> Result<()> {
        let directory = self.root.join(namespace);
        self.connection.immediate_transaction::<_, anyhow::Error, _>(|tx| {
            let imported = diesel::sql_query("SELECT COUNT(*) AS value FROM fp_imports WHERE namespace=?")
                .bind::<Text,_>(namespace).get_result::<Number>(tx)?.value;
            if imported != 0 { return Ok(()); }
            match std::fs::read_dir(&directory) {
                Ok(entries) => for entry in entries {
                    let entry = entry?;
                    if !entry.file_type()?.is_file() { continue; }
                    let key = entry.file_name().into_string().map_err(|_| anyhow::anyhow!("Invalid legacy state filename"))?;
                    if key.starts_with('.') { continue; }
                    let payload = std::fs::read_to_string(entry.path())?;
                    diesel::sql_query("INSERT OR IGNORE INTO fp_records(namespace,key,payload) VALUES(?,?,?)")
                        .bind::<Text,_>(namespace).bind::<Text,_>(key).bind::<Text,_>(payload).execute(tx)?;
                },
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                Err(e) => return Err(e.into()),
            }
            diesel::sql_query("INSERT INTO fp_imports(namespace) VALUES(?)").bind::<Text,_>(namespace).execute(tx)?;
            Ok(())
        })
    }

    pub fn records(&mut self, namespace: &str) -> Result<Vec<Record>> {
        self.import_records(namespace)?;
        Ok(
            diesel::sql_query("SELECT key,payload FROM fp_records WHERE namespace=? ORDER BY key")
                .bind::<Text, _>(namespace)
                .load(&mut self.connection)?,
        )
    }

    pub fn put(&mut self, namespace: &str, key: &str, payload: &str) -> Result<()> {
        self.import_records(namespace)?;
        diesel::sql_query("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload")
            .bind::<Text,_>(namespace).bind::<Text,_>(key).bind::<Text,_>(payload).execute(&mut self.connection)?;
        Ok(())
    }

    /// Compare-and-delete avoids removing a newer value produced by the extension.
    pub fn consume(&mut self, namespace: &str, record: &Record) -> Result<bool> {
        Ok(
            diesel::sql_query("DELETE FROM fp_records WHERE namespace=? AND key=? AND payload=?")
                .bind::<Text, _>(namespace)
                .bind::<Text, _>(&record.key)
                .bind::<Text, _>(&record.payload)
                .execute(&mut self.connection)?
                != 0,
        )
    }

    pub fn update(
        &mut self,
        namespace: &str,
        key: &str,
        update: impl FnOnce(&str) -> Result<String>,
    ) -> Result<String> {
        self.import_records(namespace)?;
        self.connection
            .immediate_transaction::<_, anyhow::Error, _>(|tx| {
                let record = diesel::sql_query(
                    "SELECT key,payload FROM fp_records WHERE namespace=? AND key=?",
                )
                .bind::<Text, _>(namespace)
                .bind::<Text, _>(key)
                .get_result::<Record>(tx)?;
                let payload = update(&record.payload)?;
                diesel::sql_query("UPDATE fp_records SET payload=? WHERE namespace=? AND key=?")
                    .bind::<Text, _>(&payload)
                    .bind::<Text, _>(namespace)
                    .bind::<Text, _>(key)
                    .execute(tx)?;
                Ok(payload)
            })
    }

    pub fn append_events(&mut self, drive: &str, records: &mut [FpEventRecord]) -> Result<()> {
        self.append_delivery(drive, records, None)
    }

    pub fn acknowledge_delivery(&mut self, id: &str) -> Result<()> {
        diesel::sql_query("DELETE FROM fp_deliveries WHERE id=?")
            .bind::<Text, _>(id)
            .execute(&mut self.connection)?;
        Ok(())
    }

    pub fn append_delivery(
        &mut self,
        drive: &str,
        records: &mut [FpEventRecord],
        delivery: Option<&str>,
    ) -> Result<()> {
        self.commit_events(drive, records, delivery, &[])
    }

    pub fn append_events_consuming(
        &mut self,
        drive: &str,
        records: &mut [FpEventRecord],
        receipts: &[Record],
    ) -> Result<()> {
        self.commit_events(drive, records, None, receipts)
    }

    fn commit_events(
        &mut self,
        drive: &str,
        records: &mut [FpEventRecord],
        delivery: Option<&str>,
        receipts: &[Record],
    ) -> Result<()> {
        let legacy = self.root.join("fp-events").join(format!("{drive}.jsonl"));
        self.connection.immediate_transaction::<_, anyhow::Error, _>(|tx| {
            if let Some(id) = delivery {
                let inserted = diesel::sql_query("INSERT OR IGNORE INTO fp_deliveries(id) VALUES(?)")
                    .bind::<Text,_>(id).execute(tx)?;
                if inserted == 0 { return Ok(()); }
            }
            diesel::sql_query("INSERT OR IGNORE INTO fp_event_heads(drive) VALUES(?)").bind::<Text,_>(drive).execute(tx)?;
            let imported = diesel::sql_query("SELECT imported AS value FROM fp_event_heads WHERE drive=?")
                .bind::<Text,_>(drive).get_result::<Number>(tx)?.value;
            if imported == 0 {
                let text = match std::fs::read_to_string(&legacy) {
                    Ok(text) => text,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
                    Err(e) => return Err(e.into()),
                };
                // A partial legacy line is an error, never silently acknowledged.
                let events = text.lines().filter(|line| !line.trim().is_empty())
                    .map(serde_json::from_str::<FpEventRecord>).collect::<std::result::Result<Vec<_>,_>>()?;
                for event in &events { insert_event(tx, drive, event)?; }
                let latest = events.iter().map(|e| e.ts).max().unwrap_or(0);
                let floor = events.iter().map(|e| e.ts).min().unwrap_or(0);
                diesel::sql_query("UPDATE fp_event_heads SET latest=?,floor=?,imported=1 WHERE drive=?")
                    .bind::<BigInt,_>(latest).bind::<BigInt,_>(floor).bind::<Text,_>(drive).execute(tx)?;
            }
            let mut latest = diesel::sql_query("SELECT latest AS value FROM fp_event_heads WHERE drive=?")
                .bind::<Text,_>(drive).get_result::<Number>(tx)?.value;
            for record in records {
                latest = chrono::Utc::now().timestamp_millis().max(latest.checked_add(1).context("Event sequence overflow")?);
                record.ts = latest;
                insert_event(tx, drive, record)?;
            }
            // Prune transactionally with a persisted floor. Readers below it
            // must reconcile; they cannot silently advance over removed events.
            let cutoff = diesel::sql_query("SELECT COALESCE((SELECT sequence FROM fp_events WHERE drive=? ORDER BY sequence DESC LIMIT 1 OFFSET ?),0) AS value")
                .bind::<Text,_>(drive).bind::<BigInt,_>(EVENT_RETENTION).get_result::<Number>(tx)?.value;
            diesel::sql_query("UPDATE fp_event_heads SET latest=?,floor=MAX(floor,?) WHERE drive=?")
                .bind::<BigInt,_>(latest).bind::<BigInt,_>(cutoff).bind::<Text,_>(drive).execute(tx)?;
            diesel::sql_query("DELETE FROM fp_events WHERE drive=? AND sequence<=?")
                .bind::<Text,_>(drive).bind::<BigInt,_>(cutoff).execute(tx)?;
            for receipt in receipts {
                diesel::sql_query("DELETE FROM fp_records WHERE namespace='fileprovider-upload-receipts' AND key=? AND payload=?")
                    .bind::<Text,_>(&receipt.key).bind::<Text,_>(&receipt.payload).execute(tx)?;
            }
            Ok(())
        })
    }
}

fn insert_event(tx: &mut SqliteConnection, drive: &str, event: &FpEventRecord) -> Result<()> {
    diesel::sql_query("INSERT INTO fp_events(drive,sequence,payload) VALUES(?,?,?)")
        .bind::<Text, _>(drive)
        .bind::<BigInt, _>(event.ts)
        .bind::<Text, _>(serde_json::to_string(event)?)
        .execute(tx)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event() -> FpEventRecord {
        FpEventRecord {
            ts: 0,
            event_type: "create".into(),
            from: "/Folder/你好 'quoted'.af".into(),
            to: String::new(),
            local_echo: false,
        }
    }

    #[test]
    fn cleanup_imports_before_deletion_and_preserves_unknown_files() {
        let temp = tempfile::tempdir().unwrap();
        let requests = temp.path().join("pin-requests");
        std::fs::create_dir(&requests).unwrap();
        std::fs::write(requests.join("request.json"), "{\"uri\":\"kept\"}").unwrap();
        std::fs::write(requests.join("notes.txt"), "do not delete").unwrap();
        std::fs::create_dir(temp.path().join("backup-pre-fp-reset")).unwrap();
        std::fs::create_dir(temp.path().join("fp-reset")).unwrap();
        std::fs::write(temp.path().join("fp-reset/drive.marker"), "old-reset").unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        assert_eq!(db.migrate_and_cleanup().unwrap(), 2);
        assert!(!requests.join("request.json").exists());
        assert!(requests.join("notes.txt").exists());
        assert!(temp.path().join("backup-pre-fp-reset").exists());
        let records = db.records("pin-requests").unwrap();
        assert!(records.iter().any(|r| r.key == "request.json"));
        assert!(db.records("fp-reset-requests-v2").unwrap().is_empty());
        assert!(db.consume("pin-requests", records.iter().find(|r| r.key == "request.json").unwrap()).unwrap());
        assert_eq!(db.migrate_and_cleanup().unwrap(), 0);
        assert!(!db.records("pin-requests").unwrap().iter().any(|r| r.key == "request.json"));
    }

    #[test]
    fn cleanup_preserves_failed_event_import_and_symlinks() {
        use std::os::unix::fs::symlink;
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("important.json"), "keep").unwrap();
        symlink(outside.path(), temp.path().join("pin-requests")).unwrap();
        let events = temp.path().join("fp-events");
        std::fs::create_dir(&events).unwrap();
        let log = events.join("df3d7708-4131-5518-89eb-8ef8cd4dc0db.jsonl");
        std::fs::write(&log, "{broken").unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        assert!(db.migrate_and_cleanup().is_err());
        assert!(log.exists());
        assert!(outside.path().join("important.json").exists());
        std::fs::write(&log, serde_json::to_string(&event()).unwrap()).unwrap();
        assert_eq!(db.migrate_and_cleanup().unwrap(), 1);
        assert!(!log.exists());
    }

    fn number(db: &mut StateDb, sql: &str) -> i64 {
        diesel::sql_query(sql)
            .get_result::<Number>(&mut db.connection)
            .unwrap()
            .value
    }

    #[test]
    fn migration_preserves_anchors_and_does_not_resurrect_consumed_records() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("fp-events")).unwrap();
        let mut legacy = event();
        legacy.ts = 123;
        std::fs::write(
            temp.path().join("fp-events/drive.jsonl"),
            serde_json::to_string(&legacy).unwrap(),
        )
        .unwrap();
        std::fs::create_dir(temp.path().join("pin-requests")).unwrap();
        std::fs::write(
            temp.path().join("pin-requests/request.json"),
            "{\"uri\":\"hello\"}",
        )
        .unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        db.append_events("drive", &mut [event()]).unwrap();
        assert_eq!(
            number(&mut db, "SELECT MIN(sequence) AS value FROM fp_events"),
            123
        );
        let records = db.records("pin-requests").unwrap();
        assert!(db.consume("pin-requests", &records[0]).unwrap());
        drop(db);
        let mut db = StateDb::at(temp.path()).unwrap();
        assert!(db.records("pin-requests").unwrap().is_empty());
        db.append_events("drive", &mut []).unwrap();
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_events"),
            2
        );
        assert!(temp.path().join("pin-requests/request.json").exists());
    }

    #[test]
    fn stale_consumer_cannot_delete_a_replaced_request() {
        let temp = tempfile::tempdir().unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        db.put("requests", "key", "old").unwrap();
        let old = db.records("requests").unwrap().remove(0);
        db.put("requests", "key", "new").unwrap();
        assert!(!db.consume("requests", &old).unwrap());
        assert_eq!(db.records("requests").unwrap()[0].payload, "new");
    }

    #[test]
    fn malformed_legacy_events_roll_back_import_and_delivery() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("fp-events")).unwrap();
        std::fs::write(temp.path().join("fp-events/drive.jsonl"), "{broken").unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        assert!(
            db.append_delivery("drive", &mut [event()], Some("delivery"))
                .is_err()
        );
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_events"),
            0
        );
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_deliveries"),
            0
        );
    }

    #[test]
    fn outbox_redelivery_does_not_duplicate_events() {
        let temp = tempfile::tempdir().unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        db.append_delivery("drive", &mut [event()], Some("delivery"))
            .unwrap();
        drop(db);
        let mut db = StateDb::at(temp.path()).unwrap();
        db.append_delivery("drive", &mut [event()], Some("delivery"))
            .unwrap();
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_events"),
            1
        );
    }

    #[test]
    fn upload_receipt_acknowledgement_is_atomic_with_event_commit() {
        let temp = tempfile::tempdir().unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        db.put("fileprovider-upload-receipts", "receipt", "payload")
            .unwrap();
        let receipts = db.records("fileprovider-upload-receipts").unwrap();
        db.connection.batch_execute("CREATE TRIGGER fail_event BEFORE INSERT ON fp_events BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;").unwrap();
        assert!(
            db.append_events_consuming("drive", &mut [event()], &receipts)
                .is_err()
        );
        assert_eq!(db.records("fileprovider-upload-receipts").unwrap().len(), 1);
        db.connection
            .batch_execute("DROP TRIGGER fail_event;")
            .unwrap();
        db.append_events_consuming("drive", &mut [event()], &receipts)
            .unwrap();
        assert!(
            db.records("fileprovider-upload-receipts")
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_events"),
            1
        );
    }

    #[test]
    fn independent_writers_allocate_unique_ordered_sequences() {
        let temp = tempfile::tempdir().unwrap();
        StateDb::at(temp.path()).unwrap();
        let handles = (0..4)
            .map(|_| {
                let path = temp.path().to_owned();
                std::thread::spawn(move || {
                    let mut db = StateDb::at(&path).unwrap();
                    for _ in 0..25 {
                        db.append_events("drive", &mut [event()]).unwrap();
                    }
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            handle.join().unwrap();
        }
        let mut db = StateDb::at(temp.path()).unwrap();
        assert_eq!(
            number(
                &mut db,
                "SELECT COUNT(DISTINCT sequence) AS value FROM fp_events"
            ),
            100
        );
        assert_eq!(
            number(
                &mut db,
                "SELECT latest-(SELECT MAX(sequence) FROM fp_events) AS value FROM fp_event_heads"
            ),
            0
        );
    }

    #[test]
    fn pruning_commits_explicit_anchor_floor() {
        let temp = tempfile::tempdir().unwrap();
        let mut db = StateDb::at(temp.path()).unwrap();
        db.append_events("drive", &mut []).unwrap();
        db.connection.batch_execute("WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<100002) INSERT INTO fp_events SELECT 'drive',n,'{}' FROM seq;").unwrap();
        db.append_events("drive", &mut [event()]).unwrap();
        assert_eq!(
            number(&mut db, "SELECT COUNT(*) AS value FROM fp_events"),
            EVENT_RETENTION
        );
        assert_eq!(
            number(&mut db, "SELECT floor AS value FROM fp_event_heads"),
            3
        );
    }

    /// Optional fixture for the cross-language integration script; never opens
    /// the user's state directory.
    #[test]
    fn export_swift_fixture() {
        let Ok(root) = std::env::var("CLOUDREVE_FP_TEST_FIXTURE") else {
            return;
        };
        let mut db = StateDb::at(Path::new(&root)).unwrap();
        db.append_events("interop", &mut [event()]).unwrap();
        db.put("interop", "rust", "Unicode: 你好; 'quotes'")
            .unwrap();
    }
}
