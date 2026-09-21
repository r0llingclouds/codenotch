import Charts
import SwiftUI

struct UsageHistoryClaudeView: View {
    @ObservedObject var model: UsageHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.providerTrends.isEmpty {
                Label(model.isLoading ? L10n.t("Loading history…") : L10n.t("Waiting for Claude readings"),
                      systemImage: "chart.xyaxis.line")
                    .foregroundStyle(dashboardMuted).historyPanel()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                          alignment: .leading, spacing: 14) {
                    // A provider ID identifies a global card, but each Claude
                    // quota has its own series ID. Using the provider here
                    // would collapse all three charts into the same view.
                    ForEach(model.providerTrends, id: \.series.id) { trend in
                        ClaudeQuotaHistoryCard(trend: trend, start: model.start, end: model.end)
                    }
                }
            }
            Text(L10n.t("Each quota has its own reset window. Daily changes are shown separately because the quotas overlap."))
                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
            Text(L10n.t("Observed changes between nearby readings, not a billing total. The first reading, resets and offline periods are excluded."))
                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
        }
    }
}

private struct ClaudeQuotaHistoryCard: View {
    let trend: UsageHistoryTrend
    let start: Date
    let end: Date
    @State private var selectedDate: Date?
    private var tint: Color {
        if trend.series.isFable { return DashboardBrand.color("claude") }
        if trend.series.meterID == "session" { return .mint }
        return Color(red: 0.70, green: 0.65, blue: 1)
    }
    private var title: String {
        if trend.series.isFable { return trend.series.label }
        if trend.series.meterID == "session" { return L10n.t("Session") }
        if trend.series.meterID == "weekly_all" { return L10n.t("Week · all models") }
        return trend.series.label
    }
    private var inspected: UsageHistoryPoint? {
        guard let selectedDate else { return trend.points.last }
        return trend.points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var consumed: Double? {
        let values = trend.days.compactMap(\.consumed)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(trend.series.formatted(inspected?.value))
                .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
            Text(inspected?.date.formatted(date: .abbreviated, time: .shortened) ?? L10n.t("No readings in this period yet"))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
            HistoryEvolutionChart(points: trend.chartPoints, quota: trend.series.kind == .quota,
                start: start, end: end, tint: tint, selectedDate: $selectedDate)
                .frame(height: 155)
            HStack {
                Text(L10n.t("Observed consumption")).foregroundStyle(dashboardMuted)
                Spacer(minLength: 4)
                Text(trend.series.formatted(consumed, delta: true)).foregroundStyle(tint).fontWeight(.semibold)
            }.font(.system(size: 11))
            Divider().overlay(.white.opacity(0.06))
            Text(L10n.t("Daily consumption · pp")).font(.system(size: 11, weight: .medium))
            daily.frame(height: 95)
            Text(L10n.t("Activity calendar")).font(.system(size: 11, weight: .medium))
            HistoryCalendar(days: trend.days, tint: tint)
            Text(L10n.t("Saved readings: \(trend.points.count)"))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted)
        }.historyPanel()
            .onChange(of: start) { _, _ in selectedDate = nil }
    }

    private var daily: some View {
        Chart(trend.days) { day in
            if let consumed = day.consumed {
                BarMark(x: .value(L10n.t("Day"), day.date, unit: .day),
                        y: .value(L10n.t("Observed consumption"), consumed))
                    .foregroundStyle(tint.gradient).cornerRadius(3)
                if consumed == 0 {
                    PointMark(x: .value(L10n.t("Day"), day.date, unit: .day),
                              y: .value(L10n.t("Observed consumption"), 0))
                        .foregroundStyle(tint).symbolSize(12)
                }
            }
        }
        .chartXScale(domain: start...endOfDay)
        .chartYScale(domain: 0...max(1, (trend.days.compactMap(\.consumed).max() ?? 0) * 1.15))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
    }
}
