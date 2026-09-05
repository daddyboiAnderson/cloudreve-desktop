use objc2_app_kit::{NSWorkspace, NSWorkspaceIconCreationOptions};
use objc2_foundation::NSString;
use serde::Deserialize;
use tauri::AppHandle;

#[derive(Deserialize)]
struct Request {
    drive_id: String,
    item_identifier: String,
}

/// Remove legacy custom icons that have our ownership marker.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let Some(home) = dirs::home_dir() else { return };
        let directory = home.join(".cloudreve/fileprovider-activity/folder-icons");
        loop {
            if let Ok(entries) = std::fs::read_dir(&directory) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|s| s.to_str()) != Some("json") {
                        continue;
                    }
                    let Ok(data) = std::fs::read(&path) else {
                        continue;
                    };
                    let Ok(request) = serde_json::from_slice::<Request>(&data) else {
                        continue;
                    };
                    let marker = path.with_extension("applied");
                    if !marker.exists() {
                        continue;
                    }
                    let Some(state) = crate::APP_STATE.get() else {
                        continue;
                    };
                    let Some(drive) = state.drive_manager.get_drive(&request.drive_id).await else {
                        continue;
                    };
                    let config = drive.get_config().await;
                    let domain = cloudreve_sync::fileprovider::domain_identifier(&request.drive_id);
                    let Some(local) = cloudreve_sync::fileprovider::user_visible_item_url(
                        &domain,
                        &config.name,
                        &request.item_identifier,
                    )
                    .await
                    else {
                        continue;
                    };
                    if !std::path::Path::new(&local).is_dir() {
                        continue;
                    }
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    if app
                        .run_on_main_thread(move || {
                            let ok = NSWorkspace::sharedWorkspace().setIcon_forFile_options(
                                None,
                                &NSString::from_str(&local),
                                NSWorkspaceIconCreationOptions::empty(),
                            );
                            let _ = tx.send(ok);
                        })
                        .is_ok()
                        && rx.await.unwrap_or(false)
                    {
                        let _ = std::fs::remove_file(&marker);
                        let _ = std::fs::remove_file(&path);
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        }
    });
}
