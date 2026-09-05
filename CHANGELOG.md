# Changelog

## Cloudreve Desktop 0.2.0 for macOS — Build 5

Build 5 is a major update to Finder integration, conflict safety, sharing, and the menu-bar experience.

### Safer conflict handling

Cloudreve now pauses an upload when the online file changed, is locked by another editor, or cannot be verified safely. A dedicated conflict window explains what happened and offers clear actions.

For example, if a document changes online while you are editing it locally, you can save your edit as a separate copy or discard it and restore the current Cloudreve version. A safe retry is offered when the online file is unchanged and no longer locked.

Conflicts and File Provider errors also appear in the menu-bar popup, where you can open the affected item and resolve it without searching through Finder.

### A more useful menu-bar popup

The popup now has three focused views:

- **Recent** shows uploads, downloads, grouped activity, and items that need attention.
- **Keep Downloaded** lists the files and folders selected for offline access. You can reveal an item in Finder or remove Keep Downloaded while leaving its current local copy in place.
- **Shared by me** lists links you created, including links for items inside folders shared with you. You can copy a link, open the item in Finder, or manage it in Share Options.

The views can be filtered by drive and searched by readable file or folder names. The popup also has clearer controls, rounded navigation, and spacing below the macOS menu bar.

### Shared folders and files

Folders shared with you can be added to My Files as shortcuts and explored directly in Finder. Files inside them follow the permissions granted by the owner, including creating new share links when allowed.

Finder distinguishes **Shared with me** from **Shared by me**. For example, a received folder remains Shared with me, while a file inside it shows Shared by me after you create your own link for that file. Native folder artwork and Keep Downloaded status remain compatible with these labels.

The Share Options window has also been refined with clearer layout, aligned window controls, better filename truncation, and access to existing links that belong to you.

### Drive sign-in

After browser authorization, choosing Open in Cloudreve now brings the Add Drive window to the active macOS Space and focuses it automatically.

### Bug fixes

- Fixed Keep Downloaded items that displayed a badge without remaining downloaded.
- Fixed unnecessary reimport and upload-conflict loops for unchanged files.
- Fixed restoring individual shared-file shortcuts from Cloudreve.
- Fixed shared-item labels in Finder list and icon views.
- Fixed owned links missing from received folders and individual file shortcuts.
- Fixed Cloudreve API responses with empty sorting options breaking the shared-items view.
- Fixed encoded spaces such as `%20` appearing in menu-bar paths and search.
- Improved stale delete completion, metadata refreshes, and sync recovery after reconnecting.
