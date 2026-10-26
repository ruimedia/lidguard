// lidguard-probe —— LidGuard 检测核心（无 UI 版）
//
// 用途：在做任何 UI 之前，先验证「电源 / 电量 / 温度 / agent 活跃度 / 统计」这些数据
//       到底能不能从系统里稳定采到。采不到的东西不应该出现在界面上。
//
// 判定规则（每个 agent 独立）：
//   1. 进程不在            → notRunning（不参与任何计算）
//   2. 进程在 + 活跃文件近 N 秒内有写入 → busy（强信号）
//   3. 进程在 + CPU 时间增量超过阈值     → busy（弱信号，仅作补充）
//   4. 进程在但都没信号     → idle
//
// 编译： swiftc -O probe.swift -o lidguard-probe

import Foundation
import IOKit.ps
import Darwin

// MARK: - 采集结果模型

struct AgentState: Codable {
    var name: String
    var running: Bool
    var state: String        // busy / idle / notRunning
    var level: Int           // 0-4 电平
    var cpuSeconds: Double   // 本次采样窗口内消耗的 CPU 秒数
    var lastActivityAt: Date? // 最近的活跃文件写入时间
    var detail: String       // 给界面看的说明
}

struct SystemState {
    var onAC: Bool
    var batteryPercent: Int
    var isCharging: Bool
    var thermal: String      // nominal / fair / serious / critical
    var thermalCN: String
    var sleepDisabled: Bool
}

struct Snapshot: Codable {
    var timestamp: Date
    var system: SystemSnapshot
    var agents: [AgentState]
}

struct SystemSnapshot: Codable {
    var onAC: Bool
    var batteryPercent: Int
    var isCharging: Bool
    var thermal: String
    var sleepDisabled: Bool
}

// MARK: - Agent 配置

struct AgentSpec {
    let name: String
    // 进程命令行中包含任一关键字即视为「在运行」
    let processHints: [String]
    // 活跃信号文件；目录会按 maxDepth 向下找最近修改的文件
    let activityPaths: [String]
    // 该路径下，多久内的写入算「活跃」
    let freshSeconds: Int

    init(_ name: String, hints: [String], paths: [String], fresh: Int = 90, depth: Int = 2) {
        self.name = name
        self.processHints = hints
        self.activityPaths = paths
        self.freshSeconds = fresh
        self.depth = depth
    }
    let depth: Int
}

var home: String { NSHomeDirectory() }

var agentSpecs: [AgentSpec] {
    [
        AgentSpec("MiniMax Code",
                  hints: ["/MiniMax Code.app/"],
                  paths: [home + "/.minimax/sessions"], fresh: 75, depth: 2),
        AgentSpec("WorkBuddy",
                  hints: ["/WorkBuddy.app/"],
                  paths: [home + "/.workbuddy/logs"], fresh: 75, depth: 1),
        AgentSpec("Codex",
                  hints: ["/.codex/bin/", "/codex"],
                  paths: [home + "/.codex/thread_history_1.sqlite",
                          home + "/.codex/state_5.sqlite",
                          home + "/.codex/logs_2.sqlite"],
                  fresh: 120, depth: 0),
        AgentSpec("Claude Code",
                  hints: ["/.claude/", "/claude"],
                  paths: [home + "/.claude/projects"], fresh: 90, depth: 3),
        AgentSpec("OpenCode",
                  hints: ["/opencode"],
                  paths: [home + "/.opencode", home + "/.local/share/opencode"],
                  fresh: 120, depth: 3),
        AgentSpec("Cursor",
                  hints: ["/Cursor.app/"],
                  paths: [home + "/Library/Application Support/Cursor/User/workspaceStorage"],
                  fresh: 90, depth: 3),
        // Muse（Meta，bundle id com.meta.endo）：analytics 事件库上传后即清空，
        // device-v1.json 会自己停摆；最稳的是 preferences plist（约 30 秒写一次）。
        AgentSpec("Muse",
                  hints: ["/Muse.app/"],
                  paths: [home + "/Library/Preferences/com.meta.endo.plist",
                          home + "/Library/Caches/com.meta.endo/AuthRollout/com.meta.endo/device-v1.json",
                          home + "/Library/Application Support/com.meta.endo/analytics/unified_micro_batch"],
                  fresh: 180, depth: 1)
    ]
}

// MARK: - 进程工具

struct ProcEntry {
    let pid: pid_t
    let command: String
    let cpuTotal: Double   // 自启动以来的累计 CPU 秒数
}

