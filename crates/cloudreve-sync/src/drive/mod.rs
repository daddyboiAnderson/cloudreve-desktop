#[cfg(windows)]
pub mod callback;
pub mod commands;
pub mod event_blocker;
#[cfg(target_os = "macos")]
pub(crate) mod fileprovider_audit;
pub mod ignore;
pub mod manager;
pub mod mounts;
#[cfg(windows)]
pub mod placeholder;
#[cfg(not(windows))]
#[path = "placeholder_non_windows.rs"]
pub mod placeholder;
pub mod remote_events;
pub mod share_shortcuts;
pub mod sync;
pub mod utils;
