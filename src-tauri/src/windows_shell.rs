use std::path::PathBuf;

/// Reveal an item with the native Windows Shell on a fresh STA thread.
///
/// Webview/Tokio workers may already belong to an MTA. Creating a dedicated
/// thread avoids `RPC_E_CHANGED_MODE`, and the oneshot keeps the async caller
/// from blocking while Explorer handles the request.
pub async fn reveal_item(path: impl Into<PathBuf>) -> Result<(), String> {
    let path = path.into();
    let open_directory = path.is_dir();
    tracing::info!(target: "windows_shell", path = %path.display(), open_directory, "Opening item in File Explorer");
    let (sender, receiver) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("cloudreve-explorer-reveal".into())
        .spawn(move || {
            let result = if open_directory {
                open_directory_with_shell(path)
            } else {
                select_file_in_explorer(path)
            };
            let _ = sender.send(result);
        })
        .map_err(|error| format!("Could not start File Explorer integration: {error}"))?;

    receiver
        .await
        .map_err(|_| "File Explorer integration unexpectedly stopped".to_string())?
        .map_err(|error| format!("Could not show this item in File Explorer: {error}"))
}

fn open_directory_with_shell(path: PathBuf) -> windows::core::Result<()> {
    use windows::{
        core::{w, HSTRING},
        Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL},
    };

    let path = HSTRING::from(path.as_os_str());
    let result = unsafe { ShellExecuteW(None, w!("open"), &path, None, None, SW_SHOWNORMAL) };
    if result.0 as isize > 32 {
        Ok(())
    } else {
        Err(windows::core::Error::from_win32())
    }
}

fn select_file_in_explorer(path: PathBuf) -> windows::core::Result<()> {
    use std::os::windows::process::CommandExt;

    let mut command = std::process::Command::new("explorer.exe");
    // Explorer requires /select and the filename in one raw argument. Paths
    // cannot contain a double quote, so quoting the absolute path is safe.
    command.raw_arg(format!("/select,\"{}\"", path.display()));
    command.spawn().map(|_| ()).map_err(|error| {
        windows::core::Error::new(
            windows::Win32::Foundation::E_FAIL,
            format!("Could not open File Explorer: {error}"),
        )
    })
}
