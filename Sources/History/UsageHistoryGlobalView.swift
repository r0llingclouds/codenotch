import Charts
import SwiftUI

struct UsageHistoryGlobalView: View {
    @ObservedObject var model: UsageHistoryModel
    private var quotaTrends: [UsageHistoryTrend] { model.trends.filter { $0.series.kind == .quota } }
    private var endOfDay: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: model.end))! }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(UsageWidgetSnapshot.catalogue, id: \.id) { provider in
                    HistoryTrendCard(id: provider.id, name: provider.name,
                        trend: model.trends.first { $0.id == provider.id },
                        start: model.start, end: endOfDay,
                        select: { model.selectProvider(provider.id) })
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("Quota trends together")).font(.system(size: 16, weight: .semibold))
                Text(L10n.t("One labeled quota per service. Each has its own limit and reset window; percentages are not added together."))
                    .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                GlobalQuotaChart(trends: quotaTrends, start: model.start, end: endOfDay)
                    .frame(height: 210)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 9) {
                    ForEach(quotaTrends) { trend in
                        HStack(spacing: 6) {
                            Circle().fill(DashboardBrand.color(trend.id)).frame(width: 6, height: 6)
                            Text(trend.name + " · " + trend.series.label).lineLimit(1)
                        }.font(.system(size: 10)).foregroundStyle(dashboardMuted)
                    }
                }
            }.historyPanel()
            HStack(alignment: .top, spacing: 18) {
                activity.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.t("Activity across services")).font(.system(size: 15, weight: .semibold))
                    HistoryCalendar(days: model.globalDays, tint: .mint, valueLabel: L10n.t("Active services"))
                    Text(L10n.t("Brighter days show more services with observed consumption. Empty days have no readings."))
                        .font(.system(size: 10)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
                }.historyPanel().frame(maxWidth: .infinity)
            }
            Text(L10n.t("Recording starts with your first fresh reading. Select any card for its daily consumption, quota windows and CSV export."))
                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("Active services per day")).font(.system(size: 15, weight: .semibold))
            Chart(model.globalDays) { day in
                if let active = day.consumed {
                    BarMark(x: .value(L10n.t("Day"), day.date, unit: .day), y: .value(L10n.t("Active services"), active))
                        .foregroundStyle(Color.mint.gradient).cornerRadius(3)
                    if active == 0 {
                        PointMark(x: .value(L10n.t("Day"), day.date, unit: .day), y: .value(L10n.t("Active services"), 0))
                            .foregroundStyle(.mint).symbolSize(15)
                    }
                }
            }
            .chartXScale(domain: model.start...endOfDay).chartYScale(domain: 0...9)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 3, 6, 9]) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
            .frame(height: 145)
            Text(L10n.t("Counts services with observed consumption in the displayed series. Money, credits and quota percentages are never summed."))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
        }.historyPanel()
    }
}

private struct HistoryTrendCard: View {
    let id: String
    let name: String
    let trend: UsageHistoryTrend?
    let start: Date
    let end: Date
    let select: () -> Void
    private var tint: Color { DashboardBrand.color(id) }
    private var value: String { trend?.series.formatted(trend?.points.last?.value) ?? "—" }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DashboardBrand(id: id, size: 18)
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(value).font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                }
                HStack {
                    Text(trend?.series.label ?? L10n.t("Waiting for readings"))
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
                if let trend, !trend.points.isEmpty {
                    HistorySparkline(points: trend.chartPoints, start: start, end: end, tint: tint)
                        .frame(height: 45)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.05))
                        .overlay(Text(L10n.t("No history yet")).font(.system(size: 10)).foregroundStyle(dashboardMuted))
                        .frame(height: 45)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.18)))
        }.buttonStyle(.plain)
            .accessibilityLabel(name + ", " + (trend?.series.label ?? L10n.t("No readings yet")))
            .accessibilityValue(value).accessibilityHint(L10n.t("Show this service's history"))
            .help(L10n.t("The sparkline spans the available readings within the selected period."))
    }
}

private struct HistorySparkline: View {
    let points: [UsageHistoryChartPoint]
    let start: Date
    let end: Date
    let tint: Color
    private var visibleRange: ClosedRange<Date> {
        guard let first = points.first?.point.date, let last = points.last?.point.date else { return start...end }
        // Fit the available history: a new installation has minutes of data,
        // which would otherwise collapse to a vertical mark in a 30-day card.
        if first == last { return first.addingTimeInterval(-150)...last.addingTimeInterval(150) }
        return first...last
    }
    var body: some View {
        Chart {
            ForEach(points) { item in
                LineMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Reading"), item.point.value),
                    series: .value("Window", item.segment))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Reading"), item.point.value))
                    .foregroundStyle(tint).symbolSize(points.count < 10 ? 13 : 3)
            }
        }.chartXScale(domain: visibleRange).chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden).accessibilityHidden(true)
    }
}

private struct GlobalQuotaChart: View {
    let trends: [UsageHistoryTrend]
    let start: Date
    let end: Date
    private var maximum: Double { max(100, (trends.flatMap(\.points).map(\.value).max() ?? 0) * 1.1) }
    var body: some View {
        Chart {
            ForEach(trends) { trend in
                ForEach(trend.chartPoints) { item in
                    LineMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Quota used (%)"), item.point.value),
                        series: .value("Window", "\(trend.id)-\(item.segment)"))
                        .foregroundStyle(DashboardBrand.color(trend.id)).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Quota used (%)"), item.point.value))
                        .foregroundStyle(DashboardBrand.color(trend.id)).symbolSize(trend.chartPoints.count < 50 ? 22 : 3)
                        .accessibilityLabel(trend.name + ", " + trend.series.label)
                }
            }
            RuleMark(y: .value(L10n.t("Limit"), 100))
                .foregroundStyle(.white.opacity(0.15)).lineStyle(StrokeStyle(dash: [4, 4]))
        }.chartXScale(domain: start...end).chartYScale(domain: 0...maximum)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
            .chartLegend(.hidden)
    }
}
