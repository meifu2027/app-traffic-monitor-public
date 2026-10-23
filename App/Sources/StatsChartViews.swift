import SwiftUI
import Charts

// I 线统计图页签的 SwiftUI 图表视图（经 NSHostingView 内嵌进 AppKit 统计窗口）。
// 本文件是项目中唯一的 SwiftUI 使用点（I 线决策：用 Swift Charts 换取坐标轴/
// 图例/悬浮的成品质量，其余 UI 维持纯 AppKit 手写）。

/// 字节数的自适应格式化（坐标轴与条形标注共用）。
struct BytesFormatStyle: FormatStyle {
    func format(_ value: Double) -> String {
        let v = max(value, 0)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fG", v / 1e9)
        case 1_000_000...: return String(format: "%.1fM", v / 1e6)
        case 1_000...: return String(format: "%.0fK", v / 1e3)
        default: return String(format: "%.0fB", v)
        }
    }
}

/// 主图数据点：一个周期一个点（上传/下载双系列）。
struct SeriesPoint: Identifiable {
    let start: Date
    let upload: Double
    let download: Double
    var id: Date { start }
}

/// TopN 条形图数据点（应用名/目标标签 + 合计流量）。
struct NamedPoint: Identifiable {
    let name: String
    let value: Double
    var id: String { name }
}

/// 主图：按周期分桶的上传/下载分组柱状图。
/// X 域固定为查询区间（无数据的日留空，避免坐标轴缩到数据范围让"近 N 天"变样）。
struct SeriesChartView: View {
    let points: [SeriesPoint]
    let unit: Calendar.Component
    let domain: ClosedRange<Date>

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("时间", point.start, unit: unit),
                    y: .value("流量", point.download))
                .foregroundStyle(by: .value("方向", "下载"))
            BarMark(x: .value("时间", point.start, unit: unit),
                    y: .value("流量", point.upload))
                .foregroundStyle(by: .value("方向", "上传"))
        }
        .chartXScale(domain: domain)
        .chartForegroundStyleScale([
            "下载": Color(nsColor: .systemBlue),
            "上传": Color(nsColor: .systemOrange),
        ])
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: BytesFormatStyle())
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6))
        }
        .chartLegend(position: .top, alignment: .trailing)
        .padding(.horizontal, 4)
    }
}

/// TopN 行：应用名/目标文字在前、比例条形居中、末尾具体用量（用户决策的布局）。
/// 应用面板：最多三行换行；目标面板（域名可能极长）：单行尾截断 + 悬浮提示全文
/// （提示由 AppKit 层实现——SwiftUI .help() 在 NSHostingView 内嵌下实测不可靠）。
struct TopNRow: View {
    let name: String
    let value: Double
    let maxValue: Double
    let barColor: Color
    let isSelected: Bool
    /// 单行截断并把全文放进悬浮提示（访问目标面板用）
    var singleLineTooltip = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            nameView
                .frame(width: 140, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: Self.barWidth(value: value, max: maxValue,
                                                    available: geo.size.width),
                               height: 8)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            Text(BytesFormatStyle().format(value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    /// 名称列：目标面板单行尾截断（全文走悬浮提示回调）；应用面板最多三行换行。
    @ViewBuilder private var nameView: some View {
        let styled = Text(name)
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : .primary)
            .truncationMode(.tail)
            .frame(width: 140, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if singleLineTooltip {
            styled.lineLimit(1)
        } else {
            styled.lineLimit(3)
        }
    }

    static func barWidth(value: Double, max maxValue: Double, available: CGFloat) -> CGFloat {
        guard maxValue > 0, available > 0, value > 0 else { return 0 }
        return max(2, available * CGFloat(value / maxValue))
    }
}

/// TopN 列表（统计图页签两张底图共用）：文字|条形|用量 行布局 + 垂直滚动兜底。
/// 应用面板传 onSelect 支持点行联动筛选（多选 toggle：加入/移出集合由页签处理）。
struct TopNListView: View {
    let items: [NamedPoint]
    let selectedNames: Set<String>
    let barColor: Color
    let emptyText: String
    var singleLineTooltip = false
    /// 行悬浮回调（hovering 行名 / 离开为 nil）——目标面板把全文交给 AppKit 层显示
    var onHoverName: ((String?) -> Void)? = nil
    /// 行点击回调（恒传所点行名；toggle 语义由回调方实现）
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        if items.isEmpty {
            EmptyChartView(text: emptyText)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    let maxValue = items.map(\.value).max() ?? 0
                    ForEach(items) { item in
                        TopNRow(name: item.name,
                                value: item.value,
                                maxValue: maxValue,
                                barColor: barColor,
                                isSelected: selectedNames.contains(item.name),
                                singleLineTooltip: singleLineTooltip)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                onHoverName?(hovering ? item.name : nil)
                            }
                            .onTapGesture {
                                onSelect?(item.name)
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }
}

/// 空态占位（区间无数据/查询失败）。
struct EmptyChartView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
