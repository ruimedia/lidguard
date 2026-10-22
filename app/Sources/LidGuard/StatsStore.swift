import Foundation

/// 统计存档（纯本地，不联网）
final class StatsStore {
    static let shared = StatsStore()
    private let fm = FileManager.default

    var dir: String {
        let d = fm.homeDirectoryForCurrentUser.path + "/Library/Application Support/LidGuard"
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    var file: String { dir + "/stats.json" }

    func load() -> Stats {
        guard let d = fm.contents(atPath: file) else { return Stats() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // 必须与 save 的 encoding 策略一致
        return (try? dec.decode(Stats.self, from: d)) ?? Stats()
    }

    func save(_ s: Stats) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(s) else { return }
        try? d.write(to: URL(fileURLWithPath: file))
    }

    func reset() { try? fm.removeItem(atPath: file) }
}

// MARK: - 武装状态（与 root 守护进程 lidguard 共享的文件通道）

/// 界面是用户级进程，没有 root 权限。
/// 真正执行 pmset 的是 /usr/local/bin/lidguard 的 root 守护进程，
/// 这里只负责写/读标记文件，由守护进程读取并执行。
struct ArmState {
    let home: String
    var dir: String { home + "/.lidguard" }
    var armFile: String { dir + "/armed" }
    var sleepnowFile: String { dir + "/sleepnow" }

    init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
    }

    var isArmed: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: armFile),
              let m = a[.modificationDate] as? Date else { return false }
        let age = Date().timeIntervalSince(m)
        return age >= 0 && age <= budget
    }

    /// 本次武装设置的时间预算（秒）
    var budget: Double {
        guard let s = try? String(contentsOfFile: armFile, encoding: .utf8),
              let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              v > 0 else { return 0 }
        return v
    }

    /// 剩余秒数
    var remaining: Double {
        guard let a = try? FileManager.default.attributesOfItem(atPath: armFile),
              let m = a[.modificationDate] as? Date else { return 0 }
        return max(0, budget - Date().timeIntervalSince(m))
    }

    /// 已武装时长
    var elapsed: Double {
        guard let a = try? FileManager.default.attributesOfItem(atPath: armFile),
              let m = a[.modificationDate] as? Date else { return 0 }
        return max(0, Date().timeIntervalSince(m))
    }

    func arm(hours: Double) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? String(Int(hours * 3600)).write(toFile: armFile, atomically: true, encoding: .utf8)
    }

    func disarm() {
        try? FileManager.default.removeItem(atPath: armFile)
    }

    /// 「立即休眠」：pmset sleepnow 需要 root，故写标记交给守护进程执行
    func requestSleepNow() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data().write(to: URL(fileURLWithPath: sleepnowFile))
    }
}