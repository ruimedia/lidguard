# 安全模型

LidGuard 会修改 macOS 的休眠行为，因此本文档记录**完整的判定逻辑**、
**所有会修改系统状态的路径**，以及**每条路径的回滚方式**。

> 如果你只想记住两条命令，请记这两条：
>
> ```bash
> ioreg -r -c IOPMrootDomain | grep SleepDisabled   # No=正常  Yes=休眠被禁
> sudo pmset -a disablesleep 0                       # 强制回滚
> ```

---

## 1. 唯一的系统级改动

LidGuard 整机只修改**一项**电源设置：

```
pmset disablesleep
```

没有任何其他改动。没有网络请求，没有 agent 配置修改，没有 hook 注入，
没有常驻提权 helper，没有 sudoers 规则。

### 这个开关的真实语义

| 事实 | 后果 |
|---|---|
| 它是**单一全局标志** | 无法按电源类型区分。`pmset -c disablesleep 1` 中的 `-c`（仅充电时）**无效** |
| 它不出现在 `pmset -g cap` | 无法查询各电源类型的独立配置 |
| 它会**禁用「电量过低强制休眠」** | 插电池合盖进包 = 一直清醒到彻底没电 |
| 它持久化在 `/Library/Preferences/com.apple.PowerManagement.plist` | **跨重启残留** |

LidGuard 的全部设计，就是为了在使用这个开关的同时消除上表后两行的风险。

---

## 2. 判定逻辑

判定逻辑**只存在于 `daemon/lidguard` 中**，以 root 身份由 LaunchDaemon 每 10 秒执行一次。

```
DECISION = 0   默认值 = 恢复休眠
```

只有以下条件**全部满足**才置为 1，任一不满足立即返回 0：

| # | 条件 | 失败时的实际行为 |
|---|---|---|
| 1 | 武装标记文件存在且可读 | 恢复休眠 |
| 2 | 标记文件的修改时间不晚于当前时间 | 恢复休眠（时钟异常） |
| 3 | 标记文件的修改时间**不早于本次开机时间** | 恢复休眠（跨重启残留） |
| 4 | 距标记文件创建的时间未超过预算（默认 8 小时） | 恢复休眠（超时） |
| 5 | `pmset -g ps` 显示 `'AC Power'` | 恢复休眠（未接电源） |
| 6 | `pmset -g therm` 显示 `No thermal warning level has been recorded` | 恢复休眠（温度告警） |

设计原则：**任何「不确定」都倒向「让它睡」。**
读取失败、解析失败、时间异常、命令无输出——全部按「不满足」处理。

### 双重重启防护

条件 3 和开机时的 `INIT_MARKER`（`/var/run/lidguard.initialized`）构成双保险：

- `INIT_MARKER` 依赖 `/var/run` 在开机时被清空 —— 已实测确认该行为成立
- 条件 3 直接比对 `kern.boottime` 与标记文件 mtime —— **即使 `INIT_MARKER` 因任何原因残留也不会漏判**

---

## 3. 权限模型

```
LidGuard.app   用户级进程，无任何特权
               只能写 ~/.lidguard/ 下的标记文件

lidguard       root LaunchDaemon
               唯一执行 pmset 的地方
```

**因此不需要任何 `sudoers` 规则。** 守护进程本身就以 root 身份运行，
用户级 App 完全不需要提权，也无法提权。

### 标记文件通道

| 文件 | 创建者 | 消费者 | 含义 |
|---|---|---|---|
| `~/.lidguard/armed` | 界面 / `lidguard on` | 守护进程 | 内容为时间预算秒数 |
| `~/.lidguard/sleepnow` | 界面 | 守护进程 | 请求立即休眠 |
| `/var/run/lidguard.initialized` | 守护进程 | 守护进程 | 本次开机已处理过 |

标记文件路径由 `stat -f%Su /dev/console` 动态确定，跟随当前登录用户。

---

## 4. 触发 `pmset` 的全部路径

穷举如下，没有其他路径：

