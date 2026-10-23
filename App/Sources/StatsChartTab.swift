import AppKit
import SwiftUI
import StatsCore
import Storage

/// 统计图页签控制器（I 线）：主图（时间序列）+ Top 应用 / 访问目标 TopN 条形图联动。
///
/// 数据口径：近端分钟桶（约 48 小时）∪ 日汇总（约 400 天）；「Clash 已观测」口径
/// 同其它页签。查询节流：1 秒 Timer 驱动但默认 30 秒才真正查询一次（控件变更立即查），
/// 关窗由 StatsWindowController 调 reset() 清空模型（资源规则 §9）。
final class StatsChartTab {

    private enum RangePreset: Int, CaseIterable {
        case today, last7Days, last30Days, thisMonth, lastMonth, last90Days, lastYear, custom

        var title: String {
            switch self {
            case .today: return "今天"
            case .last7Days: return "最近 7 天"
            case .last30Days: return "最近 30 天"
            case .thisMonth: return "本月"
            case .lastMonth: return "上月"
            case .last90Days: return "最近 90 天"
            case .lastYear: return "最近 1 年"
            case .custom: return "自定义"
            }
        }

        /// 自定义档返回 nil（由起止选择器决定）；其余返回日对齐区间。
        func interval(now: Date, calendar: Calendar) -> (from: Date, to: Date)? {
            let today = calendar.startOfDay(for: now)
            let to = now.addingTimeInterval(60)
            switch self {
            case .today:
                return (today, to)
            case .last7Days:
                return (calendar.date(byAdding: .day, value: -6, to: today)!, to)
            case .last30Days:
                return (calendar.date(byAdding: .day, value: -29, to: today)!, to)
            case .thisMonth:
                return (calendar.dateInterval(of: .month, for: today)!.start, to)
            case .lastMonth:
                let month = calendar.dateInterval(of: .month, for: today)!
                let lastMonth = calendar.dateInterval(of: .month,
                                                      for: month.start.addingTimeInterval(-1))!
                return (lastMonth.start, month.start)
            case .last90Days:
                return (calendar.date(byAdding: .day, value: -89, to: today)!, to)
            case .lastYear:
                return (calendar.date(byAdding: .day, value: -364, to: today)!, to)
            case .custom:
                return nil
            }
        }
    }

    /// 页脚口径行由主窗口统一展示（与表格页签共用底部标签）。
    var onFooterChange: ((String) -> Void)?

    let root = NSView(frame: NSRect(x: 0, y: 0, width: 848, height: 412))

    private let store: TrafficStore
    private let resolver: AppIdentityResolver
    private let calendar: Calendar = {
        var cal = Calendar.current
        cal.firstWeekday = 2 // 周一为一周起点（与归桶测试口径一致）
        return cal
    }()

    private var preset: RangePreset = .last7Days
    private var granularity: PeriodGranularity = .day
    private var routeRaw: String?
    /// 多选筛选集（Top 应用条形点击 toggle 增删；主图与访问目标 TopN 按集合聚合）
    private var selectedAppKeys: [String] = []
    private var lastQueryAt: Date?
    private var hourDroppedNotice = false

    private var seriesPoints: [SeriesPoint] = []
    /// 最近一次成功查询的区间（主图 X 域，空档日也占位）
    private var queriedDomain: ClosedRange<Date> = Date()...Date()
    private var topAppItems: [NamedPoint] = []
    private var targetItems: [NamedPoint] = []
    /// 展示名 → appKey（条形图点击联动用；名已去重，反查唯一）
    private var appKeyByName: [String: String] = [:]
    private var popupAppKeys: [String] = [] // 与菜单项一一对应（index 0 = 全部应用）

    private var rangePopup: NSPopUpButton!
    private var startPicker: NSDatePicker!
    private var endPicker: NSDatePicker!
    private var routePopup: NSPopUpButton!
    private var granularitySegment: NSSegmentedControl!
    private var appPopup: NSPopUpButton!
    private var mainHost: NSHostingView<AnyView>!
    private var leftHost: NSHostingView<AnyView>!
    private var rightHost: NSHostingView<AnyView>!
    private var rightCaption: NSTextField!

