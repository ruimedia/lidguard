# LidGuard · 合盖不休眠

> **macOS 合盖不休眠工具 · macbook lid keep running · 安全封装 `pmset disablesleep`**

合盖离开时让 AI 任务继续跑，**拔电后自动恢复正常休眠**。

只有**接通电源**且**你主动武装过**时，合盖才不会让机器休眠；
一旦拔掉电源、超过时间上限、温度告警或重启，立刻恢复休眠。

[English summary](#english-summary) · [安全模型](docs/SAFETY.md) · [图标设计](docs/assets/preview.html)

---

## 为什么需要它

MacBook 无外接显示器时，合盖休眠**无法**被 `caffeinate` 或 `IOPMAssertion` 挡住。
唯一有效的开关是：

```bash
sudo pmset disablesleep 1
```

但这个开关有三个危险特性：

1. **它是单一全局标志**，不出现在 `pmset -g cap` 里，无法按电源类型区分。
   所以网上流传的 `pmset -c disablesleep 1`（`-c` = 仅充电时）**根本不起作用**。
2. 它会**一并禁用 macOS 的「电量过低强制休眠」保护**。
3. 它的取值持久化在 `/Library/Preferences/com.apple.PowerManagement.plist`，**跨重启残留**。

第 2、3 条加起来的后果很具体：插着电池、忘了关、合盖进包 —— 机器会一直保持清醒
直到电池彻底耗尽。LidGuard 就是来解决这个问题的。

## 核心保证

**任何不确定都倒向「让它睡」。**

判定规则只有一条，任意条件不满足立即恢复休眠：

```
disablesleep = 1   仅当  已武装 ∧ 接通电源 ∧ 未超时 ∧ 无温度警告 ∧ 本次开机未重启过
disablesleep = 0   其余所有情况
```

|安全机制 | 说明 |
|---|---|
| 时间硬上限 | 武装最长 4 / 8 / 24 小时，到点自动恢复休眠 |
| 断电即停 | 拔掉电源的下一个轮询周期（10 秒内）立即恢复 |
| 重启自动解除 | 双重判据：`INIT_MARKER` + `kern.boottime` 直接比对，绝不跨重启残留 |
| 温度兜底 | 出现温度警告立即恢复休眠 |
| 超时降级 | 守护进程异常退出后 `disablesleep` 保持为 0 |

## 它不会做什么

- ❌ 不安装、不修改任何 AI agent 的配置
- ❌ 不注入任何 hook、不注册开机自启的第三方 helper
- ❌ 不发起任何网络请求
- ❌ 不改 `pmset disablesleep` 以外的任何电源设置
- ❌ 不需要任何 `sudoers` 规则（守护进程本身就是 root，见下）

## 架构

```
┌──────────────────────────────────────────────┐
│  LidGuard.app   用户级 · 无任何特权             │
│  菜单栏 UI / agent 状态探测 / 守护统计          │
│  只能读写 ~/.lidguard/ 下的标记文件            │
└───────────────────┬──────────────────────────┘
                    │  标记文件
┌───────────────────▼──────────────────────────┐
│  /usr/local/bin/lidguard   root LaunchDaemon  │
│  唯一判定逻辑所在，每 10 秒执行一次             │
│  整机只被一处改动影响：pmset disablesleep      │
└──────────────────────────────────────────────┘
```

**判定逻辑只存在于 root 守护脚本里。** 界面进程没有任何特权，它写的只是一个
「用户希望保持清醒」的标记文件；真正的 `pmset` 调用由 launchd 以 root 身份执行。
因此**不需要任何 sudoers 规则**，也不需要安装常驻提权 helper。

## 安装

```bash
git clone https://github.com/ruimedia/lidguard.git
cd lidguard
sudo ./install.sh
```

### 构建菜单栏 App

```bash
cd app
./build-app.sh
open .build/LidGuard.app
```

只需要 Command Line Tools，**不需要完整 Xcode**。

## 使用

1. 插上电源
2. 点菜单栏的 LidGuard 图标，把「合盖不休眠」开关打开
3. 合盖离开

回来时菜单栏图标旁会显示本次离开的时长。

| 命令 | 作用 |
|---|---|
| `lidguard on [小时数]` | 武装（默认 8 小时上限） |
| `lidguard off` | 立即解除，并立刻恢复休眠 |
| `lidguard status` | 查看当前判定结果和原因 |
| `lidguard --daemon` | 内部：LaunchDaemon 调用入口 |

## 随时检查与回滚

这两个命令请记住，它们能让你在任何时候确认机器的真实电源状态：

```bash
# 查看系统真实的睡眠禁用状态：No=正常，Yes=休眠被禁
ioreg -r -c IOPMrootDomain | grep SleepDisabled

# 强制回滚，立即恢复正常休眠
sudo pmset -a disablesleep 0
```

## 卸载

```bash
sudo ./install.sh --uninstall
```

## 支持的 AI agent

以下 agent 被纳入活动状态探测（仅用于**界面展示**，不参与保活触发决策）：

| Agent | 活动信号来源 |
|---|---|
| MiniMax Code | `~/.minimax/sessions` 写入时间 |
| WorkBuddy | `~/.workbuddy/logs` 写入时间 |
| Codex | `~/.codex/*.sqlite` 写入时间 |
| Claude Code | `~/.claude/projects` 写入时间 |
| OpenCode | `~/.opencode`、`~/.local/share/opencode` |
| Cursor | `~/Library/Application Support/Cursor/User/workspaceStorage` |

判定方式为**日志写入时间 + CPU 活动度**双重信号。

> 实测结论：CPU 信号在这些 agent 上几乎无效 —— agent 大部分时间在等待网络返回，
> CPU 使用率长期为 0。因此**日志写入时间承担了几乎全部判定权重**，CPU 仅作兜底。
> 界面刻意不显示 CPU 数字，因为它几乎不动，容易让人误以为程序没在工作。

## 仓库结构

```
daemon/lidguard        root 守护脚本（判定逻辑唯一所在）
install.sh             安装 / 卸载脚本
tools/test-decision.sh 判定逻辑测试（10 项，pmset 打桩，与实时电源状态无关）
tools/probe.swift      无界面的检测核心，可单独编译运行
app/                   AppKit 菜单栏 App（Swift）
  Sources/LidGuard/      7 个源文件
  swiftui-draft/         SwiftUI 版本草稿（见下）
docs/SAFETY.md          安全模型与判定逻辑详解
docs/assets/            图标 SVG 源文件与生成脚本
docs/ui-mockup.html     界面设计稿（深浅双色，浏览器直接打开）
```

### 跑测试

```bash
sh tools/test-decision.sh
```

测试会把守护脚本里的 `pmset` 替换成桩程序，因此**无论机器当前插没插电都得到同样结果**，
可以在 CI 里跑。它只改动 `~/.lidguard/armed`，测完自动还原原状态。

### 为什么界面用 AppKit 而不是 SwiftUI

`@State` / `@StateObject` 依赖 `SwiftUIMacros` 插件，该插件**随完整 Xcode 分发**，
在只安装了 Command Line Tools 的机器上无法编译。为了让项目在没有 Xcode 的机器上
也能构建，界面改用纯 AppKit 实现。

`app/swiftui-draft/` 保留了等价的 SwiftUI 版本，装了 Xcode 后可直接迁回。

## 系统要求

- macOS 13 或更高（Apple Silicon 与 Intel 均可）
- root 权限仅用于安装 LaunchDaemon，App 本身运行在用户级

## 已知局限

诚实列出，详见 [docs/SAFETY.md](docs/SAFETY.md)：

- `disablesleep` 会禁用低电量强制休眠，这是该开关的固有行为，无法只关闭其中一项
- Apple Silicon 不支持 Wi-Fi 唤醒；本机无启用有线网口，**真正的远程唤醒做不到**
  （保持清醒 ≠ 可远程唤醒）
- 若守护进程在 `disablesleep=1` 期间崩溃，该值会持续到下次手动纠正；
  8 小时硬上限把最坏情况限制在 8 小时内

---

## English summary

**LidGuard** is a macOS menu bar tool that keeps your Mac awake while the lid is closed,
and restores normal sleep as soon as you unplug.

There is exactly one mechanism on macOS that survives a closed lid without an external
display: `pmset disablesleep`. That switch is dangerous — it also disables the
low-battery forced-sleep protection, it persists across reboots, and it is a single
global flag that **cannot** be scoped to AC power (`pmset -c disablesleep` does not work).

LidGuard wraps that one switch with a single rule:

```
disablesleep = 1   only if  armed ∧ on AC power ∧ within time budget ∧ no thermal warning ∧ not from a previous boot
disablesleep = 0   everything else
```

Any uncertainty resolves to *let it sleep*.

- No sudoers rules — the daemon already runs as root
- No agent config modification, no hooks, no network access
- Changes exactly one power setting: `pmset disablesleep`

### Install

```bash
git clone https://github.com/ruimedia/lidguard.git
cd lidguard
sudo ./install.sh
cd app && ./build-app.sh && open .build/LidGuard.app
```

### Verify and roll back at any time

```bash
ioreg -r -c IOPMrootDomain | grep SleepDisabled   # No=normal, Yes=sleep disabled
sudo pmset -a disablesleep 0                       # force rollback
```

### Uninstall

```bash
sudo ./install.sh --uninstall
```

---

## 关于 / About

**RUI Media CO., LIMITED ／ 香港奢华品牌传播有限公司**

RUI Media 是一家面向奢华酒店、旅游目的地与高端生活方式品牌的传播与内容运营公司，
围绕品牌定位、公共关系、编辑内容、社交媒体及视觉表达组织项目交付。公司正在推进
**RUIDITOR** —— 一个把品牌资料、内容规范、编辑审核与客户反馈连接起来的品牌传播
工作流产品，在保留专业判断与人工责任的前提下，探索更稳定、可追溯的传播交付方式。

LidGuard 是 RUI Media 的内部工具，选择公开是为了让同一条命令的代价被更多人看见 ——
`pmset disablesleep` 是个很少有人讲清楚后果的开关。

## 许可 / License

**保留所有权利。** 本仓库公开仅供阅读与安全研究，未授予任何复制、修改、
分发或商业使用的许可。详见 [LICENSE](LICENSE)。