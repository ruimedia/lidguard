import AppKit
import Combine

// MARK: - 主题

enum Theme {
    static func card() -> NSColor {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
    }
    static func stateColor(_ s: ActivityState) -> NSColor {
        switch s {
        case .busy:       return .systemGreen
        case .idle:       return .secondaryLabelColor
        case .notRunning: return NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        }
    }
}

// MARK: - 布局与控件工厂

enum UI {
    static let padX: CGFloat = 14

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    static func secondary(_ size: CGFloat = 11) -> NSTextField { label("", size: size, color: .secondaryLabelColor) }

    static func separator() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1),
            v.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: padX),
            v.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -padX),
            v.topAnchor.constraint(equalTo: holder.topAnchor),
            v.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return holder
    }

    /// 垂直堆叠容器，自带边距
    static func vstack(_ views: [NSView], spacing: CGFloat = 0,
                       top: CGFloat = 0, bottom: CGFloat = 0) -> NSStackView {
        let s = UI.makeStack(views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: top, left: padX,
                                    bottom: bottom, right: padX)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 0,
                       alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = UI.makeStack(views)
        s.orientation = .horizontal
        s.alignment = alignment
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func spacer() -> NSView { NSView() }

    /// macOS 27 SDK 里 NSStackView 的初始化签名有变动，
    /// 统一走 addArrangedSubview 累积，避免依赖具体 init 标签。
    static func makeStack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView()
        views.forEach { s.addArrangedSubview($0) }
        return s
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = color
        iv.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
        iv.heightAnchor.constraint(equalToConstant: size + 4).isActive = true
        return iv
    }

    static func sectionLabel(_ t: String) -> NSTextField {
        return label(t, size: 10, weight: .semibold, color: .tertiaryLabelColor)
    }

    /// 圆角卡片，内部装一个 stack
    static func card(_ inner: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = Theme.card().cgColor
        v.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: insets.left),
            inner.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -insets.right),
            inner.topAnchor.constraint(equalTo: v.topAnchor, constant: insets.top),
            inner.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -insets.bottom),
        ])
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

// MARK: - 信息行

final class InfoRow: NSStackView {
    private let valueLabel: NSTextField

    init(icon: String, title: String, value: String = "", tint: NSColor = .labelColor) {
        valueLabel = UI.label(value, size: 12.5, weight: .medium, color: tint)
        valueLabel.alignment = .right
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 9
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(UI.symbol(icon, size: 11, color: .secondaryLabelColor))
        addArrangedSubview(UI.label(title, size: 12.5))
        addArrangedSubview(UI.spacer())
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ s: String, tint: NSColor? = nil) {
        valueLabel.stringValue = s
        if let t = tint { valueLabel.textColor = t }
    }
}

// MARK: - Agent 行

final class AgentRow: NSStackView {
    private let nameLabel = UI.label("", size: 12.5, weight: .medium)
    private let durationLabel = UI.secondary(10.5)
    private let stateLabel = UI.label("", size: 11, weight: .semibold)
    private let dot = NSView()
    private var bars: [NSView] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        addArrangedSubview(dot)
        addArrangedSubview(nameLabel)
        addArrangedSubview(UI.spacer())

        let barStack = NSStackView()
        barStack.orientation = .horizontal
        barStack.spacing = 2
        barStack.alignment = .bottom
        barStack.translatesAutoresizingMaskIntoConstraints = false
        for i in 1...4 {
            let b = NSView()
            b.wantsLayer = true
            b.layer?.cornerRadius = 1.5
            b.widthAnchor.constraint(equalToConstant: 4).isActive = true
            b.heightAnchor.constraint(equalToConstant: CGFloat(3 + i * 2)).isActive = true
            barStack.addArrangedSubview(b)
            bars.append(b)
        }
        barStack.widthAnchor.constraint(equalToConstant: 26).isActive = true
        addArrangedSubview(barStack)

        durationLabel.alignment = .right
        durationLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        addArrangedSubview(durationLabel)

        stateLabel.alignment = .right
        stateLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        addArrangedSubview(stateLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, state: ActivityState, level: Int,
                   sessionSeconds: Double, detail: String) {
        nameLabel.stringValue = name
        toolTip = detail
        let c = Theme.stateColor(state)
        dot.layer?.backgroundColor = c.cgColor
        stateLabel.stringValue = state.label
        stateLabel.textColor = c
        durationLabel.stringValue = state == .notRunning ? "—" : Fmt.short(sessionSeconds)
        for (i, v) in bars.enumerated() {
            v.layer?.backgroundColor = (i < level ? c
                : NSColor.secondaryLabelColor.withAlphaComponent(0.22)).cgColor
        }
    }
}

// MARK: - 面板主视图