    // 悬浮提示（SwiftUI .help() 在 NSHostingView 内嵌下不可靠，改为 AppKit 自绘面板）
    private var tooltipPanel: NSPanel?
    private var tooltipShowTimer: Timer?
    private var hoveredTargetName: String?

    init(store: TrafficStore, resolver: AppIdentityResolver) {
        self.store = store
        self.resolver = resolver
        buildControls()
        syncPickersWithPreset(now: Date())
        updateGranularityUI(now: Date())
        renderAll()
    }

    // MARK: - 刷新（1 秒 Timer 驱动，内部节流）

    func refresh(force: Bool) {
        let now = Date()
        if !force, let last = lastQueryAt, now.timeIntervalSince(last) < 30 { return }
        lastQueryAt = now
        refreshLocked(now: now)
    }

    /// 关窗复位：清空模型并复位节流（下次打开强制重查；控件选择保留，重开即恢复视图）。
    func reset() {
        seriesPoints = []
        topAppItems = []
        targetItems = []
        lastQueryAt = nil
        handleTargetHover(nil)
        renderAll()
    }

    private func refreshLocked(now: Date) {
        guard let (rawFrom, rawTo) = currentInterval(now: now) else {
            seriesPoints = []
            topAppItems = []
            targetItems = []
            renderAll()
            onFooterChange?("时间区间无效：起始日不能晚于结束日。")
            return
        }
        // 小时粒度仅近端分钟数据可支撑：from 早于维护前沿时自动降级为天并注明
        hourDroppedNotice = false
        if granularity == .hour, rawFrom < minuteFrontier(now: now) {
            granularity = .day
            hourDroppedNotice = true
            updateGranularityUI(now: now)
        }
        // 天/周/月粒度把区间 snap 到日边界（日汇总按整日计入，避免口径损失）
        var from = rawFrom
        var to = rawTo
        if granularity != .hour {
            from = calendar.startOfDay(for: from)
            let toDay = calendar.startOfDay(for: to.addingTimeInterval(-1))
            to = calendar.date(byAdding: .day, value: 1, to: toDay)!
        }
        queriedDomain = from...max(to, from)

        do {
            // 主图序列
            // 主图序列（按多选集合聚合，空集合 = 全部应用）
            let rawSeries: [PeriodTotal]
            if granularity == .hour {
                rawSeries = try store.hourTotals(from: from, to: to, route: routeRaw,
                                                  appKeys: selectedAppKeys)
            } else {
                let days = try store.dayTotals(from: from, to: to, route: routeRaw,
                                                appKeys: selectedAppKeys, calendar: calendar)
                rawSeries = PeriodBucketing.group(days, by: granularity, calendar: calendar)
            }
            seriesPoints = rawSeries.map {
                SeriesPoint(start: $0.date, upload: Double($0.upload), download: Double($0.download))
            }

            // Top 应用（不随选中 app 过滤，保持排行可见以便联动切换）。
            // 降序即「最大者在顶」（行布局自上而下渲染，无需为图表坐标反转）
            let apps = try store.appUsage(from: from, to: to, route: routeRaw)
                .sorted { $0.upload + $0.download > $1.upload + $1.download }
            rebuildAppChoices(apps)
            topAppItems = apps.prefix(8).map {
                NamedPoint(name: displayName(appKey: $0.appKey),
                           value: Double($0.upload + $0.download))
            }

            // 访问目标 TopN（多选集非空时为这些 app 的目标聚合，否则全部目标）
            let usage: [TrafficStore.TargetUsage]
            if selectedAppKeys.isEmpty {
                usage = try store.targetUsage(from: from, to: to, route: routeRaw)
            } else {
                usage = try store.appTargetUsage(appKeys: selectedAppKeys, from: from, to: to, route: routeRaw)
            }
            var merged: [String: (label: String, total: Int64)] = [:]
            for row in usage {
                let label = row.kind == "ip" ? "IP \(row.key)" : row.key
                let id = "\(row.kind)|\(row.key)"
                merged[id, default: (label, 0)].total += row.upload + row.download
            }
            targetItems = merged.values
                .sorted { $0.total > $1.total }
                .prefix(8)
                .map { NamedPoint(name: $0.label, value: Double($0.total)) }

            let upload = rawSeries.reduce(Int64(0)) { $0 + $1.upload }
            let download = rawSeries.reduce(Int64(0)) { $0 + $1.download }
            onFooterChange?(buildFooter(from: from, to: to, upload: upload, download: download))
        } catch {
            seriesPoints = []
            topAppItems = []
            targetItems = []
            onFooterChange?("查询失败：\(String(describing: error))")
        }
        renderAll()
    }

