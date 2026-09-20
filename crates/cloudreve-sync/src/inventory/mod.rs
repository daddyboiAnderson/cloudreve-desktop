mod db;
mod models;
pub(crate) mod schema;

#[cfg(target_os = "macos")]
pub use db::{FileProviderRemoteItem, NewFileProviderRemoteItem};
pub use db::{InventoryDb, RecentTasks};
pub use models::{
    ConflictState, DriveProps, DrivePropsUpdate, FileMetadata, MetadataEntry, NewTaskRecord,
    TaskRecord, TaskStatus, TaskUpdate,
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
