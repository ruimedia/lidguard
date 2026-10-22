import Foundation
import Combine

@MainActor
final class Monitor: ObservableObject {
    @Published var system = SystemSnapshot(onAC: false, batteryPercent: -1,
                                          isCharging: false, thermalRaw: "unknown",
                                          thermalLabel: "未知", sleepDisabled: false)
    @Published var agents: [AgentState] = []
    @Published var stats = Stats()
    @Published var isArmed = false
    @Published var remaining: Double = 0
    @Published var elapsed: Double = 0
    /// 菜单栏角标：离开超过 2 分钟才显示摘要，避免短时间打扰
    @Published var badge: String = ""

    /// 最近一次离开时长（用于角标）。由显示层根据内部显示休眠状态推断。
    @Published var lastAwaySeconds: Double = 0

    private let specs = AgentSpecs.all()
    private let store = StatsStore.shared
    private let arm = ArmState()
    private var cpuCache: [pid_t: Double] = [:]
    private var openSession: SessionRecord?
    private var lastTick = Date()
    private let queue = DispatchQueue(label: "com.lidguard.sensing", qos: .utility)
    private var timer: AnyCancellable?

    /// 启动自动采样
    func start() {
        var stats = store.load()
        // 上次退出时若有未结束的会话，补上结束时间，避免统计被撑大
        if let s = stats.sessions.last, s.endedAt == nil {
            stats.sessions[stats.sessions.count - 1].endedAt = s.startedAt
            store.save(stats)
        }
        self.stats = stats

        refresh()
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let armSnapshot: (isArmed: Bool, remaining: Double, elapsed: Double) =
            (arm.isArmed, arm.remaining, arm.elapsed)

        // 采样放到后台，避免阻塞界面
        queue.async { [specs, cpuBox] in
            var cache = cpuBox.value
            let procs = runningProcesses()
            let sys = readSystemState()
            let ags = probeAgents(specs: specs, procs: procs, cpuCache: &cache)
            cpuBox.value = cache
            Task { @MainActor [weak self] in
                self?.apply(sys: sys, ags: ags, dt: dt, arm: armSnapshot)
            }
        }
    }

    private let cpuBox = CPUBox()

    private func apply(sys: SystemSnapshot, ags: [AgentState], dt: Double,
                       arm: (isArmed: Bool, remaining: Double, elapsed: Double)) {
        system = sys
        isArmed = arm.isArmed
        remaining = arm.remaining
        elapsed = arm.elapsed

        // 会话统计：仅在真正禁睡（守护进程已生效）时累计
        if sys.sleepDisabled {
            if openSession == nil {
                openSession = SessionRecord(startedAt: Date())
            }
            var s = openSession!
            for a in ags where a.state == .busy {
                s.agentSeconds[a.name, default: 0] += dt
            }
            openSession = s
        } else if openSession != nil {
            var s = openSession!
            s.endedAt = Date()
            stats.sessions.append(s)
            store.save(stats)
            openSession = nil
        }

        // 补上本次会话内各 agent 的累计活跃时长
        var result = ags
        if let s = openSession {
            for i in result.indices {
                result[i].sessionActiveSeconds = s.agentSeconds[result[i].name] ?? 0
            }
        }
        agents = result

        // 角标：只在有实质离开时长时显示，避免平时一直挂个字
        if sys.sleepDisabled && elapsed > 120 {
            badge = Fmt.short(elapsed)
        } else {
            badge = ""
        }
    }

    // MARK: - 用户操作

    func setArmed(_ on: Bool, hours: Double) {
        if on { arm.arm(hours: hours) } else { arm.disarm() }
        isArmed = arm.isArmed
        remaining = arm.remaining
        elapsed = arm.elapsed
        refresh()
    }

    func sleepNow() { arm.requestSleepNow() }
    func resetStats() { store.reset(); stats = Stats() }
}

/// 线程安全的缓存盒（采样在后台线程，读写在主线程）
final class CPUBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [pid_t: Double] = [:]
    var value: [pid_t: Double] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}