    /// 分钟数据维护前沿（与 TrafficStore.maintainDailyRollup 同式）：小时粒度可用窗口。
    private func minuteFrontier(now: Date) -> Date {
        let anchor = calendar.startOfDay(for: now.addingTimeInterval(-600))
        return calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
    }

    private func buildFooter(from: Date, to: Date, upload: Int64, download: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm"
        var lines: [String] = []
        let selectedNames = selectedAppDisplayNames()
        let appText = selectedNames.isEmpty
            ? "全部应用"
            : "「" + selectedNames.joined(separator: " + ") + "」"
        lines.append("区间 \(formatter.string(from: from)) → \(formatter.string(from: to.addingTimeInterval(-1)))"
                     + "　\(granularity.title)粒度 · \(appText) · \(routeTitle())")
        var retention = "合计 ↑\(StatsWindowController.bytes(upload)) ↓\(StatsWindowController.bytes(download))"
            + "；数据保留：近端分钟级约 48 小时 + 日汇总约 400 天"
        if hourDroppedNotice { retention += "；区间超出小时粒度可用窗口，已自动改用天粒度" }
        lines.append(retention)
        lines.append("口径：Clash 已观测——周期活跃连接快照，短连接可能漏采；不含绕过 Clash 的直连。")
        return lines.joined(separator: "\n")
    }

    private func routeTitle() -> String {
        switch routeRaw {
        case "proxy": return "仅代理"
        case "direct": return "仅直连"
        case "unknown": return "仅路由未知"
        default: return "全路由"
        }
    }

    // MARK: - 控件

