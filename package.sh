#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 每次打包自动把次版本号 +1，例如 1.1 -> 1.2；同步写入 Info.plist。
# 只想重打同一版时：SKIP_VERSION_BUMP=1 ./package.sh
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [ "${SKIP_VERSION_BUMP:-0}" = "1" ]; then
  VERSION="$CURRENT_VERSION"
else
  MAJOR="${CURRENT_VERSION%%.*}"
  MINOR="${CURRENT_VERSION#*.}"
  case "$MINOR" in
    ''|*[!0-9]*) MINOR=0 ;;
  esac
  VERSION="${MAJOR}.$((MINOR + 1))"
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist
fi

NAME="TokenPeek"
TAG="AppleSilicon"
APP="build/${NAME}.app"
DIST="dist"
STAGE="build/${NAME}-${VERSION}-${TAG}"
DMG="${DIST}/${NAME}-${VERSION}-${TAG}.dmg"
ZIP="${DIST}/${NAME}-${VERSION}-${TAG}.zip"

# macOS 27.2 SDK 把 SwiftUI 的 @State 改成了宏，但命令行工具没带
# SwiftUIMacros 插件；有 26.5 SDK 时优先用它，保证能直接编译。
SDK_ARGS=()
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK_ARGS=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

echo "编译 Apple Silicon（arm64 / macOS 14+），版本 ${VERSION}..."
swiftc \
  "${SDK_ARGS[@]}" \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
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
  -volname "TokenPeek" \
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