/// 解析 ps 的 TIME 字段，支持 MM:SS.ss / HH:MM:SS.ss / DD-HH:MM:SS.ss
func parsePSTime(_ s: String) -> Double {
    var work = s.trimmingCharacters(in: .whitespaces)
    var days = 0.0
    if let dash = work.firstIndex(of: "-") {
        days = (Double(work[work.startIndex..<dash]) ?? 0) * 86400
        work = String(work[work.index(after: dash)...])
    }
    // 注意：天数要单独累加，不能混进下面的乘 60 累乘，否则基数会被反复放大
    var clock = 0.0
    for seg in work.split(separator: ":") {
        clock = clock * 60 + (Double(seg) ?? 0)
    }
    return days + clock
}

/// 一次 ps 调用同时拿到进程列表 + 累计 CPU 时间。
/// 注意：此前用 proc_pid_rusage(RUSAGE_INFO_V2) 读取，实测数值比 ps 的 TIME 少约 33 倍，
///       与 ps 交叉验证不一致，故改为直接解析 ps 输出。
func runningProcesses() -> [ProcEntry] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "pid=,time=,command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)

    return text.split(separator: "\n").compactMap { line -> ProcEntry? in
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true,
                                whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 3, let pid = pid_t(parts[0]) else { return nil }
        return ProcEntry(pid: pid, command: String(parts[2]),
                         cpuTotal: parsePSTime(String(parts[1])))
    }
}

// MARK: - 文件活跃度

/// 返回 paths 下最近一次写入的时间；maxDepth 控制向下搜索深度，避免遍历大树
func newestModification(paths: [String], maxDepth: Int) -> Date? {
    var newest: Date? = nil
    let fm = FileManager.default
    var visited = 0
    let budget = 20_000   // 最多访问 2 万个条目，防止卡住

    for root in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else { continue }

        if !isDir.boolValue {
            let a = try? fm.attributesOfItem(atPath: root)
            if let m = a?[.modificationDate] as? Date, m > (newest ?? .distantPast) {
                newest = m
            }
            continue
        }

        let rootURL = URL(fileURLWithPath: root)
        guard let walker = fm.enumerator(at: rootURL,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { continue }
        let rootPath = rootURL.standardizedFileURL.path
        while let obj = walker.nextObject() {
            visited += 1
            if visited > budget { break }
            guard let u = obj as? URL else { continue }
            let full = u.standardizedFileURL.path
            let rel = full.count > rootPath.count
                ? String(full.dropFirst(rootPath.count + 1)) : ""
            let depth = rel.reduce(into: 0) { c, ch in if ch == "/" { c += 1 } }
            let values = try? u.resourceValues(forKeys: [.contentModificationDateKey])
            if let m = values?.contentModificationDate, m > (newest ?? .distantPast) {
                newest = m
            }
            if depth + 1 > maxDepth { walker.skipDescendants() }
        }
    }
    return newest
}

// MARK: - 系统状态

func readSystemState() -> SystemState {
    // 电源来源
    // 注意：本机（Apple Silicon）实测 IOPSCopyPowerSourcesList 只返回一个描述符
    //   Type=InternalBattery，AC 适配器根本不在列表里，因此 IOKit 这条路采不到电源类型。
    //   改用 pmset -g ps 判断，已交叉验证与 pmset 输出一致。
    let onAC = runCapture("/usr/bin/pmset", ["-g", "ps"])
        .contains { $0.contains("'AC Power'") }

    // 电量（InternalBattery 描述符可用）
    let src = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(src).takeRetainedValue() as Array
    var percent = -1
    var charging = false
    for desc in list {
        guard let d = IOPSGetPowerSourceDescription(src, desc)?.takeUnretainedValue() as? [String: Any] else { continue }
        if let cur = d[kIOPSCurrentCapacityKey] as? Int,
           let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = Int(Double(cur) / Double(max) * 100.0)
        }
        if let isCh = d[kIOPSIsChargingKey] as? Bool { charging = isCh }
    }

    // 温度
    let t = ProcessInfo.processInfo.thermalState
    let name: String
    let cn: String
    switch t {
    case .nominal:  (name, cn) = ("nominal", "正常")
    case .fair:     (name, cn) = ("fair", "偏高")
    case .serious:  (name, cn) = ("serious", "严重")
    case .critical: (name, cn) = ("critical", "危险")
    @unknown default: (name, cn) = ("unknown", "未知")
    }

    // 是否禁止睡眠
    let sleepDisabled = runCapture("/usr/bin/pmset", ["-g"])
        .contains { $0.contains("SleepDisabled") && $0.contains("1") }

    return SystemState(onAC: onAC, batteryPercent: percent, isCharging: charging,
                       thermal: name, thermalCN: cn, sleepDisabled: sleepDisabled)
}

func runCapture(_ path: String, _ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return [] }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
}

// MARK: - agent 探测

