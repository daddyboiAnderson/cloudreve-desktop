#!/bin/bash
# Builds TestHost.app: a minimal .app embedding CloudreveFileProvider.appex,
# used to register the file provider domain without building the Tauri app.
# Registers the app with Launch Services so pluginkit/Finder can find it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT/macos/build"
APP="$BUILD_DIR/TestHost.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Ensure the extension is built first
"$ROOT/macos/scripts/build-extension.sh"

echo "==> Compiling TestHost"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns" "$APP/Contents/Resources"
swiftc -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -sdk "$SDK" \
    -framework Foundation -framework FileProvider \
    -o "$APP/Contents/MacOS/TestHost" \
    "$ROOT/macos/testhost/main.swift"
cp "$ROOT/macos/testhost/Info.plist" "$APP/Contents/Info.plist"

echo "==> Embedding extension"
cp -R "$BUILD_DIR/CloudreveFileProvider.appex" "$APP/Contents/PlugIns/"
cp "$BUILD_DIR/CloudreveFileProvider.appex/Contents/Resources/KeepDownloaded.icns" \
    "$APP/Contents/Resources/KeepDownloaded.icns"
cp "$BUILD_DIR/CloudreveFileProvider.appex/Contents/Resources/Shared.icns" \
    "$APP/Contents/Resources/Shared.icns"

echo "==> Signing app bundle"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Registering with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"

echo "==> Done: $APP"
echo
echo "Next steps:"
echo "  $APP/Contents/MacOS/TestHost register"
echo "  pluginkit -m -p com.apple.fileprovider-nonui | grep -i cloudreve"
