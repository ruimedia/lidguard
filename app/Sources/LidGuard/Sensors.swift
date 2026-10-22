import Foundation
import IOKit.ps

// MARK: - 命令执行

@discardableResult
func runCapture(_ path: String, _ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return [] }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
}

// MARK: - 进程

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
    // 天数单独累加，不能混进下面的乘 60 累乘
    var clock = 0.0
    for seg in work.split(separator: ":") {
        clock = clock * 60 + (Double(seg) ?? 0)
    }
    return days + clock
}

/// 一次 ps 调用同时拿到进程列表 + 累计 CPU 时间。
/// 说明：曾用 proc_pid_rusage(RUSAGE_INFO_V2)，实测数值比 ps 的 TIME 少约 33 倍，
/// 与 ps 交叉验证不一致，故改为解析 ps 输出。
func runningProcesses() -> [ProcEntry] {
    let out = runCapture("/bin/ps", ["-Ao", "pid=,time=,command="])
    return out.compactMap { line in
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true,
                               whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 3, let pid = pid_t(parts[0]) else { return nil }
        return ProcEntry(pid: pid, command: String(parts[2]),
                         cpuTotal: parsePSTime(String(parts[1])))
    }
}

// MARK: - 文件活跃度

/// 返回 paths 下最近一次写入的时间；maxDepth 控制搜索深度，避免遍历大树
func newestModification(paths: [String], maxDepth: Int) -> Date? {
    var newest: Date?
    let fm = FileManager.default
    var visited = 0
    let budget = 20_000

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

func readSystemState() -> SystemSnapshot {
    // 电源来源：Apple Silicon 上 IOPSCopyPowerSourcesList 只返回 InternalBattery，
    // AC 适配器不在其中，必须走 pmset -g ps（已与 pmset 输出交叉验证一致）。
    let onAC = runCapture("/usr/bin/pmset", ["-g", "ps"])
        .contains { $0.contains("'AC Power'") }

    // 电量
    let src = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(src).takeRetainedValue() as Array
    var percent = -1
    var charging = false
    for desc in list {
        guard let d = IOPSGetPowerSourceDescription(src, desc)?
                .takeUnretainedValue() as? [String: Any] else { continue }
        if let cur = d[kIOPSCurrentCapacityKey] as? Int,
           let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = Int(Double(cur) / Double(max) * 100.0)
        }
        if let isCh = d[kIOPSIsChargingKey] as? Bool { charging = isCh }
    }

    // 温度
    let t = ProcessInfo.processInfo.thermalState
    let raw: String, cn: String
    switch t {
    case .nominal:  (raw, cn) = ("nominal", "正常")
    case .fair:     (raw, cn) = ("fair", "偏高")
    case .serious:  (raw, cn) = ("serious", "严重")
    case .critical: (raw, cn) = ("critical", "危险")
    @unknown default: (raw, cn) = ("unknown", "未知")
    }

    // 是否禁止睡眠
    let disabled = runCapture("/usr/bin/pmset", ["-g"])
        .contains { $0.contains("SleepDisabled") && $0.contains("1") }

    return SystemSnapshot(onAC: onAC, batteryPercent: percent, isCharging: charging,
                          thermalRaw: raw, thermalLabel: cn, sleepDisabled: disabled)
}

// MARK: - Agent 探测

/// cpuCache 保存上一轮各 PID 的累计 CPU 时间，用于算本轮增量
func probeAgents(specs: [AgentSpec],
                 procs: [ProcEntry],
                 cpuCache: inout [pid_t: Double],
                 sessionSeconds: [String: Double] = [:]) -> [AgentState] {
    var out: [AgentState] = []
    let now = Date()

    for spec in specs {
        let matched = procs.filter { p in spec.processHints.contains { p.command.contains($0) } }

        guard !matched.isEmpty else {
            out.append(AgentState(name: spec.name, state: .notRunning, level: 0,
                                  cpuSeconds: 0, lastActivityAt: nil, detail: "未检测到进程"))
            continue
        }

        var cpuDelta = 0.0
        for p in matched {
            if let prev = cpuCache[p.pid] { cpuDelta += max(0, p.cpuTotal - prev) }
            cpuCache[p.pid] = p.cpuTotal
        }

        let newest = newestModification(paths: spec.activityPaths, maxDepth: spec.maxDepth)
        let age = newest.map { now.timeIntervalSince($0) }
        let fileFresh = (age ?? .infinity) <= Double(spec.freshSeconds)

        var state = ActivityState.idle
        var level = 1
        var detail = "进程在运行，暂无新活动"
        if fileFresh {
            state = .busy; level = 4
            detail = "日志/会话文件 \(Int(age ?? 0)) 秒前有写入"
        } else if cpuDelta > 1.5 {
            state = .busy; level = 3
            detail = String(format: "CPU 本轮消耗 %.1fs", cpuDelta)
        } else if cpuDelta > 0.3 {
            state = .busy; level = 2
            detail = String(format: "CPU 本轮消耗 %.1fs", cpuDelta)
        } else if let a = age, a < 600 {
            detail = "最近活动在 \(Int(a / 60)) 分钟前"
        } else {
            level = 0
            detail = "进程在运行，但看起来是空闲的"
        }

        var st = AgentState(name: spec.name, state: state, level: level,
                            cpuSeconds: cpuDelta, lastActivityAt: newest, detail: detail)
        st.sessionActiveSeconds = sessionSeconds[spec.name] ?? 0
        out.append(st)
    }
    return out
}