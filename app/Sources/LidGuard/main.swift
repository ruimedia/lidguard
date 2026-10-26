import AppKit
import Combine

/// LidGuard —— 仅驻菜单栏的 macOS 守卫工具
///
/// 分工：
///   * 界面（本文件 + PanelController）是【用户级】进程，没有 root 权限，
///     只能读写 ~/.lidguard/ 下的标记文件。
///   * 真正执行 pmset 的是 /usr/local/bin/lidguard 的 root LaunchDaemon。
///     判定规则全部在那个脚本里，本 App 不做任何特权操作。

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = Monitor()
    private let login = LoginItemManager.shared
    private var cancellables = Set<AnyCancellable>()

    /// 菜单栏图标隐藏时（电池供电），面板需要一个锚点。
    /// 这里放一个 1×1 的隐形窗口贴在屏幕右上角，当作面板的弹出参照，
    /// 这样即使菜单栏没有图标，用户依然能从「应用程序」里打开面板。
    private var anchorWindow: NSWindow?
    private var anchorView: NSView?

    func applicationDidFinishLaunching(_ n: Notification) {
        // 命令行模式（--diagnose / --login）是无界面工具：
        // --force-battery：把电源读数强行当成电池供电，
        // 用来验证「不通电时菜单栏图标自动消失」这条规则。
        // 必须放在命令行分支之前，否则命令行模式下不生效。
        if CommandLine.arguments.contains("--force-battery") {
            monitor.forceBattery = true
        }

        // 不抢单实例锁、不建状态项，免得和正在运行的实例互相踢。
        if let cli = parseCLI() {
            NSApp.setActivationPolicy(.prohibited)
            monitor.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runCLI(cli)
                NSApp.terminate(nil)
            }
            return
        }

        // 单实例保护：登录项自启和用户手动点开撞车时，只保留一个。
        // 拿不到锁就直接退出，并把已经在跑的那个叫醒。
        if !SingleInstance.shared.acquire() {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "media.rui.lidguard")
                .first?.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)   // 不显示 Dock 图标

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = PanelViewController(monitor: monitor)

        monitor.start()
        login.refresh()

        // 角标：离开超过 2 分钟才在菜单栏显示时长，平时保持干净
        monitor.$badge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureButton() }
            .store(in: &cancellables)

        monitor.$isArmed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureButton() }
            .store(in: &cancellables)

        // 菜单栏常驻规则：接通电源时常驻，电池供电时自动消失。
        // 必须等第一次真实采样出来再动手，否则会用占位值误判。
        Publishers.CombineLatest(monitor.$system, monitor.$hasSampled)
            .receive(on: RunLoop.main)
            .sink { [weak self] sys, sampled in
                guard sampled else { return }
                self?.applyMenuBarVisibility(onAC: sys.onAC)
            }
            .store(in: &cancellables)

        // --demo：启动后自动展开面板，便于截图验证 UI 渲染
        if CommandLine.arguments.contains("--demo") {
            showPanel()
        }

        // --self-test：验证「忘记关掉怎么办 / 累计统计」两个按钮的真实点击效果。
        // 曾经的 bug 是窗口控制器是方法内局部变量，返回即释放、窗口跟着消失，
        // 所以这里不靠截图，而是跨多个 runloop 轮询窗口是否仍然可见。
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
        }

        // 强制电池模式下补一次采样，让首帧就是「电池供电」
        if monitor.forceBattery {
            monitor.refresh()
        }

        // --verify-menubar：在真实 GUI 路径里实测「通电显示 / 断电隐藏」这条规则。
        // --diagnose 是无界面模式，看不到状态项本身，所以另开一个走完整路径的。
        if CommandLine.arguments.contains("--verify-menubar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.verifyMenuBarRule()
            }
        }
    }

    /// 依次测两次：真实电源状态下的显隐 → 强制电池后的显隐。
    private func verifyMenuBarRule() {
        let onAC = monitor.system.onAC
        let visibleOnAC = statusItem.isVisible
        print("接电源时（实际读数 \(onAC ? "AC" : "电池")）菜单栏图标："
              + (visibleOnAC == onAC ? "符合规则 ✅" : "不符合规则 ❌"))

        monitor.forceBattery = true
        monitor.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let visibleOnBattery = self.statusItem.isVisible
            print("电池供电时菜单栏图标："
                  + (visibleOnBattery ? "仍然显示 ❌" : "已隐藏 ✅"))
            NSApp.terminate(nil)
        }
    }

    // MARK: 命令行模式

    private enum CLI {
        case diagnose
        case login(String)
    }

    private func parseCLI() -> CLI? {
        let args = CommandLine.arguments
        if args.contains("--diagnose") { return .diagnose }
        if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
            return .login(args[i + 1])
        }
        return nil
    }

    private func runCLI(_ cli: CLI) {
        switch cli {
        case .diagnose:
            let sys = monitor.system
            let ac = sys.onAC
            print("=== LidGuard 诊断 ===")
            print("电源         : \(ac ? "已接通电源 (AC)" : "电池供电")")
            print("电量         : \(sys.batteryPercent)%   温度: \(sys.thermalLabel)")
            print("禁睡         : \(sys.sleepDisabled ? "是" : "否")")
            print("武装         : \(monitor.isArmed ? "已武装" : "未武装")")
            let expected = ac
            if let item = statusItem {
                let actual = item.isVisible
                print("菜单栏图标   : 期望=\(expected ? "显示" : "隐藏") "
                      + "实际=\(actual ? "显示" : "隐藏") "
                      + (expected == actual ? "✅ 一致" : "❌ 不一致"))
            } else {
                print("菜单栏图标   : 期望=\(expected ? "显示" : "隐藏")"
                      + "（命令行模式不建状态项，此处只报规则）")
            }
            print("登录项       : \(login.detail)")
            print("--- AI 任务活动 ---")
            for a in monitor.agents {
                let mark = a.state == .busy ? "●" : (a.state == .idle ? "○" : "·")
                print("  \(mark) \(a.name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + " \(a.state.label)  \(a.detail)")
            }
        case .login(let action):
            switch action {
            case "on":  login.setEnabled(true)
            case "off": login.setEnabled(false)
            default:    login.refresh()
            }
            print("登录项状态: \(login.state)  \(login.detail)")
        }
    }

    /// 自检：走和真实按钮完全相同的代码路径，然后连续多帧检查窗口存活。
    private func runSelfTest() {
        let panel = popover.contentViewController as? PanelViewController
        var report: [String] = []

        guard let panel else {
            try? "FAIL PanelViewController 未取到".write(
                to: URL(fileURLWithPath: "/tmp/lidguard-selftest.txt"),
                atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        func probe(_ label: String, _ open: () -> Void, path: String) {
            let before = NSApp.windows.filter { $0.isVisible && !$0.isSheet }.count
            open()
            for tick in 1...6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                // 每帧把 autorelease pool 排空，模拟「方法早已返回、局部变量已析构」
                let found = NSApp.windows.filter {
                    $0.isVisible && $0.identifier?.rawValue == path
                }
                report.append(String(
                    format: "%@ tick%d visible=%@ count=%d",
                    label, tick, found.isEmpty ? "NO" : "YES", NSApp.windows.count))
            }
            report.append("\(label) beforeVisibleWindows=\(before)")
        }

        probe("SAFETY", { panel.demoShowSafety() }, path: "com.lidguard.safety")
        probe("STATS",  { panel.demoShowStats()  }, path: "com.lidguard.stats")

        let out = URL(fileURLWithPath: "/tmp/lidguard-selftest.txt")
        try? report.joined(separator: "\n").write(
            to: out, atomically: true, encoding: .utf8)
        print("SELFTEST-DONE \(report.count) lines")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    private func configureButton() {
        guard let item = statusItem, let b = item.button else { return }
        b.target = self
        b.action = #selector(togglePopover)
        let armed = monitor.isArmed
        let active = armed && monitor.system.onAC

        // 用自带的合盖笔记本图标（纯黑模板图，系统按菜单栏深浅色自动反色）。
        // 找不到就退回 SF Symbol，保证任何情况下菜单栏都有东西显示。
        let symbol: NSImage? = {
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            return NSImage(systemSymbolName: "macbook", accessibilityDescription: "LidGuard")?
                .withSymbolConfiguration(cfg)
        }()

        b.imagePosition = .imageLeading

        if monitor.badge.isEmpty {
            b.image = symbol
            b.attributedTitle = NSAttributedString(string: "")
        } else {
            let text = NSAttributedString(string: " \(monitor.badge)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.labelColor])
            b.image = symbol
            b.attributedTitle = text
        }
        b.contentTintColor = active ? .systemGreen : (armed ? .systemOrange : .secondaryLabelColor)
        b.toolTip = active ? "LidGuard · 已武装，合盖不休眠"
                           : (armed ? "LidGuard · 已武装（当前电池供电）" : "LidGuard · 未武装")
    }

    /// 通电时状态项常驻，电池供电时收起来。
    /// 注意 isVisible 切换之后 button 会被重建，必须重新 configure 一次，
    /// 否则图标会退化成系统默认的样子。
    private func applyMenuBarVisibility(onAC: Bool) {
        guard let item = statusItem else { return }
        guard item.isVisible != onAC else { return }
        item.isVisible = onAC
        configureButton()
    }

    /// 面板的弹出锚点：一个 1×1 的隐形窗口。
    ///
    /// 不直接挂在状态项按钮上，有两个原因：
    ///   1. 菜单栏图标在电池供电时会被收起来，此时按钮没有屏幕位置，面板就弹不出来了；
    ///   2. macOS 27 上存在一个系统级问题——新建的 NSStatusItem 不会被 MenuBarAgent
    ///      合成进菜单栏（button 有对象、场景已注册、事件也能转发，但屏幕上就是没有）。
    ///      这时按钮的 window 没有真实坐标，挂在它身上等于面板一起消失。
    ///
    /// 所以自己造一个锚点：图标位置正常时贴在图标下方，否则贴在屏幕右上角，
    /// 面板两种情况下都弹得出来。
    private func makeAnchorView() -> NSView {
        if let v = anchorView { return v }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView = view
        panel.setFrameOrigin(anchorOrigin())
        panel.orderFront(nil)

        anchorWindow = panel
        anchorView = view
        return view
    }

    /// 锚点该放在哪：优先贴在菜单栏图标正下方，否则贴屏幕右上角。
    private func anchorOrigin() -> NSPoint {
        if statusItem?.isVisible == true, let b = statusItem?.button, let w = b.window {
            let f = w.frame
            // 宽高退化说明这个按钮并没有真正落在屏幕上（macOS 27 的合成故障）
            if f.width >= 8 && f.height >= 8 {
                return NSPoint(x: f.minX, y: f.minY)
            }
        }
        let vf = NSScreen.main?.visibleFrame ?? .zero
        // 面板宽 344，锚点往左让出半个面板宽，避免面板超出屏幕右缘
        return NSPoint(x: vf.maxX - 180, y: vf.maxY - 1)
    }

    private func showPanel() {
        guard popover.contentViewController != nil else { return }
        let anchor = makeAnchorView()
        anchorWindow?.setFrameOrigin(anchorOrigin())
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// 用户在「应用程序」里再次点 LidGuard 时，把它叫醒并把面板摆出来。
    /// 菜单栏图标隐藏时（电池供电）这是唯一的入口。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// MARK: - 入口

// 顶层代码默认不在主 actor 上，而 AppDelegate / Monitor 都是 @MainActor，
// 这里显式声明我们就在主线程（AppKit 入口天然如此）。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
