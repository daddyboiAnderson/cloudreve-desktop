//! Updates are verified by Tauri's pinned public key, never by a downloaded key.
use serde::Serialize;
use tauri::State;

#[cfg(any(target_os = "macos", test))]
fn trusted_release_url(url: &tauri::Url) -> bool {
    url.scheme() == "https"
        && url.host_str() == Some("github.com")
        && url.username().is_empty()
        && url.password().is_none()
        && url.port_or_known_default() == Some(443)
        && url
            .path()
            .starts_with("/daddyboiAnderson/cloudreve-desktop/releases/download/")
}

#[derive(Default)]
pub struct UpdateState {
    #[cfg(target_os = "macos")]
    pending: tokio::sync::Mutex<Option<tauri_plugin_updater::Update>>,
}

#[derive(Serialize)]
pub struct UpdateInfo {
    version: Option<String>,
    notes: Option<String>,
    managed: bool,
}

#[tauri::command]
pub async fn check_app_update(
    app: tauri::AppHandle,
    state: State<'_, UpdateState>,
) -> Result<UpdateInfo, String> {
    // Windows Explorer integration depends on the existing MSIX identity.
    // Never replace that installation with an unrelated NSIS/MSI package.
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, state);
        return Ok(UpdateInfo {
            version: None,
            notes: None,
            managed: true,
        });
    }
    #[cfg(target_os = "macos")]
    {
        use tauri_plugin_updater::UpdaterExt;
        let mut pending = state
            .pending
            .try_lock()
            .map_err(|_| "An update operation is already running")?;
        *pending = None;
        let update = app
            .updater_builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| e.to_string())?
            .check()
            .await
            .map_err(|e| e.to_string())?;
        if let Some(update) = &update {
            let url = &update.download_url;
            if !trusted_release_url(url) {
                return Err("The update is not hosted by the configured release repository".into());
            }
        }
        let info = UpdateInfo {
            version: update.as_ref().map(|u| u.version.clone()),
            notes: update.as_ref().and_then(|u| u.body.clone()),
            managed: false,
        };
        *pending = update;
        Ok(info)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_downloads_are_bound_to_our_https_release_repository() {
        assert!(trusted_release_url(&tauri::Url::parse("https://github.com/daddyboiAnderson/cloudreve-desktop/releases/download/v0.2.1/app.tar.gz").unwrap()));
        for url in [
            "http://github.com/daddyboiAnderson/cloudreve-desktop/releases/download/v1/app.tar.gz",
            "https://github.com.evil.invalid/daddyboiAnderson/cloudreve-desktop/releases/download/v1/app.tar.gz",
            "https://github.com/other/repo/releases/download/v1/app.tar.gz",
            "https://github.com/daddyboiAnderson/cloudreve-desktop/releases/download/../../../other",
            "https://user:secret@github.com/daddyboiAnderson/cloudreve-desktop/releases/download/v1/app.tar.gz",
        ] { assert!(!trusted_release_url(&tauri::Url::parse(url).unwrap()), "{url}"); }
    }
}

#[tauri::command]
pub async fn install_app_update(
    app: tauri::AppHandle,
    state: State<'_, UpdateState>,
) -> Result<(), String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, state);
        Err("Use your platform's package installer to update Cloudreve".into())
    }
    #[cfg(target_os = "macos")]
    {
        let mut pending = state
            .pending
            .try_lock()
            .map_err(|_| "An update operation is already running")?;
        let update = pending
            .as_ref()
            .ok_or("Check for updates before installing")?;
        // The same checked release is installed; a second check cannot silently
        // substitute a different version after the user approves it.
        let bytes = update
            .download(|_, _| {}, || {})
            .await
            .map_err(|e| e.to_string())?;
        update.install(bytes).map_err(|e| e.to_string())?;
        *pending = None;
        crate::shutdown().await;
        app.restart();
    }
}
