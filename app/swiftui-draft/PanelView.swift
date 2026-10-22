import SwiftUI

// MARK: - 主面板

struct PanelView: View {
    @EnvironmentObject var mon: Monitor
    @State private var durationHours: Double = 8
    @State private var showSafety = false
    @State private var showStats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            powerSection
            divider
            agentSection
            divider
            controlSection
            verdict
            quickActions
            divider
            statsSection
            safetyRow
            footer
        }
        .frame(width: 344)
        .background(.ultraThinMaterial)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 7) {
            LidIcon(size: 15, active: mon.isArmed && mon.system.onAC)
            Text("LidGuard").font(.system(size: 13.5, weight: .semibold))
            Spacer()
            pill(mon.isArmed ? "已武装" : "未武装",
                 color: mon.isArmed ? .green : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func pill(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
    }

    // MARK: 电源

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("电源状态")
            row(icon: "bolt.fill",
                title: "电源",
                value: mon.system.onAC ? "已接通电源" : "电池供电",
                tint: mon.system.onAC ? .green : .orange)
            row(icon: "battery.75percent",
                title: "电量",
                value: mon.system.batteryPercent >= 0 ? "\(mon.system.batteryPercent)%" : "未知",
                tint: .primary,
                trailing: mon.system.isCharging ? "充电中" : nil)
            row(icon: "thermometer.medium",
                title: "温度",
                value: mon.system.thermalLabel,
                tint: thermalTint)
            row(icon: "clock",
                title: "预计可用",
                value: mon.isArmed ? Fmt.duration(mon.remaining) : "—",
                tint: .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var thermalTint: Color {
        switch mon.system.thermalRaw {
        case "nominal": return .primary
        case "fair":    return .orange
        default:        return .red
        }
    }

    private func row(icon: String, title: String, value: String,
                     tint: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 12.5))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.vertical, 1)
    }

    // MARK: Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("AI 任务活动")
            ForEach(mon.agents) { a in
                agentRow(a)
            }
            if mon.agents.isEmpty {
                Text("采样中…").font(.system(size: 12))
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func agentRow(_ a: AgentState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(a.state))
                .frame(width: 5, height: 5)
            Text(a.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            LevelBars(level: a.level, color: stateColor(a.state))
            Text(a.state == .notRunning ? "—" : Fmt.short(a.sessionActiveSeconds))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(a.state.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stateColor(a.state))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .help(a.detail)
    }

    private func stateColor(_ s: ActivityState) -> Color {
        switch s {
        case .busy:       return .green
        case .idle:       return .secondary
        case .notRunning: return Color.secondary.opacity(0.45)
        }
    }

    // MARK: 控制

    private var controlSection: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许合盖不休眠").font(.system(size: 13, weight: .semibold))
                    Text("武装后，通电时合盖继续运行")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { mon.isArmed },
                    set: { mon.setArmed($0, hours: durationHours) }
                )).labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

            HStack {
                Text("最长保活时长").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: $durationHours) {
                    Text("4h").tag(4.0)
                    Text("8h").tag(8.0)
                    Text("24h").tag(24.0)
                    Text("∞").tag(1_000_000.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .onChange(of: durationHours) { _, newValue in
                    if mon.isArmed { mon.setArmed(true, hours: newValue) }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 结论条

    private var verdict: some View {
        HStack(spacing: 8) {
            Image(systemName: verdictIcon)
                .font(.system(size: 12))
            Text(verdictText)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(verdictColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(verdictColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var verdictText: String {
        if mon.isArmed && mon.system.onAC {
            return "已武装 + 已接通电源 → 合盖后机器不会睡眠"
        }
        if mon.isArmed {
            return "已武装，但当前电池供电 → 合盖仍会正常休眠"
        }
        return "未武装 → 合盖会正常休眠"
    }
    private var verdictIcon: String {
        (mon.isArmed && mon.system.onAC) ? "lock.open.fill" : "moon.zzz.fill"
    }
    private var verdictColor: Color {
        (mon.isArmed && mon.system.onAC) ? .green : .secondary
    }

    // MARK: 快捷操作

    private var quickActions: some View {
        HStack(spacing: 6) {
            quickButton("立即休眠", icon: "power") { mon.sleepNow() }
            quickButton("解除武装", icon: "hand.raised") { mon.setArmed(false, hours: 0) }
            quickButton("查看日志", icon: "doc.text") { showStats = true }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    private func quickButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: 统计

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("累计守护")
            HStack(spacing: 14) {
                statBlock("\(mon.stats.totalCount)", "次", "合盖守护")
                statBlock(String(format: "%.0f", mon.stats.totalSeconds / 3600),
                          "小时", "累计时长")
                statBlock(String(format: "%.1f", mon.stats.todaySeconds / 3600),
                          "小时", "今天")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func statBlock(_ n: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(n).font(.system(size: 19, weight: .bold)).monospacedDigit()
                Text(unit).font(.system(size: 11, weight: .semibold))
            }
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 安全提示

    private var safetyRow: some View {
        Button {
            showSafety = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 15, height: 15)
                    .background(.secondary.opacity(0.25), in: Circle())
                    .foregroundStyle(.secondary)
                Text("忘记关掉怎么办？").font(.system(size: 11.5))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .popover(isPresented: $showSafety, arrowEdge: .top) {
            SafetySheet()
        }
    }

    // MARK: 页脚

    private var footer: some View {
        HStack {
            Text(mon.isArmed ? "本轮已守护 \(Fmt.duration(mon.elapsed))" : "点击图标打开面板")
            Spacer()
            Text(mon.badge.isEmpty ? "5 秒刷新" : "离开 \(mon.badge)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var divider: some View {
        Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 14)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - 电平条

struct LevelBars: View {
    let level: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? color : Color.secondary.opacity(0.22))
                    .frame(width: 4, height: CGFloat(3 + i * 2))
            }
        }
        .frame(width: 26, height: 11, alignment: .bottom)
    }
}

// MARK: - 图标

struct LidIcon: View {
    let size: CGFloat
    let active: Bool

    var body: some View {
        Image(systemName: "macbook")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(active ? Color.green : Color.secondary)
    }
}

// MARK: - 安全说明弹层

struct SafetySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("忘记关掉也不会失控")
                .font(.system(size: 14, weight: .semibold))
            safetyRow("clock.badge.checkmark", "时间硬上限",
                      "武装最长 4/8/24 小时，到点自动恢复休眠。")
            safetyRow("arrow.uturn.backward.circle", "重启自动解除",
                      "每次开机都会清空武装状态，不会跨重启残留。")
            safetyRow("bolt.slash", "拔电立即恢复",
                      "守护进程每 10 秒检查一次电源，拔掉充电器后自动关闭禁睡。")
            safetyRow("thermometer.high", "过热自动放弃",
                      "系统记录温度警告时立刻恢复休眠。")
            safetyRow("terminal", "随时手动回滚",
                      "终端执行 sudo pmset -a disablesleep 0")
            Divider()
            Text("界面里点「解除武装」，效果等同于上面这条回滚命令。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("知道了") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func safetyRow(_ icon: String, _ title: String, _ detail: String) -> some View {
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

// MARK: - 统计详情

struct StatsDetail: View {
    @EnvironmentObject var mon: Monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("守护记录").font(.system(size: 14, weight: .semibold))
            if mon.stats.sessions.isEmpty {
                Text("还没有记录。武装后合盖离开，回来就有了。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(mon.stats.sessions.enumerated().reversed()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(Fmt.duration((s.endedAt ?? Date()).timeIntervalSince(s.startedAt)))
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
                .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Button("清空统计", role: .destructive) { mon.resetStats() }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}