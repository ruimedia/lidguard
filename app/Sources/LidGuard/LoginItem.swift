import Foundation
import ServiceManagement
import Combine

enum LoginItemState: Equatable {
    case enabled
    case disabled
    /// 已注册但系统要求用户去「系统设置」里放行
    case needsApproval
    case failed(String)
}

/// 「开机自动启动」管理器。
///
/// 首选系统的 SMAppService.mainApp —— 这是 Apple 官方的登录项方案，
/// 注册后条目会出现在「系统设置 → 通用 → 登录项」里，用户随时能关掉，
/// 而且 macOS 会自己记住这个选择。
///
/// 但 SMAppService 对 App 有硬性要求：必须是签名过的正规 bundle。
/// 临时签名、从源码目录直接运行、路径里有变动，都会让它直接抛错。
/// 所以这里留一条退路：注册失败就改写一个用户级 LaunchAgent，
/// 功能完全等价（同样是登录后自动拉起），只是入口不在系统设置里。
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var state: LoginItemState = .disabled
    @Published private(set) var detail: String = "登录后自动启动"

    private let bundleID = "media.rui.lidguard"
    private let agentLabel = "media.rui.lidguard.agent"

    private var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private init() {}

    // MARK: 状态

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            state = .enabled
            detail = "登录后自动启动"
            return
        case .requiresApproval:
            state = .needsApproval
            detail = "需在「系统设置 → 通用 → 登录项」里放行"
            return
        default:
            break
        }
        // SMAppService 没生效时，看我们写的 LaunchAgent 兜底在不在
        if FileManager.default.fileExists(atPath: agentPlistURL.path) {
            state = .enabled
            detail = "登录后自动启动（LaunchAgent）"
        } else {
            state = .disabled
            detail = "登录后自动启动"
        }
    }

    func setEnabled(_ on: Bool) {
        if on { enable() } else { disable() }
        refresh()
    }

    // MARK: 开启 / 关闭

    private func enable() {
        // 先拆掉兜底方案，避免两条机制同时生效、开机起两个进程
        removeAgent()

        do {
            try SMAppService.mainApp.register()
            state = .enabled
            detail = "登录后自动启动"
        } catch {
            let reason = (error as NSError).localizedDescription
            if installAgent() {
                state = .enabled
                detail = "登录后自动启动（LaunchAgent）"
            } else {
                state = .failed(reason)
                detail = "开启失败：\(reason)"
            }
        }
    }

    private func disable() {
        try? SMAppService.mainApp.unregister()
        removeAgent()
    }

    // MARK: LaunchAgent 兜底

    private func installAgent() -> Bool {
        let exe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/LidGuard").path
        guard FileManager.default.fileExists(atPath: exe) else { return false }

        let dir = agentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        do { try data.write(to: agentPlistURL) } catch { return false }

        // 立刻加载一次，验证它真的能起来，而不是只写了文件
        let code = run("/bin/launchctl",
                       ["bootstrap", "gui/\(getuid())", agentPlistURL.path])
        return code == 0
    }

    private func removeAgent() {
        guard FileManager.default.fileExists(atPath: agentPlistURL.path) else { return }
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentPlistURL)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
