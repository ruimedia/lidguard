import SwiftUI
import AppKit

@main
struct LidGuardApp: App {
    @StateObject private var monitor = Monitor()
    @State private var showStats = false

    var body: some Scene {
        // .window 样式才能做出设计稿里的卡片面板，而不是普通下拉菜单
        MenuBarExtra {
            PanelView()
                .environmentObject(monitor)
                .onAppear { monitor.start() }
        } label: {
            // 菜单栏图标：合盖的笔记本 + 状态点；离开久了显示时长角标
            HStack(spacing: 2) {
                Image(systemName: "macbook")
                if !monitor.badge.isEmpty {
                    Text(monitor.badge)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}