final class PanelViewController: NSViewController {
    private let mon: Monitor
    private var cancellables = Set<AnyCancellable>()

    private let iconView = NSImageView()
    private let pillDot = NSView()
    private let pillLabel = UI.label("", size: 11, weight: .semibold)
    private let pillBox = NSView()

    private let powerRow = InfoRow(icon: "bolt.fill", title: "电源")
    private let battRow  = InfoRow(icon: "battery.75percent", title: "电量")
    private let tempRow  = InfoRow(icon: "thermometer.medium", title: "温度")
    private let availRow = InfoRow(icon: "clock", title: "预计可用")

    private let agentStack = UI.vstack([], spacing: 2)
    private var agentRows: [String: AgentRow] = [:]

    private let toggle = NSSwitch()
    private let segControl = NSSegmentedControl()
    private var selectedHours: Double = 8

    private let loginSwitch = NSSwitch()
    private let loginDetail = UI.secondary(11)
    private let login: LoginItemManager = LoginItemManager.shared

    private let verdictBox = NSView()
    private let verdictIcon = NSImageView()
    private let verdictLabel = UI.label("", size: 12)

    private let statCount = UI.label("0", size: 19, weight: .bold)
    private let statTotal = UI.label("0", size: 19, weight: .bold)
    private let statToday = UI.label("0", size: 19, weight: .bold)

    private let footerLabel = UI.secondary(11)
    private let loadingLabel = UI.label("采样中…", size: 12, color: .secondaryLabelColor)

    // 必须持有强引用：NSWindowController 若无人持有会立刻释放，
    // 连带窗口一起消失，表现为「点了没反应」。
    private var safetyWindow: SafetyWindowController?
    private var statsWindow: StatsWindowController?