    private func buildControls() {
        root.wantsLayer = true

        rangePopup = NSPopUpButton(frame: NSRect(x: 0, y: 386, width: 116, height: 26), pullsDown: false)
        RangePreset.allCases.forEach { rangePopup.addItem(withTitle: $0.title) }
        rangePopup.selectItem(at: preset.rawValue)
        rangePopup.target = self
        rangePopup.action = #selector(presetChanged(_:))

        startPicker = NSDatePicker(frame: NSRect(x: 124, y: 385, width: 132, height: 28))
        endPicker = NSDatePicker(frame: NSRect(x: 274, y: 385, width: 132, height: 28))
        for picker in [startPicker!, endPicker!] {
            // macOS NSDatePicker 无 compact 样式（那是 SwiftUI 的）；文本框+步进器最省空间
            picker.datePickerStyle = .textField
            picker.datePickerElements = [.yearMonthDay]
            picker.timeZone = calendar.timeZone
            picker.target = self
            picker.action = #selector(customDateChanged(_:))
        }

        let dash = NSTextField(labelWithString: "–")
        dash.frame = NSRect(x: 260, y: 386, width: 12, height: 26)
        dash.textColor = .secondaryLabelColor

        routePopup = NSPopUpButton(frame: NSRect(x: 416, y: 386, width: 110, height: 26), pullsDown: false)
        for title in ["全部", "代理", "直连", "路由未知"] {
            routePopup.addItem(withTitle: title)
        }
        routePopup.target = self
        routePopup.action = #selector(routeChanged(_:))

        granularitySegment = NSSegmentedControl(frame: NSRect(x: 0, y: 352, width: 216, height: 26))
        granularitySegment.segmentCount = 4
        for (index, g) in PeriodGranularity.allCases.enumerated() {
            granularitySegment.setLabel(g.title, forSegment: index)
        }
        granularitySegment.trackingMode = .selectOne
        granularitySegment.selectedSegment = PeriodGranularity.allCases.firstIndex(of: granularity) ?? 1
        granularitySegment.target = self
        granularitySegment.action = #selector(granularityChanged(_:))

        appPopup = NSPopUpButton(frame: NSRect(x: 224, y: 352, width: 300, height: 26), pullsDown: false)
        appPopup.addItem(withTitle: "全部应用")
        appPopup.target = self
        appPopup.action = #selector(appChanged(_:))

        mainHost = NSHostingView(rootView: AnyView(EmptyChartView(text: "")))
        mainHost.frame = NSRect(x: 0, y: 158, width: 848, height: 188)

        let leftCaption = NSTextField(labelWithString: "Top 应用（点击条形加选 / 再点取消）")
        leftCaption.frame = NSRect(x: 0, y: 142, width: 412, height: 14)
        leftCaption.font = .systemFont(ofSize: 11, weight: .medium)
        leftCaption.textColor = .secondaryLabelColor
        rightCaption = NSTextField(labelWithString: "访问目标 TopN（全部应用）")
        rightCaption.frame = NSRect(x: 436, y: 142, width: 412, height: 14)
        rightCaption.font = .systemFont(ofSize: 11, weight: .medium)
        rightCaption.textColor = .secondaryLabelColor
        // 应用名过长时保首尾（中段截断），比尾截断更可辨认
        rightCaption.cell?.truncatesLastVisibleLine = true
        rightCaption.cell?.wraps = false
        rightCaption.lineBreakMode = .byTruncatingMiddle

        leftHost = NSHostingView(rootView: AnyView(EmptyChartView(text: "")))
        leftHost.frame = NSRect(x: 0, y: 4, width: 412, height: 134)
        rightHost = NSHostingView(rootView: AnyView(EmptyChartView(text: "")))
        rightHost.frame = NSRect(x: 436, y: 4, width: 412, height: 134)

        for subview in [rangePopup!, startPicker!, endPicker!, dash, routePopup!,
                        granularitySegment!, appPopup!, mainHost!, leftCaption, rightCaption,
                        leftHost!, rightHost!] as [NSView] {
            root.addSubview(subview)
        }
    }

    private func currentInterval(now: Date) -> (from: Date, to: Date)? {
        if let interval = preset.interval(now: now, calendar: calendar) { return interval }
        let today = calendar.startOfDay(for: now)
        var start = calendar.startOfDay(for: startPicker.dateValue)
        if start > today { start = today }
        let end = min(calendar.startOfDay(for: endPicker.dateValue), today)
        guard start <= end else { return nil }
        return (start, calendar.date(byAdding: .day, value: 1, to: end)!)
    }

    /// 按区间跨度推荐粒度（用户可手动改；小时仅在可用窗口内开放）。
    private func recommendedGranularity(span: TimeInterval) -> PeriodGranularity {
        if span <= 2 * 86400 { return .hour }
        if span <= 70 * 86400 { return .day }
        if span <= 200 * 86400 { return .week }
        return .month
    }

