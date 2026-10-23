import AppKit
import Storage

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var monitor: MihomoMonitorController!
    private var statsWindowController: StatsWindowController?
    private var store: TrafficStore!
    private var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("AppTrafficMonitor", isDirectory: true)
        do {
            store = try TrafficStore(url: supportDir.appendingPathComponent("traffic.sqlite"))
        } catch {
            // 数据库不可用时无法承担统计职责：弹窗说明并退出，不伪装正常运行
            let alert = NSAlert()
            alert.messageText = "无法打开流量数据库"
            alert.informativeText = "\(String(describing: error))\n路径：\(supportDir.path)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        monitor = MihomoMonitorController(store: store)
        monitor.onTick = { [weak self] status in
            self?.updateStatusUI(status)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.button?.image = NSImage(systemSymbolName: "arrow.up.arrow.down",
                                     accessibilityDescription: "AppTrafficMonitor")
        item.menu = buildMenu()
        statusItem = item

        monitor.start()

        // 自测/演示入口：--show-stats 启动即打开统计窗口；--show-charts 直达统计图页签
        if CommandLine.arguments.contains("--show-stats") || CommandLine.arguments.contains("--show-charts") {
            openStats()
            if CommandLine.arguments.contains("--show-charts") {
                statsWindowController?.selectChartsTab()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stopAndFlush()
    }

    // MARK: - 菜单栏

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "AppTrafficMonitor")
        menu.autoenablesItems = false

        let stats = NSMenuItem(title: "打开统计", action: #selector(openStats), keyEquivalent: "s")
        stats.target = self
        let pause = NSMenuItem(title: "暂停采集", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.tag = 100

        let statusLine = NSMenuItem(title: "正在连接 Mihomo…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.tag = 200

        let usageLine = NSMenuItem(title: "今日代理：—", action: nil, keyEquivalent: "")
        usageLine.isEnabled = false
        usageLine.tag = 201

        let quit = NSMenuItem(title: "退出 AppTrafficMonitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        menu.items = [stats, pause, .separator(), statusLine, usageLine, .separator(), quit]
        return menu
    }

    private func updateStatusUI(_ status: MihomoMonitorController.LiveStatus) {
        guard let button = statusItem?.button, let menu = statusItem?.menu else { return }

        switch status.status {
        case .running:
            button.image = nil
            button.title = "↑\(Self.rate(status.proxyUpRate)) ↓\(Self.rate(status.proxyDownRate))"
        case .paused:
            button.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已暂停")
            button.title = ""
        case .unavailable:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                   accessibilityDescription: "不可用")
            button.title = ""
        case .connecting:
            button.title = "…"
        }

        if let item = menu.item(withTag: 200) {
            switch status.status {
            case .running:
                item.title = "采集中（1 秒快照 · Clash 已观测口径）"
            case .paused:
                item.title = "已暂停（恢复后重建基线，不回填）"
            case .unavailable(let reason):
                item.title = reason.count > 60 ? String(reason.prefix(60)) + "…" : reason
            case .connecting:
                item.title = "正在连接 Mihomo…"
            }
        }

        // 今日代理用量（读取时同步查询，开销为一次小查询）
        if let item = menu.item(withTag: 201), status.status == .running || status.status == .paused {
            let calendar = Calendar.current
            let from = calendar.startOfDay(for: Date())
            if let totals = try? store.routeTotals(from: from, to: Date().addingTimeInterval(60)) {
                let proxy = totals.first { $0.route == "proxy" }
                let up = proxy.map { StatsWindowController.bytes($0.upload) } ?? "0 B"
                let down = proxy.map { StatsWindowController.bytes($0.download) } ?? "0 B"
                item.title = "今日代理：↑\(up) ↓\(down)"
            }
        }
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_000_000...: return String(format: "%.1fM", bytesPerSecond / 1e6)
        case 1_000...: return String(format: "%.0fK", bytesPerSecond / 1e3)
        case 100..<1_000: return String(format: "%.0fB", bytesPerSecond)
        default: return "0"
        }
    }

    // MARK: - 动作

    @objc private func openStats() {
        if statsWindowController == nil {
            statsWindowController = StatsWindowController(store: store)
        }
        statsWindowController?.show()
    }

    @objc private func togglePause() {
        paused.toggle()
        if paused {
            monitor.pause()
        } else {
            monitor.resume()
        }
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = paused ? "继续采集" : "暂停采集"
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