    init(monitor: Monitor) { self.mon = monitor; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let outer = UI.vstack([
            buildHeader(),
            UI.separator(),
            buildPower(),
            UI.separator(),
            buildAgents(),
            UI.separator(),
            buildControls(),
            buildVerdict(),
            buildQuickActions(),
            UI.separator(),
            buildSettings(),
            UI.separator(),
            buildStats(),
            buildSafety(),
            buildFooter()
        ], spacing: 0)

        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 344),
        ])

        view = root
        bind()
        refresh()
    }

    // MARK: 各区块

    private func buildHeader() -> NSView {
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true

        pillBox.wantsLayer = true
        pillBox.layer?.cornerRadius = 10
        pillDot.wantsLayer = true
        pillDot.layer?.cornerRadius = 3
        pillDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        pillDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let pillStack = UI.hstack([pillDot, pillLabel], spacing: 5)
        pillStack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        pillStack.alignment = .centerY
        pillBox.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: pillBox.leadingAnchor),
            pillStack.trailingAnchor.constraint(equalTo: pillBox.trailingAnchor),
            pillStack.topAnchor.constraint(equalTo: pillBox.topAnchor),
            pillStack.bottomAnchor.constraint(equalTo: pillBox.bottomAnchor),
        ])

        let h = UI.hstack([iconView, UI.label("LidGuard", size: 13.5, weight: .semibold),
                           UI.spacer(), pillBox])
        let s = UI.vstack([h], top: 11, bottom: 11)
        s.alignment = .leading
        return s
    }

    private func buildPower() -> NSView {
        UI.vstack([UI.sectionLabel("电源状态"), powerRow, battRow, tempRow, availRow],
                  spacing: 5, top: 11, bottom: 11)
    }

    private func buildAgents() -> NSView {
        UI.vstack([UI.sectionLabel("AI 任务活动"), agentStack, loadingLabel],
                  spacing: 6, top: 11, bottom: 11)
    }

    private func buildControls() -> NSView {
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.controlSize = .small

        let text = UI.vstack([
            UI.label("允许合盖不休眠", size: 13, weight: .semibold),
            UI.label("武装后，通电时合盖继续运行", size: 11, color: .secondaryLabelColor)
        ], spacing: 2)
        let card1 = UI.card(UI.hstack([text, UI.spacer(), toggle]))

        segControl.segmentStyle = .rounded
        segControl.segmentCount = 4
        ["4h", "8h", "24h", "∞"].enumerated().forEach {
            segControl.setLabel($0.element, forSegment: $0.offset)
        }
        segControl.selectedSegment = 1
        segControl.target = self
        segControl.action = #selector(durationChanged)
        segControl.controlSize = .small
        segControl.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let h2 = UI.hstack([UI.label("最长保活时长", size: 12.5, weight: .medium),
                            UI.spacer(), segControl])

        return UI.vstack([card1, h2], spacing: 8, top: 10, bottom: 10)
    }

    private func buildSettings() -> NSView {
        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged)
        loginSwitch.controlSize = .small

        let text = UI.vstack([
            UI.label("开机自动启动", size: 13, weight: .semibold),
            loginDetail
        ], spacing: 2)
        let card = UI.card(UI.hstack([text, UI.spacer(), loginSwitch]))
        card.widthAnchor.constraint(equalToConstant: 344 - UI.padX * 2).isActive = true

        let hint = UI.label("接通电源时图标常驻在菜单栏，电池供电时自动隐藏",
                            size: 11, color: .secondaryLabelColor)

        return UI.vstack([card, hint], spacing: 8, top: 10, bottom: 10)
    }

    private func buildVerdict() -> NSView {
        verdictBox.wantsLayer = true
        verdictBox.layer?.cornerRadius = 8
        verdictIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let h = UI.hstack([verdictIcon, verdictLabel], spacing: 8)
        verdictBox.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: verdictBox.leadingAnchor, constant: 11),
            h.trailingAnchor.constraint(equalTo: verdictBox.trailingAnchor, constant: -11),
            h.topAnchor.constraint(equalTo: verdictBox.topAnchor, constant: 9),
            h.bottomAnchor.constraint(equalTo: verdictBox.bottomAnchor, constant: -9),
        ])
        return UI.vstack([verdictBox], bottom: 10)
    }

    private func buildQuickActions() -> NSView {
        let titles = [("power", "立即休眠"), ("hand.raised", "解除武装"), ("doc.text", "查看日志")]
        let actions: [Selector] = [#selector(sleepNowTapped), #selector(disarmTapped), #selector(statsTapped)]
        var buttons: [NSView] = []
        for (i, t) in titles.enumerated() {
            let b = NSButton(title: "", target: self, action: actions[i])
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.layer?.backgroundColor = Theme.card().cgColor
            b.image = NSImage(systemSymbolName: t.0, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.attributedTitle = NSAttributedString(string: t.1, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor])
            b.controlSize = .small
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            buttons.append(b)
        }
        let h = UI.makeStack(buttons)
        h.orientation = .horizontal
        h.distribution = .fillEqually
        h.spacing = 6
        h.translatesAutoresizingMaskIntoConstraints = false
        return UI.vstack([h], bottom: 11)
    }

    private func buildStats() -> NSView {
        func block(_ value: NSTextField, _ unit: String, _ caption: String) -> NSView {
            let top = UI.hstack([value, UI.label(unit, size: 11, weight: .semibold)], spacing: 1, alignment: .centerY)
            return UI.vstack([top, UI.label(caption, size: 10.5, color: .secondaryLabelColor)], spacing: 1)
        }
        let h = UI.makeStack([
            block(statCount, "次", "合盖守护"),
            block(statTotal, "小时", "累计时长"),
            block(statToday, "小时", "今天")
        ])
        h.orientation = .horizontal
        h.distribution = .fillEqually
        h.spacing = 14
        h.translatesAutoresizingMaskIntoConstraints = false

        return UI.vstack([UI.sectionLabel("累计守护"), h], spacing: 8, top: 11, bottom: 11)
    }

    private func buildSafety() -> NSView {
        let q = UI.label("?", size: 9, weight: .bold, color: .secondaryLabelColor)
        q.alignment = .center
        q.wantsLayer = true
        q.layer?.cornerRadius = 7.5
        q.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
        q.widthAnchor.constraint(equalToConstant: 15).isActive = true
        q.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let btn = NSButton(title: "忘记关掉怎么办？", target: self, action: #selector(safetyTapped))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 11.5)
        btn.contentTintColor = .labelColor

        let h = UI.hstack([q, btn, UI.spacer(),
                            UI.symbol("chevron.right", size: 9, color: .tertiaryLabelColor)], spacing: 8)
        return UI.vstack([UI.card(h, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))],
                         bottom: 10)
    }

    private func buildFooter() -> NSView {
        UI.vstack([UI.hstack([footerLabel, UI.spacer()])], top: 9, bottom: 9)
    }

    // MARK: 刷新

    private func bind() {
        Publishers.CombineLatest4(mon.$system, mon.$agents, mon.$isArmed, mon.$stats)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.refresh() }
            .store(in: &cancellables)
        mon.$elapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFooter() }
            .store(in: &cancellables)

        login.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] st in self?.applyLoginState(st) }
            .store(in: &cancellables)
        login.$detail
            .receive(on: RunLoop.main)
            .sink { [weak self] d in self?.loginDetail.stringValue = d }
            .store(in: &cancellables)
    }

    private func applyLoginState(_ st: LoginItemState) {
        switch st {
        case .enabled:
            loginSwitch.state = .on
            loginSwitch.isEnabled = true
        case .disabled:
            loginSwitch.state = .off
            loginSwitch.isEnabled = true
        case .needsApproval:
            // 已注册但系统要求用户放行：开关显示为开，但不让再点
            loginSwitch.state = .on
            loginSwitch.isEnabled = false
        case .failed:
            loginSwitch.state = .off
            loginSwitch.isEnabled = true
        }
    }

    private func refresh() {
        let sys = mon.system
        let armed = mon.isArmed

        let pc = armed ? NSColor.systemGreen : NSColor.secondaryLabelColor
        pillLabel.stringValue = armed ? "已武装" : "未武装"
        pillLabel.textColor = pc
        pillDot.layer?.backgroundColor = pc.cgColor
        pillBox.layer?.backgroundColor = pc.withAlphaComponent(0.18).cgColor
        iconView.contentTintColor = (armed && sys.onAC) ? .systemGreen : .secondaryLabelColor

        powerRow.setValue(sys.onAC ? "已接通电源" : "电池供电",
                          tint: sys.onAC ? .systemGreen : .systemOrange)
        battRow.setValue(sys.batteryPercent >= 0 ? "\(sys.batteryPercent)%" : "未知")
        tempRow.setValue(sys.thermalLabel, tint: thermalColor(sys.thermalRaw))
        availRow.setValue(armed ? Fmt.duration(mon.remaining) : "—")

        loadingLabel.isHidden = !mon.agents.isEmpty
        if agentRows.count != mon.agents.count {
            agentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            agentRows.removeAll()
            for a in mon.agents {
                let r = AgentRow()
                agentRows[a.name] = r
                agentStack.addArrangedSubview(r)
            }
        }
        for a in mon.agents {
            agentRows[a.name]?.configure(name: a.name, state: a.state, level: a.level,
                                         sessionSeconds: a.sessionActiveSeconds, detail: a.detail)
        }

        toggle.state = armed ? .on : .off

        let willStayAwake = armed && sys.onAC
        verdictLabel.stringValue = willStayAwake
            ? "已武装 + 已接通电源 → 合盖后机器不会睡眠"
            : (armed ? "已武装，但当前电池供电 → 合盖仍会正常休眠"
                     : "未武装 → 合盖会正常休眠")
        let vc = willStayAwake ? NSColor.systemGreen : NSColor.secondaryLabelColor
        verdictLabel.textColor = vc
        verdictIcon.image = NSImage(systemSymbolName: willStayAwake ? "lock.open.fill" : "moon.zzz.fill",
                                    accessibilityDescription: nil)
        verdictIcon.contentTintColor = vc
        verdictBox.layer?.backgroundColor = vc.withAlphaComponent(0.13).cgColor

        statCount.stringValue = "\(mon.stats.totalCount)"
        statTotal.stringValue = String(format: "%.0f", mon.stats.totalSeconds / 3600)
        statToday.stringValue = String(format: "%.1f", mon.stats.todaySeconds / 3600)

        refreshFooter()
    }

    private func refreshFooter() {
        footerLabel.stringValue = mon.isArmed
            ? "本轮已守护 \(Fmt.duration(mon.elapsed))"
            : "点击图标打开面板"
    }

    private func thermalColor(_ raw: String) -> NSColor {
        switch raw {
        case "nominal": return .labelColor
        case "fair":    return .systemOrange
        default:        return .systemRed
        }
    }

    // MARK: 操作

    @objc private func toggleChanged() {
        mon.setArmed(toggle.state == .on, hours: selectedHours)
    }
    @objc private func durationChanged() {
        selectedHours = [4.0, 8.0, 24.0, 1_000_000.0][segControl.selectedSegment]
        if mon.isArmed { mon.setArmed(true, hours: selectedHours) }
    }
    @objc private func sleepNowTapped() { mon.sleepNow() }
    @objc private func loginSwitchChanged() {
        login.setEnabled(loginSwitch.state == .on)
    }
    @objc private func disarmTapped() {
        mon.setArmed(false, hours: 0)
        toggle.state = .off
    }
    @objc private func statsTapped() {
        NSApp.activate(ignoringOtherApps: true)
        if statsWindow == nil { statsWindow = StatsWindowController(monitor: mon) }
        statsWindow?.showWindow(nil)
        statsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    /// 仅供 --demo 自动验证使用
    func demoShowSafety() { safetyTapped() }
    func demoShowStats() { statsTapped() }

    @objc private func safetyTapped() {
        NSApp.activate(ignoringOtherApps: true)
        if safetyWindow == nil { safetyWindow = SafetyWindowController() }
        safetyWindow?.showWindow(nil)
        safetyWindow?.window?.makeKeyAndOrderFront(nil)
    }
}