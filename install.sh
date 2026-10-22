#!/bin/sh
# lidguard 安装 / 卸载脚本
#
#   sudo ./install.sh              安装
#   sudo ./install.sh --uninstall  卸载并强制恢复正常休眠
#
# 安装会做三件事，全部逐条打印：
#   1. 可选：清理本机可能存在的第三方 root 守护进程残留（Adrafinil）
#   2. 把 daemon/lidguard 安装到 /usr/local/bin/lidguard
#   3. 安装并加载 LaunchDaemon（每 10 秒判定一次）
#
# 它不会做的事：不装 sudoers 规则、不改任何 agent 配置、不发网络请求、
#              不修改除 pmset disablesleep 以外的任何电源设置。

set -eu

LABEL=com.lidguard
PLIST=/Library/LaunchDaemons/$LABEL.plist
BIN=/usr/local/bin/lidguard
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行： sudo $0"
    exit 1
fi

# ---- 卸载 -----------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    echo "=============================================="
    echo " lidguard 卸载程序"
    echo "=============================================="
    echo
    echo "[1/3] 停止 LaunchDaemon..."
    launchctl bootout "system/$LABEL" 2>/dev/null || echo "  （未在运行，跳过）"
    echo "  ✅ 已停止"

    echo
    echo "[2/3] 强制恢复正常休眠..."
    pmset -a disablesleep 0 >/dev/null 2>&1 || true
    pmset sleepnow >/dev/null 2>&1 || true
    echo "  ✅ 已执行 pmset -a disablesleep 0"

    echo
    echo "[3/3] 删除文件..."
    /bin/rm -f "$PLIST" "$BIN"
    /bin/rm -f /var/run/lidguard.initialized
    _u=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")
    [ -n "$_u" ] && [ "$_u" != "root" ] && /bin/rm -rf "/Users/$_u/.lidguard"
    echo "  ✅ 已删除脚本、plist 与标记目录"

    echo
    echo "验证当前状态（应为 No）："
    ioreg -r -c IOPMrootDomain | grep SleepDisabled
    echo
    echo "卸载完成。"
    exit 0
fi

echo "=============================================="
echo " lidguard 安装程序"
echo "=============================================="

# ---- 1. 可选：清理第三方 root 守护进程残留 --------------------------------
echo
echo "[1/3] 检查第三方 root 守护进程残留..."
if pgrep -f "AdrafinilHelper" >/dev/null 2>&1; then
    echo "  发现 Adrafinil root 进程，正在停用..."
    launchctl bootout system/glass.kagerou.adrafinil.helper 2>/dev/null || true
    sleep 1
    if pgrep -f "AdrafinilHelper" >/dev/null 2>&1; then
        echo "  ⚠️  bootout 未能终止进程。"
        echo "      它是 root 进程，请到 系统设置 → 通用 → 登录项与扩展 中手动关闭。"
    else
        echo "  ✅ 已停用 Adrafinil root 进程"
    fi
else
    echo "  无 Adrafinil 进程，跳过"
fi

# ---- 2. 安装主脚本 --------------------------------------------------------
echo
echo "[2/3] 安装 lidguard 主脚本..."
DAEMON_SRC="$SRC_DIR/daemon/lidguard"
[ -f "$DAEMON_SRC" ] || DAEMON_SRC="$SRC_DIR/lidguard"
if [ ! -f "$DAEMON_SRC" ]; then
    echo "  ❌ 找不到 lidguard 脚本。"
    echo "      期望位置： $SRC_DIR/daemon/lidguard"
    exit 1
fi
/bin/mkdir -p /usr/local/bin
/bin/cp "$DAEMON_SRC" "$BIN"
/usr/sbin/chown root:wheel "$BIN"
/bin/chmod 755 "$BIN"
echo "  ✅ 已安装到 $BIN"

# ---- 3. 安装并加载 LaunchDaemon -------------------------------------------
echo
echo "[3/3] 安装 LaunchDaemon（每 10 秒检查一次电源）..."
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--daemon</string>
    </array>
    <key>StartInterval</key>
    <integer>10</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/var/log/lidguard.out.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/lidguard.err.log</string>
</dict>
</plist>
PLISTEOF
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST"
echo "  ✅ 已加载 $LABEL"

# ---- 收尾 -----------------------------------------------------------------
echo
echo "=============================================="
echo " 安装完成"
echo "=============================================="
echo
echo "  武装（接通电源时允许合盖不休眠）："
echo "      lidguard on          # 默认最长 8 小时"
echo "      lidguard on 4        # 只保 4 小时"
echo
echo "  解除：  lidguard off"
echo "  查看：  lidguard status"
echo
echo "  当前是否处于「永不睡眠」状态（No=正常）："
ioreg -r -c IOPMrootDomain | grep SleepDisabled
echo
echo "  卸载：  sudo $0 --uninstall"
echo