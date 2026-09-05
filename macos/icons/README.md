# macOS app icon

`Cloudreve.icon` is the original Icon Composer document, including its dark appearance. Edit it in Icon Composer.

The macOS embed script compiles it with Xcode 26 or later and installs `Assets.car` and a legacy `Cloudreve.icns` into the app before signing. macOS uses the compiled appearance variants; older systems use the ICNS fallback. Windows and the monochrome menu-bar icon use their existing assets.

Set `DEVELOPER_DIR` if Xcode is installed somewhere other than `/Applications/Xcode.app`. The build stops if the icon compiler fails, so a package cannot silently ship the old icon.
