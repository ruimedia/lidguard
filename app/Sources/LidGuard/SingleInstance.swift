import Foundation
import Darwin

/// 单实例保护。
///
/// 开机自启 + 用户手动点开是最典型的双开来源：登录项把 App 拉起来，
/// 用户又从「应用程序」点了一次。两个实例会各自建一套菜单栏状态项、
/// 各自跑 5 秒轮询、写同一个统计文件，结果是菜单栏出现两个图标、
/// 统计数据互相覆盖、面板里的数字在跳。
///
/// 这里用 flock 在用户目录里放一把排他锁：拿到锁的进程才是主实例；
/// 拿不到就直接退出，同时把已经在跑的那个叫醒，让用户点一下就能看到面板。
///
/// 注意锁文件不能删：flock 是对「文件描述符」上的 advisory 锁，
/// 进程退出时内核自动释放，所以这里只需要保证文件存在即可。
final class SingleInstance {
    static let shared = SingleInstance()

    private var fd: Int32 = -1
    private(set) var isPrimary = true

    private static let lockPath: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock").path
    }()

    /// 返回 true = 本进程是主实例；false = 已经有实例在跑，调用方应当退出。
    func acquire() -> Bool {
        let path = Self.lockPath
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // 连锁文件都建不出来（用户目录只读、沙盒限制等），
            // 此时不能因为这个就把 App 拦死——退化成允许多开，好过起不来。
            isPrimary = true
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fd = -1
            isPrimary = false
            return false
        }
        isPrimary = true
        return true
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
