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
#   FP_BUILD_NUMBER   shared app/extension CFBundleVersion (default: 5.1)
#   FP_SHORT_VERSION  shared release version (default: 0.2.0)
#   FP_REGISTER_EXTENSION  set to 0 when packaging without local registration
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/target/release/bundle/macos/Cloudreve.app}"
IDENTITY="${FP_SIGN_IDENTITY:--}"
BUILD_NUMBER="${FP_BUILD_NUMBER:-5.1}"
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

for resource in KeepDownloaded.icns Shared.icns UploadConflict.icns; do
    badge_resource="$APP/Contents/PlugIns/CloudreveFileProvider.appex/Contents/Resources/$resource"
    if [[ ! -f "$badge_resource" ]]; then
        echo "error: $resource was not built" >&2
        exit 1
    fi
    cp "$badge_resource" "$APP/Contents/Resources/$resource"
done

ensure_exported_uti() {
    local uti="$1"
    local description="$2"
    local icon="$3"
    local index=0

    if ! /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations array" \
            "$APP/Contents/Info.plist"
    fi
    if /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations" \
        "$APP/Contents/Info.plist" | grep -Fq "$uti"; then
        return
    fi
    while /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations:$index" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; do
        index=$((index + 1))
    done
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index dict" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index:UTTypeIdentifier string $uti" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index:UTTypeDescription string $description" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index:UTTypeConformsTo array" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index:UTTypeConformsTo:0 string com.apple.icon-decoration.badge" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:$index:UTTypeIconFile string $icon" \
        "$APP/Contents/Info.plist"
}

ensure_exported_uti \
    "cloudreve.desktop.dev.fileprovider.decoration.keep-downloaded-v2" \
    "Cloudreve Keep Downloaded badge" KeepDownloaded.icns
ensure_exported_uti \
    "cloudreve.desktop.dev.fileprovider.decoration.shared-v1" \
    "Cloudreve Shared badge" Shared.icns
ensure_exported_uti \
    "cloudreve.desktop.dev.fileprovider.decoration.upload-conflict-v1" \
    "Cloudreve Upload Conflict badge" UploadConflict.icns

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
