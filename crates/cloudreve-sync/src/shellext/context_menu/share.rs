use crate::{
    drive::{commands::ManagerCommand, manager::DriveManager},
    utils::app::AppRoot,
};
use rust_i18n::t;
use std::{path::PathBuf, sync::Arc};
use windows::{
    Win32::{Foundation::*, System::Com::*, UI::Shell::*},
    core::*,
};

/// Opens Cloudreve's native Share Options window for one Explorer item.
#[implement(IExplorerCommand)]
pub struct ShareCommandHandler {
    drive_manager: Arc<DriveManager>,
    app_root: AppRoot,
}

impl ShareCommandHandler {
    pub fn new(drive_manager: Arc<DriveManager>, app_root: AppRoot) -> Self {
        Self {
            drive_manager,
            app_root,
        }
    }

    fn selected_path(items: Option<&IShellItemArray>) -> Option<PathBuf> {
        let items = items?;
        unsafe {
            if items.GetCount().ok()? != 1 {
                return None;
            }
            let item = items.GetItemAt(0).ok()?;
            let display_name = item.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
            Some(PathBuf::from(display_name.to_string().ok()?))
        }
    }
}

impl IExplorerCommand_Impl for ShareCommandHandler_Impl {
    fn GetTitle(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        let title = t!("shareItem");
        unsafe { SHStrDupW(&HSTRING::from(title.as_ref())) }
    }

    fn GetIcon(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        let icon_path = format!("{}\\people.ico", self.app_root.image_path());
        unsafe { SHStrDupW(&HSTRING::from(icon_path)) }
    }

    fn GetToolTip(&self, _items: Option<&IShellItemArray>) -> Result<PWSTR> {
        Err(Error::from(E_NOTIMPL))
    }

    fn GetCanonicalName(&self) -> Result<GUID> {
        Ok(GUID::from_u128(0x7af3d449_3752_4f19_9444_97b8f03829b1))
    }

    fn GetState(&self, items: Option<&IShellItemArray>, _oktobeslow: BOOL) -> Result<u32> {
        let Some(path) = ShareCommandHandler::selected_path(items) else {
            return Ok(ECS_HIDDEN.0 as u32);
        };
        match self
            .drive_manager
            .get_inventory()
            .query_by_path(path.to_string_lossy().as_ref())
        {
            Ok(Some(_)) => Ok(ECS_ENABLED.0 as u32),
            _ => Ok(ECS_HIDDEN.0 as u32),
        }
    }

    fn Invoke(
        &self,
        selection: Option<&IShellItemArray>,
        _bindctx: Option<&IBindCtx>,
    ) -> Result<()> {
        let Some(path) = ShareCommandHandler::selected_path(selection) else {
            return Ok(());
        };
        if let Err(error) = self
            .drive_manager
            .get_command_sender()
            .send(ManagerCommand::Share { path: path.clone() })
        {
            tracing::error!(target: "shellext::context_menu", path = %path.display(), error = %error, "Failed to send Share command");
        }
        Ok(())
    }

    fn GetFlags(&self) -> Result<u32> {
        Ok(ECF_DEFAULT.0 as u32)
    }

    fn EnumSubCommands(&self) -> Result<IEnumExplorerCommand> {
        Err(Error::from(E_NOTIMPL))
    }
}
