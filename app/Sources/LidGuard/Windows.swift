import AppKit
import SwiftUI

// MARK: - 安全说明窗口

final class SafetyWindowController: NSWindowController {
    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "忘记关掉也不会失控"
        w.identifier = NSUserInterfaceItemIdentifier("com.lidguard.safety")
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.center()
        w.contentViewController = NSHostingController(
            rootView: SafetyView().frame(width: 340))
    }
}

struct SafetyView: View {
    /// dismissWindow 需要 macOS 14，直接关窗以保持 macOS 13 兼容
    private func close() { NSApp.keyWindow?.close() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("忘记关掉也不会失控").font(.system(size: 15, weight: .semibold))
            row("clock.badge.checkmark", "时间硬上限",
                "武装最长 4/8/24 小时，到点自动恢复休眠。")
            row("arrow.uturn.backward.circle", "重启自动解除",
                "每次开机都会清空武装状态，不会跨重启残留。")
            row("bolt.slash", "拔电立即恢复",
                "守护进程每 10 秒检查一次电源，拔掉充电器后自动关闭禁睡。")
            row("thermometer.high", "过热自动放弃",
                "系统记录温度警告时立刻恢复休眠。")
            row("terminal", "随时手动回滚",
                "终端执行 sudo pmset -a disablesleep 0")
            Divider()
            Text("界面里点「解除武装」，效果等同于上面这条回滚命令。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("知道了") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(.green).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 统计窗口

final class StatsWindowController: NSWindowController {
    convenience init(monitor: Monitor) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "守护记录"
        w.identifier = NSUserInterfaceItemIdentifier("com.lidguard.stats")
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.center()
        w.contentViewController = NSHostingController(
            rootView: StatsListView().environmentObject(monitor))
    }
}

struct StatsListView: View {
    @EnvironmentObject var mon: Monitor
    /// dismissWindow 需要 macOS 14，直接关窗以保持 macOS 13 兼容
    private func close() { NSApp.keyWindow?.close() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("守护记录").font(.system(size: 15, weight: .semibold))

            if mon.stats.sessions.isEmpty {
                Text("还没有记录。武装后合盖离开，回来就有了。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(mon.stats.sessions.enumerated().reversed()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(Fmt.duration((s.endedAt ?? Date())
                                        .timeIntervalSince(s.startedAt)))
                                        .font(.system(size: 11)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                let top = s.agentSeconds.filter { $0.value > 30 }
                                    .sorted { $0.value > $1.value }.prefix(3)
                                if !top.isEmpty {
                                    Text(top.map { "\($0.key) \(Fmt.short($0.value))" }
                                         .joined(separator: " · "))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("清空统计", role: .destructive) { mon.resetStats() }
                Spacer()
                Button("关闭") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 340, minHeight: 300)
    }
}