/// cpuCache: 上一次采样时各 PID 的 CPU 累计时间，用于算增量
func probeAgents(procs: [ProcEntry],
                 cpuCache: inout [pid_t: Double]) -> [AgentState] {
    var out: [AgentState] = []
    let now = Date()

    for spec in agentSpecs {
        // 找到匹配的进程
        let matched = procs.filter { p in
            spec.processHints.contains { p.command.contains($0) }
        }
        guard !matched.isEmpty else {
            out.append(AgentState(name: spec.name, running: false, state: "notRunning",
                                  level: 0, cpuSeconds: 0, lastActivityAt: nil,
                                  detail: "未检测到进程"))
            continue
        }

        // CPU 增量
        var cpuDelta = 0.0
        for p in matched {
            if let prev = cpuCache[p.pid] { cpuDelta += max(0, p.cpuTotal - prev) }
            cpuCache[p.pid] = p.cpuTotal
        }

        // 活跃文件
        let newest = newestModification(paths: spec.activityPaths, maxDepth: spec.depth)
        let age = newest.map { now.timeIntervalSince($0) }
        let fileFresh = (age ?? .infinity) <= Double(spec.freshSeconds)

        // 判定
        var state = "idle"
        var level = 1
        var detail = "进程在运行，暂无新活动"
        if fileFresh {
            state = "busy"; level = 4
            detail = "检测到日志/会话文件 \(Int(age ?? 0)) 秒前有写入"
        } else if cpuDelta > 1.5 {
            state = "busy"; level = 3
            detail = String(format: "CPU 本次消耗 %.1fs", cpuDelta)
        } else if cpuDelta > 0.3 {
            state = "busy"; level = 2
            detail = String(format: "CPU 本次消耗 %.1fs", cpuDelta)
        } else if let a = age, a < 600 {
            detail = String(format: "最近活动在 %d 分钟前", Int(a / 60))
        } else {
            level = 0
            detail = "进程在运行，但看起来是空闲的"
        }

        out.append(AgentState(name: spec.name, running: true, state: state,
                              level: level, cpuSeconds: cpuDelta,
                              lastActivityAt: newest, detail: detail))
    }
    return out
}

// MARK: - 统计

struct SessionRecord: Codable {
    var startedAt: Date
    var endedAt: Date?
    var agentSeconds: [String: Double] = [:]
}

struct Stats: Codable {
    var sessions: [SessionRecord] = []
}

var statsDir: String {
    let d = home + "/Library/Application Support/LidGuard"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func loadStats() -> Stats {
    let path = statsDir + "/stats.json"
    guard let d = FileManager.default.contents(atPath: path) else { return Stats() }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601   // 必须与 saveStats 的 encoding 策略一致
    do { return try dec.decode(Stats.self, from: d) }
    catch {
        FileHandle.standardError.write("lidguard-probe: stats.json 解析失败 -> \(error.localizedDescription)\n".data(using: .utf8)!)
        return Stats()
    }
}

func saveStats(_ s: Stats) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(s) {
        try? d.write(to: URL(fileURLWithPath: statsDir + "/stats.json"))
    }
}

func summary(_ s: Stats) -> (count: Int, total: Double, today: Double) {
    let cal = Calendar.current
    let now = Date()
    var total: Double = 0
    var today: Double = 0
    for s in s.sessions {
        let end = s.endedAt ?? now
        let dur = end.timeIntervalSince(s.startedAt)
        total += dur
        if cal.isDate(s.startedAt, inSameDayAs: now) { today += dur }
    }
    return (s.sessions.count, total, today)
}

/// print 到文件时是块缓冲的，进程被 kill 时缓冲会丢失，这里强制逐行刷新
func emit(_ s: String) {
    print(s)
    fflush(stdout)
}

func fmtDur(_ sec: Double) -> String {
    let h = Int(sec) / 3600, m = (Int(sec) % 3600) / 60
    return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分"
}

// MARK: - CLI

func snapshotJSON(_ sys: SystemState, _ ags: [AgentState]) -> String {
    let s = SystemSnapshot(onAC: sys.onAC, batteryPercent: sys.batteryPercent,
                           isCharging: sys.isCharging, thermal: sys.thermal,
                           sleepDisabled: sys.sleepDisabled)
    let snap = Snapshot(timestamp: Date(), system: s, agents: ags)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    guard let d = try? enc.encode(snap) else { return "{}" }
    return String(decoding: d, as: UTF8.self)
}

