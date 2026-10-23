import AppKit
import StatsCore
import Storage

/// 统计窗口（D 线 + E 线）：应用/域名两个维度 + 时间范围 + 路由筛选。
/// 口径：Clash 已观测（周期活跃连接快照，短连接可能漏采；不含绕过 Clash 的直连）。
/// 应用维度：按用户要求仅展示已归属 .app 的流量；未归属字节数在底部口径行如实标注。
final class StatsWindowController: NSWindowController, NSWindowDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate,
                                   NSSearchFieldDelegate {

    private enum Dimension: Int {
        case apps = 0
        case domains = 1
        case charts = 2

        var title: String {
            switch self {
            case .apps: return "应用"
            case .domains: return "域名"
            case .charts: return "统计图"
            }
        }
    }

    private enum TimeRange: CaseIterable {
        case today, lastHour, last5Minutes

        var title: String {
            switch self {
            case .today: return "今天"
            case .lastHour: return "最近 1 小时"
            case .last5Minutes: return "最近 5 分钟"
            }
        }

        func interval(now: Date, calendar: Calendar) -> (from: Date, to: Date) {
            switch self {
            case .today:
                return (calendar.startOfDay(for: now), now.addingTimeInterval(60))
            case .lastHour:
                return (now.addingTimeInterval(-3600), now.addingTimeInterval(60))
            case .last5Minutes:
                return (now.addingTimeInterval(-300), now.addingTimeInterval(60))
            }
        }
    }

    private enum RouteFilter: Int {
        case all = 0, proxy = 1, direct = 2, unknown = 3

        var raw: String? {
            switch self {
            case .all: return nil
            case .proxy: return "proxy"
            case .direct: return "direct"
            case .unknown: return "unknown"
            }
        }

        var title: String {
            switch self {
            case .all: return "全部"
            case .proxy: return "代理"
            case .direct: return "直连"
            case .unknown: return "路由未知"
            }
        }
    }

    private struct AppRowModel {
        let identity: AppIdentityResolver.Identity
        let upload: Int64
        let download: Int64
        var total: Int64 { upload + download }
    }

    private struct DomainRowModel {
        let kind: String
        let key: String
        let route: String
        let upload: Int64
        let download: Int64
        var total: Int64 { upload + download }
    }

    private let store: TrafficStore
    private let resolver = AppIdentityResolver()
    private let chartTab: StatsChartTab
    private var dimension: Dimension = .apps
    private var timeRange: TimeRange = .today
    private var routeFilter: RouteFilter = .all
    private var appRows: [AppRowModel] = []
    private var domainRows: [DomainRowModel] = []
    private var refreshTimer: Timer?

    // 表头排序状态（域名页与下钻明细共用 domainSort）；与路由筛选同语义：跨窗口重开保留
    private var appSort: TableListFilter.Sort = .byTotalDesc
    private var domainSort: TableListFilter.Sort = .byTotalDesc
    /// 搜索框过滤词（逐键生效；空白 = 不过滤，跨窗口重开保留）
    private var filterText: String = ""
    /// 程序化回放排序箭头时防 sortDescriptorsDidChange 重入（程序化 set 本不回调，双保险）
    private var isSyncingSortDescriptors = false

    /// 下钻状态：非 nil 时表格展示该应用的访问目标明细。
    private var drilledApp: AppIdentityResolver.Identity?

    private var tableView: NSTableView!
    private var tableScroll: NSScrollView!
    private var footerLabel: NSTextField!
    private var dimensionSegment: NSSegmentedControl!
    private var backButton: NSButton!
    private var rangePopup: NSPopUpButton!
    private var routeSegment: NSSegmentedControl!
    private var searchField: NSSearchField!
    private var matchCountLabel: NSTextField!

    init(store: TrafficStore) {
        self.store = store
        self.chartTab = StatsChartTab(store: store, resolver: resolver)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "AppTrafficMonitor — Clash 已观测"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContentView()
        chartTab.onFooterChange = { [weak self] text in
            // 图表页签的页脚由 StatsChartTab 组装（区间/保留期/口径），共用底部标签
            self?.footerLabel?.stringValue = text
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持 storyboard 初始化") }

    func show() {
        // 修复状态分裂：上次会话可能停在下钻态（列=目标列）而 drilledApp 已被
        // windowWillClose 清空——重开时统一重建列与顶栏，保证列/数据/标题一致。
        rebuildColumns()
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, target: self,
                          selector: #selector(refreshTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// 自测/演示入口（--show-charts）：直达统计图页签。
    func selectChartsTab() {
        drilledApp = nil
        dimension = .charts
        dimensionSegment.selectedSegment = Dimension.charts.rawValue
        rebuildColumns()
        chartTab.refresh(force: true)
    }

    @objc private func refreshTimerFired() {
        guard let window = window, window.isVisible else { return }
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口关闭即停刷新并释放查询结果（资源规则 §9）；
        // 下钻态一并复位（rebuildColumns 会同步恢复顶栏与标题，防止下次打开状态分裂）
        refreshTimer?.invalidate()
        refreshTimer = nil
        appRows = []
        domainRows = []
        chartTab.reset()
        if drilledApp != nil {
            drilledApp = nil
            rebuildColumns()
        }
        tableView?.reloadData()
        footerLabel?.stringValue = ""
        matchCountLabel?.isHidden = true
    }

    // MARK: - 数据

    @objc private func refresh() {
        if dimension == .charts {
            // 统计图页签：数据/页脚由 StatsChartTab 负责（内部 30 秒节流）
            appRows = []
            domainRows = []
            tableView.reloadData()
            chartTab.refresh(force: false)
            return
        }
        let (from, to) = timeRange.interval(now: Date(), calendar: Calendar.current)
        do {
            if let drilled = drilledApp {
                let usage = try store.appTargetUsage(appKey: drilled.appKey, from: from, to: to,
                                                     route: routeFilter.raw)
                let mapped = usage.map { DomainRowModel(kind: $0.kind, key: $0.key, route: $0.route,
                                                        upload: $0.upload, download: $0.download) }
                domainRows = transformedRows(mapped, texts: { [displayKey($0)] },
                                             text: domainText, number: domainNumber)
                updateMatchCount(matched: domainRows.count, of: mapped.count)
                appRows = []
            } else {
                switch dimension {
                case .apps:
                    let usage = try store.appUsage(from: from, to: to, route: routeFilter.raw)
                    let mapped: [AppRowModel] = usage.compactMap { usage in
                        guard let identity = resolver.identity(appKey: usage.appKey) else { return nil }
                        return AppRowModel(identity: identity, upload: usage.upload, download: usage.download)
                    }
                    appRows = transformedRows(mapped,
                                              texts: { [$0.identity.displayName, $0.identity.appKey] },
                                              text: appText, number: appNumber)
                    updateMatchCount(matched: appRows.count, of: mapped.count)
                    domainRows = []
                case .domains:
                    let usage = try store.targetUsage(from: from, to: to, route: routeFilter.raw)
                    let mapped = usage.map { DomainRowModel(kind: $0.kind, key: $0.key, route: $0.route,
                                                            upload: $0.upload, download: $0.download) }
                    domainRows = transformedRows(mapped, texts: { [displayKey($0)] },
                                                 text: domainText, number: domainNumber)
                    updateMatchCount(matched: domainRows.count, of: mapped.count)
                    appRows = []
                case .charts:
                    break // 函数入口已分流到 StatsChartTab，此处不可达
                }
            }
            footerLabel?.stringValue = buildFooter(from: from, to: to)
        } catch {
            appRows = []
            domainRows = []
            matchCountLabel?.isHidden = true
            footerLabel?.stringValue = "查询失败：\(String(describing: error))"
        }
        tableView.reloadData()
    }

    /// 行列表统一管线：模糊过滤 → 表头排序（口径见 TableListFilter；排序基于 Int64 原始值）。
    private func transformedRows<Input>(_ rows: [Input],
                                       texts: (Input) -> [String],
                                       text: (Input, TableListFilter.SortKey) -> String?,
                                       number: (Input, TableListFilter.SortKey) -> Int64?) -> [Input] {
        let filtered = TableListFilter.filteredInstances(rows, query: filterText, texts: texts)
        return TableListFilter.sortedInstances(filtered, by: currentSort, text: text, number: number)
    }

    /// 当前生效排序：应用页与「域名/下钻」各自独立记忆。
    private var currentSort: TableListFilter.Sort {
        effectiveDimension == .apps ? appSort : domainSort
    }

    /// 匹配计数「命中/总数」：仅在过滤词非空白时显示。
    /// 页脚保持区间/路由真实总量口径，不受文本过滤影响（文本过滤是列表收窄）。
    private func updateMatchCount(matched: Int, of total: Int) {
        matchCountLabel?.isHidden = !isFilterActive
        matchCountLabel?.stringValue = "\(matched)/\(total)"
    }

    private var isFilterActive: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 排序键提取：数值列给 Int64 原始值（绝不给格式化字符串）；文本列按展示值（所见即所排）
    private func appText(_ row: AppRowModel, _ key: TableListFilter.SortKey) -> String? {
        key == .name ? row.identity.displayName : nil
    }

    private func appNumber(_ row: AppRowModel, _ key: TableListFilter.SortKey) -> Int64? {
        switch key {
        case .upload: return row.upload
        case .download: return row.download
        case .total: return row.total
        default: return nil
        }
    }

    private func domainText(_ row: DomainRowModel, _ key: TableListFilter.SortKey) -> String? {
        switch key {
        case .name: return displayKey(row)
        case .kind: return kindTitle(row.kind)
        case .route: return routeTitle(row.route)
        default: return nil
        }
    }

    private func domainNumber(_ row: DomainRowModel, _ key: TableListFilter.SortKey) -> Int64? {
        switch key {
        case .upload: return row.upload
        case .download: return row.download
        case .total: return row.total
        default: return nil
        }
    }

    private func buildFooter(from: Date, to: Date) -> String {
        do {
            let totals = try store.totals(from: from, to: to, route: routeFilter.raw)
            let allRoutes = try store.routeTotals(from: from, to: to)
            let routeDict = Dictionary(uniqueKeysWithValues: allRoutes.map { ($0.route, $0.upload + $0.download) })
            let all = routeDict.values.reduce(0, +)
            let unknownRoute = routeDict["unknown"] ?? 0
            let unknownPercent = all > 0 ? String(format: "%.1f%%", Double(unknownRoute) / Double(all) * 100) : "—"
            var lines: [String] = []
            lines.append("合计（当前筛选）↑\(Self.bytes(totals.upload)) ↓\(Self.bytes(totals.download))　|　全路由：代理 \(Self.bytes(routeDict["proxy"] ?? 0)) · 直连 \(Self.bytes(routeDict["direct"] ?? 0)) · 路由未知 \(Self.bytes(unknownRoute))（\(unknownPercent)）")
            if let drilled = drilledApp {
                lines.append("正在查看「\(drilled.displayName)」访问的目标（时间范围与路由筛选对下钻同样生效）")
            } else if dimension == .apps {
                let unattributed = try store.unattributedTotals(from: from, to: to, route: routeFilter.raw)
                if unattributed.upload > 0 || unattributed.download > 0 {
                    lines.append("未归属进程的流量（不在上方列表）：↑\(Self.bytes(unattributed.upload)) ↓\(Self.bytes(unattributed.download))")
                }
                lines.append("提示：双击应用行可下钻查看它访问的域名 / IP。")
            }
            lines.append("口径：Clash 已观测——周期活跃连接快照，短连接可能漏采；不含绕过 Clash 的直连；app 归属来自连接源端口映射，扫描间隔内的短连接可能记为未归属。")
            return lines.joined(separator: "\n")
        } catch {
            return "合计查询失败：\(String(describing: error))"
        }
    }

    // MARK: - UI 构建

    private func buildContentView() {
        guard let content = window?.contentView else { return }

        backButton = NSButton(title: "‹ 返回应用", target: self, action: #selector(backToAppList(_:)))
        backButton.bezelStyle = .recessed
        backButton.frame = NSRect(x: 16, y: 482, width: 110, height: 26)
        backButton.isHidden = true

        dimensionSegment = NSSegmentedControl(frame: NSRect(x: 16, y: 482, width: 200, height: 26))
        dimensionSegment.segmentCount = 3
        dimensionSegment.setLabel(Dimension.apps.title, forSegment: Dimension.apps.rawValue)
        dimensionSegment.setLabel(Dimension.domains.title, forSegment: Dimension.domains.rawValue)
        dimensionSegment.setLabel(Dimension.charts.title, forSegment: Dimension.charts.rawValue)
        dimensionSegment.trackingMode = .selectOne
        dimensionSegment.selectedSegment = Dimension.apps.rawValue
        dimensionSegment.target = self
        dimensionSegment.action = #selector(dimensionChanged(_:))

        rangePopup = NSPopUpButton(frame: NSRect(x: 226, y: 482, width: 140, height: 26), pullsDown: false)
        TimeRange.allCases.forEach { rangePopup.addItem(withTitle: $0.title) }
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged(_:))

        routeSegment = NSSegmentedControl(frame: NSRect(x: 380, y: 482, width: 300, height: 26))
        routeSegment.segmentCount = 4
        for (index, filter) in [RouteFilter.all, .proxy, .direct, .unknown].enumerated() {
            routeSegment.setLabel(filter.title, forSegment: index)
        }
        routeSegment.trackingMode = .selectOne
        routeSegment.selectedSegment = 0
        routeSegment.target = self
        routeSegment.action = #selector(routeChanged(_:))

        // 文本模糊过滤（逐键生效，输入即收窄）：搜索框 + 「命中/总数」计数
        searchField = NSSearchField(frame: NSRect(x: 696, y: 482, width: 118, height: 26))
        searchField.placeholderString = "过滤应用 / 路径"
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))

        matchCountLabel = NSTextField(labelWithString: "")
        matchCountLabel.frame = NSRect(x: 818, y: 486, width: 46, height: 18)
        matchCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .right
        matchCountLabel.isHidden = true

        tableScroll = NSScrollView(frame: NSRect(x: 16, y: 62, width: 848, height: 412))
        tableView = NSTableView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.target = self
        rebuildColumns()

        // 统计图页签容器（I 线）：默认隐藏，.charts 维度时接管主体区域
        chartTab.root.frame = NSRect(x: 16, y: 62, width: 848, height: 412)
        chartTab.root.isHidden = true

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.frame = NSRect(x: 16, y: 6, width: 848, height: 52)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.cell?.truncatesLastVisibleLine = true
        footerLabel.cell?.wraps = true

        content.addSubview(backButton)
        content.addSubview(dimensionSegment)
        content.addSubview(rangePopup)
        content.addSubview(routeSegment)
        content.addSubview(searchField)
        content.addSubview(matchCountLabel)
        content.addSubview(tableScroll)
        content.addSubview(chartTab.root)
        content.addSubview(footerLabel)
    }

    private func rebuildColumns() {
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        // 下钻状态使用目标明细列；与域名维度同构
        let effectiveDimension = drilledApp != nil ? Dimension.domains : dimension
        // 默认列宽按一屏放下取值：macOS 11+ .inset 样式的实际表宽 = 列宽和 + 17×列数 + 15，
        // 可视宽 848（overlay 滚动条，窗口 880）。数字列最宽值"999.99 MB"需 71pt；
        // 余量由 fitColumnsToClipWidth 归名称列。排序箭头画在现有表头格内，不影响列宽计算。
        switch effectiveDimension {
        case .apps:
            let columns: [(String, CGFloat, NSTextAlignment, TableListFilter.SortKey?)] = [
                ("图标", 44, .center, nil), ("应用", 332, .left, .name),
                ("上传", 84, .right, .upload), ("下载", 84, .right, .download),
                ("合计", 84, .right, .total),
            ]
            for (title, width, alignment, sortKey) in columns {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
                col.title = title == "图标" ? "" : title
                col.width = width
                if title == "图标" {
                    let imageCell = NSImageCell()
                    imageCell.imageAlignment = .alignCenter
                    col.dataCell = imageCell
                } else {
                    (col.dataCell as? NSTextFieldCell)?.alignment = alignment
                }
                attachSortPrototype(col, key: sortKey)
                tableView.addTableColumn(col)
            }
        case .domains:
            // 目标列加宽 + 中段截断（保住域名前缀与后缀，长 CDN 域名不再"头尾全丢"）
            let columns: [(String, CGFloat, NSTextAlignment, NSLineBreakMode?, TableListFilter.SortKey?)] = [
                ("目标", 286, .left, NSLineBreakMode.byTruncatingMiddle, .name),
                ("类型", 44, .left, nil, .kind), ("路由", 62, .left, nil, .route),
                ("上传", 73, .right, nil, .upload), ("下载", 73, .right, nil, .download),
                ("合计", 73, .right, nil, .total),
            ]
            for (title, width, alignment, lineBreak, sortKey) in columns {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
                col.title = title
                col.width = width
                if let cell = col.dataCell as? NSTextFieldCell {
                    cell.alignment = alignment
                    if let lineBreak = lineBreak { cell.lineBreakMode = lineBreak }
                }
                attachSortPrototype(col, key: sortKey)
                tableView.addTableColumn(col)
            }
        case .charts:
            break // 统计图页签无表格列（主体为图表容器）
        }
        fitColumnsToClipWidth(flexible: effectiveDimension == .apps ? "应用" : "目标")
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        syncSortIndicator()
        syncChrome()
    }

    /// 表头排序原型：数值列初向降序（大值在前）、文本列升序；「图标」列不参与（key 为 nil）。
    private func attachSortPrototype(_ column: NSTableColumn, key: TableListFilter.SortKey?) {
        guard let key else { return }
        let ascending: Bool
        switch key {
        case .upload, .download, .total: ascending = false
        case .name, .kind, .route: ascending = true
        }
        column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: ascending)
    }

    /// 列重建/维度切换后回放当前排序，恢复表头箭头（程序化 set 不触发 didChange 回调）。
    private func syncSortIndicator() {
        guard effectiveDimension != .charts else {
            tableView.sortDescriptors = []
            return
        }
        isSyncingSortDescriptors = true
        defer { isSyncingSortDescriptors = false }
        let sort = currentSort
        tableView.sortDescriptors = [NSSortDescriptor(key: columnTitle(forSortKey: sort.key),
                                                      ascending: sort.ascending)]
    }

    /// 语义键 → 列标识（回放箭头用）。「名称」在应用页叫「应用」、目标页叫「目标」。
    private func columnTitle(forSortKey key: TableListFilter.SortKey) -> String {
        switch key {
        case .name: return effectiveDimension == .apps ? "应用" : "目标"
        case .kind: return "类型"
        case .route: return "路由"
        case .upload: return "上传"
        case .download: return "下载"
        case .total: return "合计"
        }
    }

    /// 列标识 → 语义键（表头点击回调用），非可排序列返回 nil。
    private static func sortKey(forColumnTitle title: String) -> TableListFilter.SortKey? {
        switch title {
        case "应用", "目标": return .name
        case "类型": return .kind
        case "路由": return .route
        case "上传": return .upload
        case "下载": return .download
        case "合计": return .total
        default: return nil
        }
    }

    /// 让表格恰好铺满可视宽，余量全部归名称列。
    /// 窗口不可缩放，AppKit 的末列自适应不会自行触发；而可视宽随滚动条样式变化
    /// （接鼠标走 legacy 滚动条时少 17pt）。先让 AppKit 把差额算到末列，再挪给名称列，
    /// 保证两种样式下都无需横向滚动，且数字列保持等宽。用户仍可手动拖动改列宽。
    private func fitColumnsToClipWidth(flexible identifier: String) {
        guard let flexible = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)),
              let last = tableView.tableColumns.last else { return }
        let lastDefault = last.width
        tableView.sizeLastColumnToFit()
        let spare = last.width - lastDefault
        last.width = lastDefault
        flexible.width += spare
    }

    /// 顶栏与标题随状态切换（下钻时隐藏维度切换、显示返回按钮；
    /// 统计图页签接管主体区域，隐藏表格与表格侧的时间/路由筛选）。
    private func syncChrome() {
        let drilling = drilledApp != nil
        let chartsActive = dimension == .charts && !drilling
        backButton.isHidden = !drilling
        dimensionSegment.isHidden = drilling
        tableScroll.isHidden = chartsActive
        rangePopup.isHidden = chartsActive
        routeSegment.isHidden = chartsActive
        searchField.isHidden = chartsActive
        matchCountLabel.isHidden = chartsActive || !isFilterActive
        chartTab.root.isHidden = !chartsActive
        // 占位文案跟随维度（下钻态与域名页同为「域名 / IP」）
        searchField.placeholderString = (dimension == .apps && !drilling)
            ? "过滤应用 / 路径" : "过滤域名 / IP"
        if let drilled = drilledApp {
            window?.title = "AppTrafficMonitor — \(drilled.displayName) 的访问目标"
        } else if dimension == .apps {
            window?.title = "AppTrafficMonitor — 应用（双击下钻）"
        } else if dimension == .domains {
            window?.title = "AppTrafficMonitor — Clash 已观测"
        } else {
            window?.title = "AppTrafficMonitor — 统计图"
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard drilledApp == nil, dimension == .apps else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < appRows.count else { return }
        drilledApp = appRows[row].identity
        appRows = []
        rebuildColumns()
        refresh()
    }

    @objc private func backToAppList(_ sender: Any?) {
        drilledApp = nil
        domainRows = []
        rebuildColumns()
        refresh()
    }

    @objc private func dimensionChanged(_ sender: NSSegmentedControl) {
        drilledApp = nil
        dimension = Dimension(rawValue: sender.selectedSegment) ?? .apps
        rebuildColumns()
        refresh()
    }

    @objc private func rangeChanged(_ sender: NSPopUpButton) {
        timeRange = TimeRange.allCases[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func routeChanged(_ sender: NSSegmentedControl) {
        routeFilter = RouteFilter(rawValue: sender.selectedSegment) ?? .all
        refresh()
    }

    /// 搜索框回车/清空按钮：与逐键路径（controlTextDidChange）殊途同归到 refresh。
    @objc private func searchFieldAction(_ sender: NSSearchField) {
        filterText = sender.stringValue
        refresh()
    }

    /// 逐键活过滤（NSSearchField 编辑期间每键回调）。
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        filterText = field.stringValue
        refresh()
    }

    /// 表头点击：更新当前维度排序并对内存行重排（无需重查库）。
    /// 第三击清除排序时回落默认「合计降序」并回显箭头。
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncingSortDescriptors, effectiveDimension != .charts else { return }
        if let descriptor = tableView.sortDescriptors.first,
           let key = descriptor.key.flatMap(Self.sortKey(forColumnTitle:)) {
            let sort = TableListFilter.Sort(key: key, ascending: descriptor.ascending)
            if effectiveDimension == .apps { appSort = sort } else { domainSort = sort }
        } else {
            if effectiveDimension == .apps { appSort = .byTotalDesc } else { domainSort = .byTotalDesc }
            syncSortIndicator()
        }
        resortInPlace()
    }

    private func resortInPlace() {
        if effectiveDimension == .apps {
            appRows = TableListFilter.sortedInstances(appRows, by: appSort, text: appText, number: appNumber)
        } else {
            domainRows = TableListFilter.sortedInstances(domainRows, by: domainSort, text: domainText, number: domainNumber)
        }
        tableView.reloadData()
    }

    // MARK: - NSTableView

    /// 表格维度 = 下钻态等效为目标明细，否则按页签维度（修复：下钻态曾误用
    /// dimension=.apps 的空 appRows 填目标列表，导致表格恒为 0 行）。
    private var effectiveDimension: Dimension {
        drilledApp != nil ? .domains : dimension
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch effectiveDimension {
        case .apps: return appRows.count
        case .domains: return domainRows.count
        case .charts: return 0
        }
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard let column = tableColumn else { return nil }
        switch effectiveDimension {
        case .apps:
            guard row < appRows.count else { return nil }
            let model = appRows[row]
            switch column.identifier.rawValue {
            case "图标": return model.identity.icon
            case "应用": return model.identity.displayName
            case "上传": return Self.bytes(model.upload)
            case "下载": return Self.bytes(model.download)
            case "合计": return Self.bytes(model.total)
            default: return ""
            }
        case .domains:
            guard row < domainRows.count else { return nil }
            let model = domainRows[row]
            switch column.identifier.rawValue {
            case "目标": return displayKey(model)
            case "类型": return kindTitle(model.kind)
            case "路由": return routeTitle(model.route)
            case "上传": return Self.bytes(model.upload)
            case "下载": return Self.bytes(model.download)
            case "合计": return Self.bytes(model.total)
            default: return ""
            }
        case .charts:
            return ""
        }
    }

    private func displayKey(_ model: DomainRowModel) -> String {
        switch model.kind {
        case "domain": return model.key
        case "ip": return "IP \(model.key)（域名未知）"
        default: return model.key
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "domain": return "域名"
        case "ip": return "IP"
        default: return "—"
        }
    }

    private func routeTitle(_ route: String) -> String {
        switch route {
        case "proxy": return RouteFilter.proxy.title
        case "direct": return RouteFilter.direct.title
        default: return RouteFilter.unknown.title
        }
    }

    static func bytes(_ value: Int64) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.2f GB", v / 1e9)
        case 1_000_000...: return String(format: "%.2f MB", v / 1e6)
        case 1_000...: return String(format: "%.1f KB", v / 1e3)
        default: return String(format: "%.0f B", v)
        }
    }
}
