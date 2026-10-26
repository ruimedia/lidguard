import Foundation

// MARK: - Agent 配置

struct AgentSpec: Identifiable {
    let id = UUID()
    let name: String
    /// 进程命令行包含任一关键字即视为「在运行」。
    /// 注意：Electron 类应用（WorkBuddy / MiniMax Code）真正干活的是 renderer/helper 子进程，
    /// 因此这里匹配整个 .app bundle 路径，而不是主进程二进制路径。
    let processHints: [String]
    let activityPaths: [String]
    /// 该路径下，多久内的写入算「活跃」
    let freshSeconds: Int
    let maxDepth: Int

    init(_ name: String, hints: [String], paths: [String], fresh: Int = 90, depth: Int = 2) {
        self.name = name
        self.processHints = hints
        self.activityPaths = paths
        self.freshSeconds = fresh
        self.maxDepth = depth
    }
}

enum AgentSpecs {
    static func all() -> [AgentSpec] {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            AgentSpec("MiniMax Code",
                      hints: ["/MiniMax Code.app/"],
                      paths: [h + "/.minimax/sessions"], fresh: 75, depth: 2),
            AgentSpec("WorkBuddy",
                      hints: ["/WorkBuddy.app/"],
                      paths: [h + "/.workbuddy/logs"], fresh: 75, depth: 1),
            AgentSpec("Codex",
                      hints: ["/.codex/bin/", "/codex"],
                      paths: [h + "/.codex/thread_history_1.sqlite",
                              h + "/.codex/state_5.sqlite",
                              h + "/.codex/logs_2.sqlite"],
                      fresh: 120, depth: 0),
            AgentSpec("Claude Code",
                      hints: ["/.claude/", "/claude"],
                      paths: [h + "/.claude/projects"], fresh: 90, depth: 3),
            AgentSpec("OpenCode",
                      hints: ["/opencode"],
                      paths: [h + "/.opencode", h + "/.local/share/opencode"],
                      fresh: 120, depth: 3),
            AgentSpec("Cursor",
                      hints: ["/Cursor.app/"],
                      paths: [h + "/Library/Application Support/Cursor/User/workspaceStorage"],
                      fresh: 90, depth: 3),
            // Muse（Meta 出品，bundle id com.meta.endo）
            //
            // 活动信号挑了两轮才挑对，这里把踩过的坑记下来：
            //
            // 1) analytics 的事件库（FBAnalyticsUnifiedEventStore）看着最像
            //    「用户交互日志」，但 analytics_events 表长期是 0 行——事件上传成功后
            //    就被清掉了。只剩 WAL 文件偶尔的一次性时间戳，当判据只会得到死数字。
            //
            // 2) AuthRollout 里的 device-v1.json 前 35 分钟确实是标准心跳（约 61 秒一次），
            //    但实测它会自己停摆（连续 8 分钟不再写入），不能单独依赖。
            //
            // 3) 真正稳定的是 ~/Library/Preferences/com.meta.endo.plist：
            //    Muse 进程在跑时约每 30 秒写一次（cfprefsd 代写），进程一停就停。
            //
            // 所以以 prefs 为主判据，device-v1.json 与 analytics 目录作为兜底，
            // 任一有近期写入都算「活着」。
            AgentSpec("Muse",
                      hints: ["/Muse.app/"],
                      paths: [h + "/Library/Preferences/com.meta.endo.plist",
                              h + "/Library/Caches/com.meta.endo/AuthRollout/com.meta.endo/device-v1.json",
                              h + "/Library/Application Support/com.meta.endo/analytics/unified_micro_batch"],
                      fresh: 180, depth: 1)
        ]
    }
}

// MARK: - 状态模型

enum ActivityState: String {
    case busy, idle, notRunning

    var label: String {
        switch self {
        case .busy:       return "活跃"
        case .idle:       return "空闲"
        case .notRunning: return "未运行"
        }
    }
}

struct AgentState: Identifiable {
    var id: String { name }
    let name: String
    let state: ActivityState
    let level: Int            // 0-4
    let cpuSeconds: Double
    let lastActivityAt: Date?
    let detail: String
    /// 本次守护会话中该 agent 累计活跃秒数
    var sessionActiveSeconds: Double = 0
}

struct SystemSnapshot {
    var onAC: Bool
    var batteryPercent: Int
    var isCharging: Bool
    var thermalRaw: String
    var thermalLabel: String
    var sleepDisabled: Bool
}

// MARK: - 统计模型

struct SessionRecord: Codable {
    var startedAt: Date
    var endedAt: Date?
    var agentSeconds: [String: Double] = [:]
}

struct Stats: Codable {
    var sessions: [SessionRecord] = []

    var totalCount: Int { sessions.count }
    var totalSeconds: Double {
        let now = Date()
        return sessions.reduce(0) { $0 + ($1.endedAt ?? now).timeIntervalSince($1.startedAt) }
    }
    var todaySeconds: Double {
        let cal = Calendar.current, now = Date()
        return sessions.filter { cal.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + ($1.endedAt ?? now).timeIntervalSince($1.startedAt) }
    }
}

// MARK: - 格式化

enum Fmt {
    static func duration(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分"
    }

    static func short(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }
}