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
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不显示 Dock 图标

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = PanelViewController(monitor: monitor)

        monitor.start()

        // 角标：离开超过 2 分钟才在菜单栏显示时长，平时保持干净
        monitor.$badge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureButton() }
            .store(in: &cancellables)

        monitor.$isArmed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureButton() }
            .store(in: &cancellables)

        // --demo：启动后自动展开面板，便于截图验证 UI 渲染
        if CommandLine.arguments.contains("--demo") {
            if let panel = popover.contentViewController as? PanelViewController {
                popover.show(relativeTo: statusItem.button?.bounds ?? .zero,
                             of: statusItem.button!, preferredEdge: .minY)
                panel.view.window?.makeKey()
            }
        }

        // --self-test：验证「忘记关掉怎么办 / 累计统计」两个按钮的真实点击效果。
        // 曾经的 bug 是窗口控制器是方法内局部变量，返回即释放、窗口跟着消失，
        // 所以这里不靠截图，而是跨多个 runloop 轮询窗口是否仍然可见。
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
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
        guard let b = statusItem.button else { return }
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

    @objc private func togglePopover() {
        if let b = statusItem.button { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
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