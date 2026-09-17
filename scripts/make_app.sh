#!/bin/bash
# 编译 OpenAltTab 并组装成可运行的 .app 包
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenAltTab"
VERSION="1.3.0"
APP="$APP_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# 应用图标（已生成则复用）
if [ ! -f ".build/icon/AppIcon.icns" ]; then
  ./scripts/make_icon.sh
fi
cp ".build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenAltTab</string>
    <key>CFBundleDisplayName</key><string>OpenAltTab</string>
    <key>CFBundleIdentifier</key><string>com.openalttab.macos</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>OpenAltTab</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.openalttab.macos.cli</string>
            <key>CFBundleURLSchemes</key>
            <array><string>openalttab</string></array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP" 2>/dev/null
codesign --verify "$APP" && echo "✅ 构建完成: $(pwd)/$APP"