| # | 触发者 | 命令 | 何时 |
|---|---|---|---|
| 1 | 守护进程主循环 | `pmset -a disablesleep <0\|1>` | 每 10 秒，且判定值与当前值不同时 |
| 2 | 界面「立即休眠」按钮 | `pmset -a disablesleep 0` + `pmset sleepnow` | 用户点击后 10 秒内 |
| 3 | `lidguard off` | 无（仅删除标记） | 由路径 1 在下个周期完成恢复 |
| 4 | 卸载脚本 | `pmset -a disablesleep 0` | 显式兜底 |

`apply_sleep()` 只接受 `0` 或 `1` 两个值，其他值直接拒绝并记日志：

```sh
case "$_want" in
    0|1) : ;;
    *) log "ERROR: refusing invalid disablesleep value"; return 1 ;;
esac
```

---

## 5. 失效模式分析

| 故障 | 后果 | 保护 |
|---|---|---|
| 守护进程崩溃 / 被杀 | `disablesleep` 保持为 1 | **这是最危险的场景**。缓解：8 小时硬上限意味着最多 8 小时后拔电时机器仍清醒。可用路径 4 立即恢复 |
| LaunchDaemon 未加载 | 从未打开过 `disablesleep` | 安全（无操作） |
| 标记文件被误删 | 立即恢复休眠 | 安全 |
| 电源适配器识别失败 | 判定为「未接电源」→ 不保活 | 安全（倒向睡觉） |
| 温度读取命令失败 | `thermal_ok` 返回假 → 不保活 | 安全（倒向睡觉） |
| 系统时间被大幅回拨 | 条件 2 拦截 | 安全 |
| 系统时间被大幅前拨 | 条件 2 拦截 | 安全 |

### 关于「守护进程崩溃」

这是唯一一个「不安全」的失效模式：若守护进程在 `disablesleep=1` 期间退出，
该值会**持续到下次有人手动纠正**。

设计上把风险压到最低的方式是**硬时间上限**。默认 8 小时，
所以最坏情况下机器在拔电后仍会保持清醒不超过 8 小时，
且电量过低强制休眠保护已被该开关一并禁用 —— 这是本工具固有的、
无法通过软件规避的权衡。详见下文「已知局限」。

---

## 6. 已知局限

诚实列出，不回避：

1. **`disablesleep` 会禁用低电量强制休眠。** 这是该开关的固有行为，无法只关闭其中一项。
   LidGuard 的补偿是：只在接通电源时开启，且有 8 小时硬上限。

2. **无外接显示器时，合盖不休眠只有这一个开关。**
   `caffeinate` 和 `IOPMAssertion` 在合盖场景下挡不住休眠，
   接上外接显示器后它们才有效。

3. **唤醒后若守护进程未运行，需要手动执行一次 `lidguard status`。**

4. **Apple Silicon 不支持 Wi-Fi 唤醒（WoL）。** 本机无启用有线网口，
   因此**真正的远程唤醒做不到**。保持清醒 ≠ 可远程唤醒：
   机器保持在线、可被 SSH/网络服务访问，但不能从关机或深度睡眠中远程唤醒。

5. **`kern.boottime` 解析若失败，条件 3 会被跳过。** 此时仍由 `INIT_MARKER`
   和 8 小时上限兜底，失效模式可接受。

---

## 7. 验证与回滚

### 查看真实状态

```bash
ioreg -r -c IOPMrootDomain | grep SleepDisabled
```

- 输出 `No` → 正常，休眠未被禁用
- 输出 `Yes` → 休眠已被禁用，合盖不会睡

### 强制回滚

```bash
sudo pmset -a disablesleep 0
ioreg -r -c IOPMrootDomain | grep SleepDisabled   # 确认已变回 No
```

### 查看守护进程判定

```bash
lidguard status
```

会打印电源、武装状态、剩余时间、温度、当前 `disablesleep` 值和判定结果。

### 查看守护日志

```bash
log show --predicate 'sender == "lidguard"' --last 1h --style compact
```

### 完整卸载

```bash
sudo ./install.sh --uninstall
```

兜底（即使脚本失败，这两条也足以完全恢复）：

```bash
sudo launchctl bootout system/com.lidguard.daemon
sudo pmset -a disablesleep 0
```