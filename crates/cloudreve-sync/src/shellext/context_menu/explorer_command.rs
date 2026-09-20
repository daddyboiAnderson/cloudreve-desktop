use super::{SubCommands, CLSID_EXPLORER_COMMAND};
use crate::{
    drive::manager::DriveManager,
    utils::app::{get_app_root, AppRoot},
};
use std::sync::Arc;
use windows::{
    core::*,
    Win32::{Foundation::*, System::Com::*, UI::Shell::*},
};

#[implement(IExplorerCommand)]
pub struct CrExplorerCommandHandler {
    drive_manager: Arc<DriveManager>,
    app_root: AppRoot,

    #[allow(dead_code)]
    site: std::sync::Mutex<Option<IUnknown>>,
}

impl CrExplorerCommandHandler {
    pub fn new(drive_manager: Arc<DriveManager>) -> Self {
        Self {
            drive_manager: drive_manager.clone(),
            app_root: get_app_root(),
            site: std::sync::Mutex::new(None),
        }
    }

    fn selection_is_in_cloudreve(&self, items: Option<&IShellItemArray>) -> bool {
        let Some(items) = items else {
            return false;
        };
        unsafe {
            let Ok(count) = items.GetCount() else {
                return false;
            };
            if count == 0 {
                return false;
            }
            for index in 0..count {
                let Ok(item) = items.GetItemAt(index) else {
                    return false;
                };
                let Ok(display_name) = item.GetDisplayName(SIGDN_FILESYSPATH) else {
                    return false;
                };
                let Ok(path) = display_name.to_string() else {
                    return false;
                };
                if !matches!(
                    self.drive_manager.get_inventory().query_by_path(&path),
                    Ok(Some(_))
                ) {
                    return false;
                }
            }
        }
        true
    }
}

impl IExplorerCommand_Impl for CrExplorerCommandHandler_Impl {
    fn GetTitle(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        let hstring = HSTRING::from("Cloudreve");
        unsafe { SHStrDupW(&hstring) }
    }

    fn GetIcon(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        let icon_path = format!("{}\\cloudreve.ico", self.app_root.image_path_general());
        let hstring = HSTRING::from(icon_path);
        unsafe { SHStrDupW(&hstring) }
    }

    fn GetToolTip(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        Err(Error::from(E_NOTIMPL))
    }

    fn GetCanonicalName(&self) -> Result<GUID> {
        Ok(CLSID_EXPLORER_COMMAND)
    }

    fn GetState(&self, items: Option<&IShellItemArray>, _oktobeslow: BOOL) -> Result<u32> {
        Ok(if self.selection_is_in_cloudreve(items) {
            ECS_ENABLED.0 as u32
        } else {
            ECS_HIDDEN.0 as u32
        })
    }

    fn Invoke(
        &self,
        _selection: Option<&IShellItemArray>,
        _bindctx: Option<&IBindCtx>,
    ) -> Result<()> {
        tracing::debug!(target: "shellext::context_menu", "View online context menu command invoked");
        Ok(())
    }

    fn GetFlags(&self) -> Result<u32> {
        Ok((ECF_DEFAULT.0 | ECF_HASSUBCOMMANDS.0 | ECF_ISDROPDOWN.0) as u32)
    }

    fn EnumSubCommands(&self) -> Result<IEnumExplorerCommand> {
        tracing::trace!(target: "shellext::context_menu", "EnumSubCommands called");
        Ok(SubCommands::new(self.drive_manager.clone(), self.app_root.clone()).into())
    }
}
