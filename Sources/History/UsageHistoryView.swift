import Charts
import SwiftUI

struct HistoryRecordingBadge: View {
    @ObservedObject var model: UsageHistoryModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.error == nil ? Color.mint : .orange).frame(width: 5, height: 5)
            Text(model.error == nil ? L10n.t("History saved on this Mac") : L10n.t("History needs attention"))
        }
        .font(.system(size: 11)).foregroundStyle(dashboardMuted)
        .help(model.error ?? L10n.t("Readings are saved automatically while Codenotch is running."))
    }
}

struct UsageHistoryView: View {
    @ObservedObject var model: UsageHistoryModel
    @State private var selectedDate: Date?
    private var tint: Color { DashboardBrand.color(model.providerID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providers
                controls
                if let error = model.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button(L10n.t("Retry")) { model.reload() }
                    }.font(.system(size: 12)).foregroundStyle(.orange)
                }
                if model.providerID == "all" {
                    UsageHistoryGlobalView(model: model)
                } else {
                    summary
                    evolution
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            daily.frame(minWidth: 440)
                            calendar.frame(minWidth: 290)
                        }
                        VStack(spacing: 18) { daily; calendar }
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "internaldrive")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("Your history stays on this Mac. Export any series as CSV."))
                        Text(L10n.t("Recording continues with the window closed, while Codenotch is running. Days without readings stay empty."))
                    }
                }.font(.system(size: 11)).foregroundStyle(dashboardMuted)
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .onAppear { model.reload() }
        .onChange(of: model.seriesID) { _, _ in selectedDate = nil }
        .onChange(of: model.range) { _, _ in selectedDate = nil }
    }

    private var providers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { model.selectProvider("all") } label: {
                    Label(L10n.t("All services"), systemImage: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white.opacity(model.providerID == "all" ? 0.13 : 0.035), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(model.providerID == "all" ? 0.4 : 0.12)))
                }.buttonStyle(.plain).accessibilityAddTraits(model.providerID == "all" ? .isSelected : [])
                ForEach(UsageWidgetSnapshot.catalogue, id: \.id) { provider in
                    HistoryProviderButton(id: provider.id, name: provider.name,
                        selected: provider.id == model.providerID,
                        action: { model.selectProvider(provider.id) })
                }
            }.padding(.vertical, 2)
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.providerID == "all" ? L10n.t("Global history") : L10n.t("Usage over time"))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                if let date = model.firstRecordedAt {
                    Text(L10n.t("Recording since \(date.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                } else {
                    Text(L10n.t("Waiting for the first fresh reading"))
                        .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                }
            }
            Spacer(minLength: 5)
            if !model.availableSeries.isEmpty {
                Picker(L10n.t("Quota or balance"), selection: $model.seriesID) {
                    ForEach(model.availableSeries) { series in Text(series.label).tag(series.id) }
                }.labelsHidden().frame(maxWidth: 170)
            }
            Picker(L10n.t("Date range"), selection: $model.range) {
                Text(L10n.t("Today")).tag(1)
                Text(L10n.t("7D")).tag(7)
                Text(L10n.t("30D")).tag(30)
                Text(L10n.t("90D")).tag(90)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            if model.providerID != "all" {
              Button(action: model.exportCSV) { Image(systemName: "square.and.arrow.up") }
                .help(L10n.t("Export this series as CSV")).accessibilityLabel(L10n.t("Export CSV"))
                .disabled(model.points.isEmpty)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            HistoryStat(title: L10n.t("Latest reading"), value: model.formatted(model.points.last?.value),
                detail: model.selectedSeries?.label ?? L10n.t("No readings yet"), tint: tint)
            HistoryStat(title: L10n.t("Observed consumption"), value: model.formatted(model.consumed, delta: true),
                detail: model.selectedSeries?.kind == .quota ? L10n.t("Percentage points · selected period") : L10n.t("Selected period"), tint: tint)
            HistoryStat(title: L10n.t("Days recorded"), value: "\(model.recordedDays) / \(model.range)",
                detail: L10n.t("Saved readings: \(model.points.count)"), tint: tint)
        }
    }

    private var inspected: UsageHistoryPoint? {
        guard let selectedDate else { return model.points.last }
        return model.points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var evolution: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedSeries?.kind == .quota ? L10n.t("Quota evolution") : L10n.t("Balance & usage evolution"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("Each point is a saved reading. Gaps and resets break the line."))
                        .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                }
                Spacer()
                if let inspected {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.formatted(inspected.value)).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                        Text(inspected.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(dashboardMuted)
                    }
                }
            }
            HistoryEvolutionChart(points: model.chartPoints, quota: model.selectedSeries?.kind == .quota,
                start: model.start, end: model.end, tint: tint, selectedDate: $selectedDate)
                .frame(height: 190)
                .overlay { if model.points.isEmpty { emptyState } }
            if model.recordedDays <= 1 && !model.points.isEmpty {
                Label(L10n.t("Your history starts today. Daily trends will fill in as readings accumulate."), systemImage: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(dashboardMuted)
            }
        }.historyPanel()
    }

    private var daily: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Daily consumption")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.selectedSeries?.kind == .quota ? L10n.t("percentage points") : model.selectedSeries?.unit ?? "")
                    .font(.system(size: 10)).foregroundStyle(dashboardMuted)
            }
            Chart(model.days) { day in
                if let consumed = day.consumed {
                    BarMark(x: .value(L10n.t("Day"), day.date, unit: .day), y: .value(L10n.t("Observed consumption"), consumed))
                        .foregroundStyle(tint.gradient).cornerRadius(3)
                    if consumed == 0 {
                        PointMark(x: .value(L10n.t("Day"), day.date, unit: .day), y: .value(L10n.t("Observed consumption"), 0))
                            .foregroundStyle(tint).symbolSize(15)
                    }
                }
            }
            .chartXScale(domain: model.start...chartEnd)
            .chartYScale(domain: 0...max(1, (model.days.compactMap(\.consumed).max() ?? 0) * 1.15))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
            .frame(height: 145)
            Text(L10n.t("Observed changes between nearby readings, not a billing total. The first reading, resets and offline periods are excluded."))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
        }.historyPanel()
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Activity calendar")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.selectedSeries?.label ?? "").font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
            }
            HistoryCalendar(days: model.days, tint: tint)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.12)).frame(width: 10, height: 10)
                Text(L10n.t("No data"))
                Spacer()
                Text(L10n.t("Less"))
                ForEach(1..<5) { step in RoundedRectangle(cornerRadius: 2).fill(tint.opacity(Double(step) / 4)).frame(width: 9, height: 9) }
                Text(L10n.t("More"))
            }.font(.system(size: 9)).foregroundStyle(dashboardMuted)
        }.historyPanel()
    }

    private var chartEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: model.end))! }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundStyle(tint)
            Text(model.isLoading ? L10n.t("Loading history…") : L10n.t("No readings in this period yet"))
                .font(.system(size: 13, weight: .medium))
            Text(L10n.t("New readings will appear automatically. Past days are not reconstructed."))
                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
        }.padding(18).background(Color(red: 0.09, green: 0.105, blue: 0.15), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct HistoryProviderButton: View {
    let id: String
    let name: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { DashboardBrand(id: id, size: 17); Text(name).font(.system(size: 12, weight: .medium)) }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(DashboardBrand.color(id).opacity(selected ? 0.16 : 0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(DashboardBrand.color(id).opacity(selected ? 0.5 : 0.12)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HistoryStat: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11)).foregroundStyle(dashboardMuted)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).historyPanel()
    }
}

