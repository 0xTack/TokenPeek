#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TokenPeek.app"
DEST="/Applications/TokenPeek.app"
OLD="$HOME/Applications/DeepSeek计费.app"
OLD_APP="/Applications/DeepSeek仪表盘.app"
ARCH="$(uname -m)"

# macOS 27.2 SDK 把 SwiftUI 的 @State 改成了宏，但命令行工具没带
# SwiftUIMacros 插件；有 26.5 SDK 时优先用它，保证能直接编译。
SDK_ARGS=()
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK_ARGS=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译主程序..."
swiftc \
  "${SDK_ARGS[@]}" \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx14.0" \
  main.swift \
  -o "$APP/Contents/MacOS/DeepSeekCost"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for icon in AppIcon-retro.png AppIcon-watercolor.png AppIcon-classic.icns; do
  [ -f "$icon" ] && cp "$icon" "$APP/Contents/Resources/$icon"
done
if [ -d zh-Hans.lproj ]; then
  cp -R zh-Hans.lproj "$APP/Contents/Resources/"
fi
if [ -f donation-qr.png ]; then
  cp donation-qr.png "$APP/Contents/Resources/donation-qr.png"
fi

echo "签名..."
codesign --force --deep --sign - "$APP"

echo "安装到 ~/Applications ..."
mkdir -p "$HOME/Applications"

pkill -f "DeepSeek计费.app/Contents/MacOS/DeepSeekCost" 2>/dev/null || true
pkill -f "DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost" 2>/dev/null || true
pkill -f "TokenPeek.app/Contents/MacOS/DeepSeekCost" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OLD" 2>/dev/null || true
rm -rf "$OLD" "$OLD_APP" "$DEST"
cp -R "$APP" "$DEST"

echo "注册..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

open "$DEST" --args --background
echo "完成：$DEST"
