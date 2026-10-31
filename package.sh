#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.1"
NAME="DeepSeek仪表盘"
TAG="AppleSilicon"
APP="build/${NAME}.app"
DIST="dist"
STAGE="build/${NAME}-${VERSION}-${TAG}"
DMG="${DIST}/${NAME}-${VERSION}-${TAG}.dmg"
ZIP="${DIST}/${NAME}-${VERSION}-${TAG}.zip"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

echo "编译 Apple Silicon（arm64 / macOS 14+）..."
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  main.swift \
  -o "$APP/Contents/MacOS/DeepSeekCost"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -f donation-qr.png ]; then
  cp donation-qr.png "$APP/Contents/Resources/donation-qr.png"
fi

echo "签名（ad-hoc）..."
codesign --force --deep --sign - "$APP"

echo "准备安装包内容..."
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "../分享说明.txt" "$STAGE/安装说明.txt"

echo "生成 DMG..."
rm -f "$DMG"
hdiutil create \
  -volname "DeepSeek 仪表盘" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "生成 ZIP..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"

echo "复制到桌面..."
cp "$DMG" "$HOME/Desktop/"
cp "$ZIP" "$HOME/Desktop/"

echo "完成："
file "$APP/Contents/MacOS/DeepSeekCost"
otool -l "$APP/Contents/MacOS/DeepSeekCost" | awk '/LC_BUILD_VERSION/{getline; print "  minos:", $2}'
ls -lh "$DMG" "$ZIP"