private struct HistoryEvolutionChart: View {
    let points: [UsageHistoryChartPoint]
    let quota: Bool
    let start: Date
    let end: Date
    let tint: Color
    @Binding var selectedDate: Date?
    private var upper: Double { max(quota ? 100 : 1, (points.map(\.point.value).max() ?? 0) * 1.1) }
    private var endOfDay: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))! }
    var body: some View {
        Chart {
            ForEach(points) { item in
                LineMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Reading"), item.point.value),
                         series: .value("Window", item.segment))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value(L10n.t("Time"), item.point.date), y: .value(L10n.t("Reading"), item.point.value))
                    .foregroundStyle(tint).symbolSize(points.count < 50 ? 28 : 5)
            }
            if quota {
                RuleMark(y: .value(L10n.t("Limit"), 100))
                    .foregroundStyle(.white.opacity(0.15)).lineStyle(StrokeStyle(dash: [4, 4]))
            }
            if let selectedDate {
                RuleMark(x: .value(L10n.t("Selected date"), selectedDate)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .chartXScale(domain: start...endOfDay).chartYScale(domain: 0...upper)
        .chartXSelection(value: $selectedDate)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: start.distance(to: end) < 86_400 ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
        .chartLegend(.hidden)
    }
}

struct HistoryCalendar: View {
    let days: [UsageHistoryDay]
    let tint: Color
    var valueLabel: String = L10n.t("Observed change")
    private var offset: Int { days.first.map { (Calendar.current.component(.weekday, from: $0.date) + 5) % 7 } ?? 0 }
    private var columns: Int { max(1, Int(ceil(Double(days.count + offset) / 7))) }
    private var maximum: Double { max(1, days.compactMap(\.consumed).max() ?? 0) }
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { row in
                    Text(Calendar.current.veryShortWeekdaySymbols[(row + 1) % 7])
                        .font(.system(size: 9)).foregroundStyle(dashboardMuted).frame(height: 16)
                }
            }.padding(.trailing, 3)
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { row in
                        cell(index: column * 7 + row - offset)
                    }
                }.frame(maxWidth: 26)
            }
            Spacer(minLength: 0)
        }.frame(height: 145, alignment: .top)
    }
    @ViewBuilder private func cell(index: Int) -> some View {
        if days.indices.contains(index) {
            let day = days[index]
            let opacity = day.consumed.map { $0 > 0 ? 0.3 + 0.7 * $0 / maximum : 0.12 } ?? (day.readings > 0 ? 0.08 : 0)
            let label = day.date.formatted(date: .abbreviated, time: .omitted) + ": " +
                (day.consumed.map { "\(valueLabel): \($0.formatted(.number.precision(.fractionLength(0...2))))" }
                    ?? (day.readings > 0 ? L10n.t("First reading saved") : L10n.t("No readings")))
            RoundedRectangle(cornerRadius: 3).fill(tint.opacity(opacity))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(day.readings > 0 ? 0.17 : 0.07)))
                .frame(height: 16).help(label).accessibilityLabel(label)
        } else { Color.clear.frame(height: 16) }
    }
}

extension View {
    func historyPanel() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.065)))
    }
}
