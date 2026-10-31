#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DeepSeek仪表盘.app"
DEST="$HOME/Applications/DeepSeek仪表盘.app"
OLD="$HOME/Applications/DeepSeek计费.app"
ARCH="$(uname -m)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译主程序..."
swiftc \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx14.0" \
  main.swift \
  -o "$APP/Contents/MacOS/DeepSeekCost"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -f donation-qr.png ]; then
  cp donation-qr.png "$APP/Contents/Resources/donation-qr.png"
fi

echo "签名..."
codesign --force --deep --sign - "$APP"

echo "安装到 ~/Applications ..."
mkdir -p "$HOME/Applications"

pkill -f "DeepSeek计费.app/Contents/MacOS/DeepSeekCost" 2>/dev/null || true
pkill -f "DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OLD" 2>/dev/null || true
rm -rf "$OLD" "$DEST"
cp -R "$APP" "$DEST"

echo "注册..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

open "$DEST" --args --background
echo "完成：$DEST"