    private func syncPickersWithPreset(now: Date) {
        if let interval = preset.interval(now: now, calendar: calendar) {
            startPicker.minDate = nil
            endPicker.maxDate = calendar.startOfDay(for: now)
            startPicker.dateValue = calendar.startOfDay(for: interval.from)
            endPicker.dateValue = calendar.startOfDay(for: interval.to.addingTimeInterval(-1))
        }
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day,
                                   value: -Int(TrafficStore.dailyRollupRetention / 86400) + 1,
                                   to: today)!
        startPicker.minDate = oldest
        endPicker.maxDate = today
    }

    /// 同步粒度分段控件：选中态 + 小时段可用性（区间 from 需不早于分钟数据前沿）。
    private func updateGranularityUI(now: Date) {
        granularitySegment.selectedSegment = PeriodGranularity.allCases.firstIndex(of: granularity) ?? 1
        let hourAvailable: Bool
        if let interval = currentInterval(now: now) {
            hourAvailable = interval.from >= minuteFrontier(now: now)
        } else {
            hourAvailable = false
        }
        granularitySegment.setEnabled(hourAvailable, forSegment: 0)
    }

    /// 应用下拉选项重建（集合不变时保留选择；消失则回落到全部应用）。
    private func rebuildAppChoices(_ apps: [TrafficStore.AppUsage]) {
        let keys = apps.map(\.appKey)
        if keys == popupAppKeys { return }
        popupAppKeys = keys
        appKeyByName = [:]
        var usedNames = Set<String>()
        appPopup.removeAllItems()
        appPopup.addItem(withTitle: "全部应用")
        for app in apps {
            var name = displayName(appKey: app.appKey)
            if usedNames.contains(name) { name += " ②" } // 同名应用去重，保证反查唯一
            usedNames.insert(name)
            appKeyByName[name] = app.appKey
            let item = appPopup.item(withTitle: name) ?? {
                appPopup.addItem(withTitle: name)
                return appPopup.lastItem!
            }()
            item.representedObject = app.appKey
        }
        let available = Set(keys)
        selectedAppKeys = selectedAppKeys.filter { available.contains($0) }
        syncAppPopup()
    }

    /// 应用下拉与多选集同步：空 = 全部应用；单选 = 对应项；
    /// 多选 = 第 0 项改题「已选 N 个应用（清除）」，选它即清空回到全部。
    private func syncAppPopup() {
        appPopup.item(at: 0)?.title = selectedAppKeys.count > 1
            ? "已选 \(selectedAppKeys.count) 个应用（清除）"
            : "全部应用"
        if selectedAppKeys.count == 1 {
            selectAppPopup(appKey: selectedAppKeys[0])
        } else {
            appPopup.selectItem(at: 0)
        }
    }

    /// 多选集的展示名（保持选择顺序）。
    private func selectedAppDisplayNames() -> [String] {
        selectedAppKeys.map { displayName(appKey: $0) }
    }

    private func selectAppPopup(appKey: String) {
        for item in appPopup.itemArray where (item.representedObject as? String) == appKey {
            appPopup.select(item)
            return
        }
        appPopup.selectItem(at: 0)
    }

    private func displayName(appKey: String) -> String {
        if let identity = resolver.identity(appKey: appKey) { return identity.displayName }
        return URL(fileURLWithPath: appKey).deletingPathExtension().lastPathComponent
    }

    // MARK: - 渲染

    private var chartUnit: Calendar.Component {
        switch granularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private func renderAll() {
        mainHost.rootView = seriesPoints.isEmpty
            ? AnyView(EmptyChartView(text: "该区间无数据（或当前筛选无匹配流量）"))
            : AnyView(SeriesChartView(points: seriesPoints, unit: chartUnit, domain: queriedDomain))
        let orderedNames = selectedAppDisplayNames()
        let selectedNames = Set(orderedNames)
        leftHost.rootView = AnyView(TopNListView(
            items: topAppItems,
            selectedNames: selectedNames,
            barColor: Color(nsColor: .systemBlue),
            emptyText: "区间内无已归属应用流量",
            onSelect: { [weak self] name in self?.toggleAppByName(name) }))
        rightHost.rootView = AnyView(TopNListView(
            items: targetItems,
            selectedNames: [],
            barColor: Color(nsColor: .systemTeal),
            emptyText: "无访问目标数据",
            singleLineTooltip: true,
            onHoverName: { [weak self] name in
                self?.handleTargetHover(name)
            }))
        if orderedNames.isEmpty {
            rightCaption.stringValue = "访问目标 TopN（全部应用）"
        } else if orderedNames.count == 1 {
            rightCaption.stringValue = "「\(orderedNames[0])」访问目标 TopN"
        } else {
            rightCaption.stringValue = "「\(orderedNames.joined(separator: " + "))」访问目标 TopN"
        }
    }

    // MARK: - 动作

    // MARK: - 悬浮提示（访问目标全文）

    /// 行悬浮进入/离开：停留约 0.35 秒后在鼠标旁弹出全文面板；离开即隐藏。
    private func handleTargetHover(_ name: String?) {
        hoveredTargetName = name
        tooltipShowTimer?.invalidate()
        tooltipShowTimer = nil
        guard let name = name, !name.isEmpty else {
            hideTargetTooltip()
            return
        }
        // 相邻行切换时先藏旧的再走防抖，避免旧提示黏在原地
        hideTargetTooltip()
        tooltipShowTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.showTargetTooltip(name)
        }
    }

    private func showTargetTooltip(_ name: String) {
        let panel = tooltipPanel ?? makeTargetTooltipPanel()
        tooltipPanel = panel
        guard let field = (panel.contentView as? NSView)?.subviews.compactMap({ $0 as? NSTextField }).first else {
            return
        }
        field.stringValue = name

        // 尺寸：单行优先，超宽按 520pt 上限折行测量
        let attributes: [NSAttributedString.Key: Any] = [.font: field.font ?? .systemFont(ofSize: 11)]
        let textSize = (name as NSString).size(withAttributes: attributes)
        let maxTextWidth: CGFloat = 520
        let lines = max(1, ceil(textSize.width / maxTextWidth))
        let width = min(maxTextWidth, ceil(textSize.width)) + 18
        let height = ceil(textSize.height) * lines + 10
        panel.setContentSize(NSSize(width: width, height: height))

        // 位置：鼠标右上方；出屏则翻到左侧/下方
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y + 4)
        if origin.x + panel.frame.width > visible.maxX {
            origin.x = mouse.x - panel.frame.width - 16
        }
        if origin.y + panel.frame.height > visible.maxY {
            origin.y = mouse.y - panel.frame.height - 16
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func hideTargetTooltip() {
        tooltipPanel?.orderOut(nil)
    }

    /// 圆角边框 + 阴影的只读提示面板（不抢焦点，不激活 app）。
    private func makeTargetTooltipPanel() -> NSPanel {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .labelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        let panel = NSPanel(contentRect: container.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.contentView = container
        return panel
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        preset = RangePreset(rawValue: sender.indexOfSelectedItem) ?? .today
        let now = Date()
        syncPickersWithPreset(now: now)
        if preset != .custom, let interval = currentInterval(now: now) {
            let span = interval.to.timeIntervalSince(interval.from)
            let recommended = recommendedGranularity(span: span)
            if recommended != granularity {
                granularity = recommended
                hourDroppedNotice = false
            }
        }
        updateGranularityUI(now: now)
        refresh(force: true)
    }

    @objc private func customDateChanged(_ sender: NSDatePicker) {
        preset = .custom
        rangePopup.selectItem(withTitle: RangePreset.custom.title)
        let now = Date()
        syncPickersWithPreset(now: now)
        updateGranularityUI(now: now)
        refresh(force: true)
    }

    @objc private func granularityChanged(_ sender: NSSegmentedControl) {
        guard let selected = PeriodGranularity.allCases[safe: sender.selectedSegment] else { return }
        granularity = selected
        refresh(force: true)
    }

    @objc private func routeChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1: routeRaw = "proxy"
        case 2: routeRaw = "direct"
        case 3: routeRaw = "unknown"
        default: routeRaw = nil
        }
        refresh(force: true)
    }

    @objc private func appChanged(_ sender: NSPopUpButton) {
        // 下拉是单选快捷入口：选具体 app 即集合只留它；选第 0 项（全部/清除）清空集合
        selectedAppKeys = sender.indexOfSelectedItem == 0
            ? []
            : [(sender.selectedItem?.representedObject as? String)].compactMap { $0 }
        refresh(force: true)
    }

    /// Top 应用条形图点击联动（name 已在重建时去重，反查唯一）：
    /// 切换该 app 的选中态——未选则加入集合、已选则移除；主图与目标 TopN 随集合重算。
    private func toggleAppByName(_ name: String) {
        guard let appKey = appKeyByName[name] else { return }
        if let index = selectedAppKeys.firstIndex(of: appKey) {
            selectedAppKeys.remove(at: index)
        } else {
            selectedAppKeys.append(appKey)
        }
        syncAppPopup()
        refresh(force: true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
