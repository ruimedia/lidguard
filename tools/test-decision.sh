#!/bin/sh
# LidGuard 判定逻辑的确定性测试 —— 与机器实时电源状态无关。
#
# 做法：把守护脚本里的 /usr/bin/pmset 换成桩程序，由测试自己控制
# 「是否接电」「温度是否正常」，这样同一台机器插不插电都能得到同样结果。
#
# 判定逻辑本身没有任何地方被改动，测的就是线上那份脚本。

set -u
SRC="$(cd "$(dirname "$0")" && pwd)/../daemon/lidguard"
WORK=$(mktemp -d)
STUB="$WORK/bin"

mkdir -p "$STUB"

# 桩：读 $STUB/on_ac 和 $STUB/thermal 两个开关文件
cat > "$STUB/pmset" <<'STUBEOF'
#!/bin/sh
case "$1" in
  -g)
    case "$2" in
      ps)
        if [ "$(cat "$(dirname "$0")/on_ac" 2>/dev/null)" = "1" ]; then
          echo "Now drawing from 'AC Power'"
        else
          echo "Now drawing from 'Battery Power'"
        fi ;;
      therm)
        if [ "$(cat "$(dirname "$0")/thermal" 2>/dev/null)" = "bad" ]; then
          echo "CPU_Scheduler_Limit  : 100"
          echo "CPUs_Scheduler_Limit : 100"
          echo "Thermal level: CPU_Speed_Limit is reduced"
        else
          echo "No thermal warning level has been recorded"
        fi ;;
      *)
        echo " sleep=1" ;;
    esac ;;
  -a)
    echo "STUB-CALL: pmset $*" >> "$(dirname "$0")/calls.log" ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/pmset"

# 生成被测副本：只替换 pmset 的绝对路径，其余原样
sed "s#/usr/bin/pmset#$STUB/pmset#g" "$SRC" > "$WORK/lidguard-test"
chmod +x "$WORK/lidguard-test"

BT=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/grep -o 'sec = [0-9]*' | /usr/bin/head -1 | /usr/bin/cut -d' ' -f3)
NOW=$(date +%s)

# 标记文件必须放在守护脚本真正会读的位置 —— arm_file() 由 /dev/console 的属主
# 推出 /Users/<user>/.lidguard/armed，这里必须用同一个算法，否则测试等于没测。
CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console)
ARM_DIR="/Users/$CONSOLE_USER/.lidguard"
ARM="$ARM_DIR/armed"
BACKUP="$WORK/armed.backup"

# 备份用户原有状态，测完原样还原
mkdir -p "$ARM_DIR"
[ -e "$ARM" ] && cp "$ARM" "$BACKUP"

cleanup() {
    if [ -f "$BACKUP" ]; then cp "$BACKUP" "$ARM"; else rm -f "$ARM"; fi
}
trap cleanup EXIT

set_mtime() { python3 -c "import os,sys;os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))" "$ARM" "$1"; }

pass=0; fail=0
check() {
  _label="$1"; _expect="$2"; _got="$3"
  if [ "$_expect" = "$_got" ]; then
    printf "  ✅ %-24s 期望 %s  实得 %s\n" "$_label" "$_expect" "$_got"
    pass=$((pass+1))
  else
    printf "  ❌ %-24s 期望 %s  实得 %s\n" "$_label" "$_expect" "$_got"
    fail=$((fail+1))
  fi
}
decide() { LIDGUARD_DRYRUN=1 sh "$WORK/lidguard-test" status 2>&1 | grep '判定结果' | sed 's/.*判定结果  : //; s/ .*//'; }

echo "=== LidGuard 判定逻辑测试（pmset 已打桩）==="
echo

echo "1) 接通电源"
echo 1 > "$STUB/on_ac"; echo ok > "$STUB/thermal"
echo 28800 > "$ARM"; set_mtime "$NOW"
check "正常武装" 1 "$(decide)"

echo 28800 > "$ARM"; set_mtime $((NOW - 30000))
check "超过 8 小时上限" 0 "$(decide)"

echo 28800 > "$ARM"; set_mtime $((BT - 86400))
check "跨重启残留" 0 "$(decide)"

echo 28800 > "$ARM"; set_mtime $((NOW + 9999))
check "时间戳在未来" 0 "$(decide)"

echo abc > "$ARM"; set_mtime "$NOW"
check "内容非数字（回落默认）" 1 "$(decide)"

echo 2 > "$STUB/on_ac"
echo 28800 > "$ARM"; set_mtime "$NOW"
check "已武装但未接电源" 0 "$(decide)"

echo 1 > "$STUB/on_ac"; echo bad > "$STUB/thermal"
echo 28800 > "$ARM"; set_mtime "$NOW"
check "温度告警" 0 "$(decide)"

echo ok > "$STUB/thermal"
# 注意：判定「是否武装」只看文件是否存在，内容只是时间预算。
# 所以空文件 = 已武装 + 回落默认 8 小时，这正是设计意图。
: > "$ARM"; set_mtime "$NOW"
check "空文件（武装·默认预算）" 1 "$(decide)"

echo abc > "$ARM"; set_mtime "$NOW"
check "非数字（武装·默认预算）" 1 "$(decide)"

rm -f "$ARM"
check "标记文件不存在＝未武装" 0 "$(decide)"

echo
echo "2) 静态检查"
# macOS 的 touch 在 /usr/bin/touch，不存在 /bin/touch。
# 配合 2>/dev/null，这类错误会静默发生 —— 曾因此导致开机解除标记从未生成。
# 所以任何绝对路径都必须真实存在。
badpath=$(grep -oE '/(bin|usr/bin|usr/sbin)/[a-z_-]+' "$SRC" \
          | sort -u \
          | grep -v '^/bin/lidguard$' \
          | while read -r p; do [ -x "$p" ] || echo "$p"; done)
if [ -z "$badpath" ]; then
    printf "  ✅ %-24s 所有绝对路径均可执行\n" "路径检查"
    pass=$((pass+1))
else
    printf "  ❌ %-24s 以下路径不存在:\n%s\n" "路径检查" "$badpath"
    fail=$((fail+1))
fi

echo
echo "=== 结果：通过 $pass 项，失败 $fail 项 ==="
[ "$fail" -eq 0 ] || exit 1