#!/bin/bash
# Embeds CloudreveFileProvider.appex into a built Cloudreve.app bundle:
#   1. builds the appex (scripts/build-extension.sh)
#   2. copies it into Contents/PlugIns
#   3. re-signs the app bundle (ad-hoc by default)
#   4. refreshes Launch Services + pluginkit registration
#
# Usage: embed-into-app.sh [path/to/Cloudreve.app]
#   default: target/release/bundle/macos/Cloudreve.app
#
# Env overrides:
#   FP_SIGN_IDENTITY  codesign identity ("-" = ad-hoc, default)
#   FP_BUILD_NUMBER   shared app/extension CFBundleVersion (default: 4)
#   FP_SHORT_VERSION  shared release version (default: 0.2.0)
#   FP_REGISTER_EXTENSION  set to 0 when packaging without local registration
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/target/release/bundle/macos/Cloudreve.app}"
IDENTITY="${FP_SIGN_IDENTITY:--}"
BUILD_NUMBER="${FP_BUILD_NUMBER:-4}"
SHORT_VERSION="${FP_SHORT_VERSION:-0.2.0}"
REGISTER_EXTENSION="${FP_REGISTER_EXTENSION:-1}"

if [[ ! -d "$APP" ]]; then
    echo "error: app bundle not found: $APP" >&2
    exit 1
fi

"$ROOT/macos/scripts/build-extension.sh"

echo "==> Embedding into $APP"
mkdir -p "$APP/Contents/PlugIns"
rm -rf "$APP/Contents/PlugIns/CloudreveFileProvider.appex"
cp -R "$ROOT/macos/build/CloudreveFileProvider.appex" "$APP/Contents/PlugIns/"

# Export the badge UTI from the host app so Launch Services can resolve it.
# The extension keeps its own copy for standalone builds.
BADGE_RESOURCE="$APP/Contents/PlugIns/CloudreveFileProvider.appex/Contents/Resources/KeepDownloaded.icns"
if [[ ! -f "$BADGE_RESOURCE" ]]; then
    echo "error: Keep Downloaded badge resource was not built" >&2
    exit 1
fi
cp "$BADGE_RESOURCE" "$APP/Contents/Resources/KeepDownloaded.icns"

BADGE_UTI="cloudreve.desktop.dev.fileprovider.decoration.keep-downloaded-v2"
if /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    if ! /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations" \
        "$APP/Contents/Info.plist" | grep -Fq "$BADGE_UTI"; then
        echo "error: app Info.plist already has UTI declarations; cannot add $BADGE_UTI safely" >&2
        exit 1
    fi
else
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations array" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0 dict" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeIdentifier string $BADGE_UTI" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeDescription string Cloudreve Keep Downloaded badge" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo array" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:0 string com.apple.icon-decoration.badge" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeIconFile string KeepDownloaded.icns" \
        "$APP/Contents/Info.plist"
fi

echo "==> Setting app and extension version to $SHORT_VERSION ($BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP/Contents/Info.plist"

echo "==> Re-signing app bundle (identity: $IDENTITY)"
# The appex keeps its own entitlements-bearing signature; re-sign the outer
# app so the bundle seal covers the new PlugIns content.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

if [[ "$REGISTER_EXTENSION" != "0" ]]; then
    echo "==> Refreshing Launch Services + pluginkit"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"
    pluginkit -r "$APP/Contents/PlugIns/CloudreveFileProvider.appex" 2>/dev/null || true
    pluginkit -a "$APP/Contents/PlugIns/CloudreveFileProvider.appex"
fi

echo "==> Done"
if [[ "$REGISTER_EXTENSION" != "0" ]]; then
    pluginkit -m -i cloudreve.desktop.dev.fileprovider
fi