func printHuman(sys: SystemState, ags: [AgentState]) {
    print("════════════════════════════════════════")
    print(" LidGuard 检测快照  \(ISO8601DateFormatter().string(from: Date()))")
    print("════════════════════════════════════════")
    print("")
    print("【系统】")
    print("  电源      : \(sys.onAC ? "已接通电源 (AC)" : "电池供电")")
    print("  电量      : \(sys.batteryPercent)% \(sys.isCharging ? "(充电中)" : "")")
    print("  温度      : \(sys.thermalCN) / \(sys.thermal)")
    print("  禁用睡眠  : \(sys.sleepDisabled ? "是" : "否")")
    print("")
    print("【AI Agent】")
    for a in ags {
        let icon: String
        let color: String
        switch a.state {
        case "busy":       icon = "●"; color = "\u{1B}[32m"
        case "idle":       icon = "●"; color = "\u{1B}[33m"
        default:           icon = "○"; color = "\u{1B}[90m"
        }
        let bars = ["▁","▂","▃","▄","▅"][min(a.level,4)] + "▁▁▁".dropFirst(min(a.level,4)).map{_ in ""}.joined() + String(repeating: "·", count: 4 - a.level)
        let label: String
        switch a.state {
        case "busy":  label = "活跃"
        case "idle":  label = "空闲"
        default:      label = "未运行"
        }
        print(String(format: "  %@%@ %-14@ %@ %-6@ CPU %5.1fs",
                     color, icon, a.name, color, label, a.cpuSeconds))
        print("             电平 \(bars)  \(a.detail)")
    }
    print("")
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "snapshot"

switch cmd {

case "snapshot":
    var cache: [pid_t: Double] = [:]
    let procs = runningProcesses()
    _ = probeAgents(procs: procs, cpuCache: &cache)   // 第一趟只建立 CPU 基线
    Thread.sleep(forTimeInterval: 3)
    let ags = probeAgents(procs: procs, cpuCache: &cache)  // 第二趟才有增量
    let sys = readSystemState()
    printHuman(sys: sys, ags: ags)
    print("【JSON】")
    print(snapshotJSON(sys, ags))

case "watch":
    // 连续采样，每 5 秒更新一次 CPU 增量
    let interval: Double = args.count > 1 ? (Double(args[1]) ?? 5) : 5
    var cache: [pid_t: Double] = [:]
    var stats = loadStats()
    var openSession: SessionRecord? = nil
    var lastTick = Date()

    print("开始持续采样，每 \(Int(interval)) 秒一次。Ctrl-C 结束。")
    while true {
        let sys = readSystemState()
        let procs = runningProcesses()
        let ags = probeAgents(procs: procs, cpuCache: &cache)
        let now = Date()
        let dt = now.timeIntervalSince(lastTick); lastTick = now

        // 记录会话
        if sys.sleepDisabled {
            if openSession == nil {
                openSession = SessionRecord(startedAt: now)
                emit("→ 开始守护会话")
            }
            var s = openSession!
            for a in ags where a.state == "busy" {
                s.agentSeconds[a.name, default: 0] += dt
            }
            openSession = s
        } else if openSession != nil {
            var s = openSession!
            s.endedAt = now
            stats.sessions.append(s)
            saveStats(stats)
            emit("→ 结束守护会话，本次 \(fmtDur(now.timeIntervalSince(s.startedAt)))")
            openSession = nil
        }

        let busy = ags.filter { $0.state == "busy" }.map(\.name).joined(separator: ", ")
        emit(String(format: "[%@] %@ | %d%% | %@ | 活跃: %@",
                     String(ISO8601DateFormatter().string(from: now).suffix(8)),
                     sys.onAC ? "AC" : "DC", sys.batteryPercent,
                     sys.sleepDisabled ? "禁睡中" : "正常睡眠",
                     busy.isEmpty ? "无" : busy))
        Thread.sleep(forTimeInterval: interval)
    }

case "stats":
    let s = loadStats()
    let (c, total, today) = summary(s)
    print("════════════════════════════════════════")
    print(" 累计守护统计")
    print("════════════════════════════════════════")
    print("  守护次数    : \(c)")
    print("  累计时长    : \(fmtDur(total))")
    print("  今日时长    : \(fmtDur(today))")
    print("")
    print("  最近 10 次会话：")
    for sess in s.sessions.suffix(10).reversed() {
        let end = sess.endedAt ?? Date()
        let d = fmtDur(end.timeIntervalSince(sess.startedAt))
        let agents = sess.agentSeconds
            .filter { $0.value > 30 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \(fmtDur($0.value))" }
            .joined(separator: " · ")
        let mark = sess.endedAt == nil ? " (进行中)" : ""
        print("    \(sess.startedAt.formatted(date: .abbreviated, time: .shortened))  \(d)\(mark)")
        print("      \(agents.isEmpty ? "无活跃 agent" : agents)")
    }
    print("")

case "reset":
    try? FileManager.default.removeItem(atPath: statsDir + "/stats.json")
    print("统计已清空")

default:
    print("用法: lidguard-probe snapshot | watch [间隔秒] | stats | reset")
}