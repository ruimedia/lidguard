#!/bin/sh
# 构建 LidGuard.app —— 编译 + 打包 + 临时签名
# 用法： ./build-app.sh

set -eu
cd "$(dirname "$0")"

APP=".build/LidGuard.app"

echo "==> 编译"
swift build -c release 2>&1 | grep -E "error:" && { echo "❌ 编译失败"; exit 1; } || true
[ -f .build/release/LidGuard ] || { echo "❌ 未生成二进制"; exit 1; }

echo "==> 打包"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LidGuard "$APP/Contents/MacOS/LidGuard"

# 图标资源：应用图标 + 菜单栏模板图（由 docs/assets 生成）
ASSETS="$(dirname "$0")/../docs/assets"
for f in LidGuard.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    if [ -f "$ASSETS/$f" ]; then
        cp "$ASSETS/$f" "$APP/Contents/Resources/$f"
    else
        echo "   ⚠️ 缺少 $f，图标不会生效"
    fi
done

# LSUIElement=true 让 App 只驻菜单栏、不显示 Dock 图标。
# 这个键一旦缺失，状态项行为会异常，务必写入。
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LidGuard</string>
    <key>CFBundleDisplayName</key><string>LidGuard 合盖不休眠</string>
    <key>CFBundleIdentifier</key><string>media.rui.lidguard</string>
    <key>CFBundleExecutable</key><string>LidGuard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>LidGuard</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> 临时签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "   已签名" || echo "   ⚠️ 签名失败"

echo "==> 校验"
plutil -lint "$APP/Contents/Info.plist" | sed 's/^/   /'
codesign -dv "$APP" 2>&1 | head -2 | sed 's/^/   /'

echo
echo "✅ 构建完成：$APP"
echo "   运行： open $APP"