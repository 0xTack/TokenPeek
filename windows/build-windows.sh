#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.3"
APP_NAME="DeepSeekDashboard"
OUT="release"
DIST="dist"
ZIP="${DIST}/DeepSeekDashboard-${VERSION}-Windows-x64.zip"
SQLITE_ZIP_URL="https://sqlite.org/2026/sqlite-tools-win-x64-3540100.zip"

if ! command -v node >/dev/null 2>&1; then
  echo "需要 Node.js（建议 20 或更高）" >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  echo "安装依赖..."
  npm install
fi

if [ ! -f vendor/sqlite3.exe ]; then
  echo "下载 Windows sqlite3.exe..."
  mkdir -p vendor
  TMP="$(mktemp -d)"
  curl -L --fail --max-time 180 -o "${TMP}/sqlite.zip" "${SQLITE_ZIP_URL}"
  unzip -q "${TMP}/sqlite.zip" -d "${TMP}/sqlite"
  find "${TMP}/sqlite" -name "sqlite3.exe" -exec cp {} vendor/ \;
  rm -rf "${TMP}"
fi

if [ -f ../donation-qr.png ]; then
  cp ../donation-qr.png assets/donation-qr.png
else
  rm -f assets/donation-qr.png
fi

echo "生成图标..."
node scripts/gen-icons.js

echo "打包 Windows x64..."
rm -rf "${OUT}" "${ZIP}"
mkdir -p "${DIST}"
npx @electron/packager . "${APP_NAME}" \
  --platform=win32 \
  --arch=x64 \
  --out="${OUT}" \
  --overwrite \
  --asar \
  --icon=assets/icon.ico \
  --app-version="${VERSION}.0" \
  --build-version="${VERSION}.0" \
  --app-copyright="DeepSeek 仪表盘" \
  --win32metadata.CompanyName="DeepSeek 仪表盘" \
  --win32metadata.FileDescription="DeepSeek 时段与用量统计" \
  --win32metadata.ProductName="DeepSeek 仪表盘" \
  --extra-resource=vendor/sqlite3.exe \
  --extra-resource=assets/tray-idle.png \
  --extra-resource=assets/tray-peak.png \
  --ignore="^/dist" \
  --ignore="^/release" \
  --ignore="^/node_modules" \
  --ignore="^/vendor" \
  --ignore="^/scripts" \
  --ignore="^/\.icon-tmp" \
  --ignore="^/build-windows\.sh"

APP_DIR="${OUT}/${APP_NAME}-win32-x64"
if [ ! -f "${APP_DIR}/resources/sqlite3.exe" ]; then
  echo "打包失败：resources/sqlite3.exe 不存在" >&2
  exit 1
fi

cp README-Windows.md "${APP_DIR}/README-Windows.md"

echo "压缩..."
ditto -c -k --norsrc --noextattr --noacl --keepParent "${APP_DIR}" "${ZIP}"

echo "完成："
du -sh "${APP_DIR}"
ls -lh "${ZIP}"
echo "解压后运行 ${APP_NAME}.exe 即可。"
