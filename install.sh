#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/Applications/AIQuotaHover.app"
PLIST_HOVER="${HOME}/Library/LaunchAgents/com.local.ai-quota-hover.plist"

cd "${SCRIPT_DIR}"
echo "==> [1/3] 编译纯原生 AIQuotaHover (Release)..."
swift build -c release

echo "==> [2/3] 打包安装 ${APP_DIR}..."
killall AIQuotaHover 2>/dev/null || true
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${SCRIPT_DIR}/.build/release/AIQuotaHover" "${APP_DIR}/Contents/MacOS/AIQuotaHover"
chmod +x "${APP_DIR}/Contents/MacOS/AIQuotaHover"

cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>AIQuotaHover</string>
  <key>CFBundleExecutable</key>
  <string>AIQuotaHover</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.ai-quota-hover</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AIQuotaHover</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> [3/3] 配置开机自启并启动 AIQuotaHover.app..."
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST_HOVER}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.ai-quota-hover</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_DIR}/Contents/MacOS/AIQuotaHover</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.local.ai-quota-hover" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_HOVER}"
echo "🎉 安装并启动完成！把鼠标移到顶部电源图标旁的 AIQuotaHover 图标即可体验。"
