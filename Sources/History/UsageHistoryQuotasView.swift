import Charts
import SwiftUI

/// The same page for every service that has it: the whole allowance leads at
/// full width, and below it come the strongest model the service sells, the
/// model most work runs on, and whatever else it meters or ran.
///
/// A model gets a quota card where the service meters it and a token card
/// where it does not: only one of the two services says how much of the
/// allowance a model spent.
struct UsageHistoryQuotasView: View {
    @ObservedObject var model: UsageHistoryModel

    private enum Card: Identifiable {
        case quota(UsageHistoryTrend, tokens: ModelUsageTrend?)
        case model(ModelUsageTrend)
        case waiting(title: String, message: String)

        var id: String {
            switch self {
            case .quota(let trend, _): return "quota-" + trend.series.id
            case .model(let usage): return "model-" + usage.model
            case .waiting(let title, _): return "waiting-" + title
            }
        }
    }

    private var tint: Color { DashboardBrand.color(model.providerID) }
    private var source: String { model.providerID == CodexProfile.defaultID ? "Codex" : "Claude Code" }
    private var lineup: ModelLineup? { model.showsModelUsage ? ModelLineup.known[model.providerID] : nil }
    private var tokens: Int { model.modelUsage.reduce(0) { $0 + $1.tokens.total } }
    private var flagship: ModelUsageTrend? { lineup.flatMap { ModelUsageTrend.newest(of: $0.flagship, in: model.modelUsage) } }
    private var standard: ModelUsageTrend? { lineup.flatMap { ModelUsageTrend.newest(of: $0.standard, in: model.modelUsage) } }
    /// Models that have neither of the two leading cards.
    private var others: [ModelUsageTrend] {
        model.modelUsage.filter { $0.model != flagship?.model && $0.model != standard?.model }
    }
    /// A model that spent under 1 % of the period's tokens gets a line, not a card.
    private var minor: [ModelUsageTrend] { others.filter { $0.tokens.total * 100 < tokens } }

    private var cards: [Card] {
        let quotas = model.providerTrends
        guard let lineup else { return quotas.map { .quota($0, tokens: nil) } }
        let total = UsageHistoryGlobal.totalQuota(quotas)
        // Only Claude meters its strongest model; its card is that quota.
        let metered = quotas.first {
            $0.series.id != total?.series.id && $0.series.label.localizedCaseInsensitiveContains(lineup.flagship)
        }
        let missing = model.isLoadingModelUsage ? L10n.t("Reading local sessions…")
            : L10n.t("No sessions with this model on this Mac in this period")
        var cards: [Card] = []
        if let total { cards.append(.quota(total, tokens: nil)) }
        else {
            cards.append(.waiting(title: L10n.t("Total quota"),
                                  message: model.isLoading ? L10n.t("Loading history…") : L10n.t("Waiting for readings")))
        }
        if let metered { cards.append(.quota(metered, tokens: flagship)) }
        else if let flagship { cards.append(.model(flagship)) }
        else { cards.append(.waiting(title: lineup.flagship.capitalized, message: missing)) }
        if let standard { cards.append(.model(standard)) }
        else { cards.append(.waiting(title: lineup.standard.capitalized, message: missing)) }
        for quota in quotas where quota.series.id != total?.series.id && quota.series.id != metered?.series.id {
            cards.append(.quota(quota, tokens: nil))
        }
        for usage in others where usage.tokens.total * 100 >= tokens { cards.append(.model(usage)) }
        return cards
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if cards.isEmpty {
                Label(model.isLoading ? L10n.t("Loading history…") : L10n.t("Waiting for readings"),
                      systemImage: "chart.xyaxis.line")
                    .foregroundStyle(dashboardMuted).historyPanel()
            } else {
                // The total quota is what the rest is read against.
                if lineup != nil, let total = cards.first { view(for: total, wide: true) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                                         count: lineup == nil ? min(3, cards.count) : 3),
                          alignment: .leading, spacing: 14) {
                    ForEach(lineup == nil ? cards : Array(cards.dropFirst())) { view(for: $0) }
                }
            }
            Group {
                if model.providerTrends.count > 1 {
                    Text(L10n.t("Each quota has its own reset window. Daily changes are shown separately because the quotas overlap."))
                }
                Text(L10n.t("Observed changes between nearby readings, not a billing total. The first reading, resets and offline periods are excluded."))
                if lineup != nil {
                    Text(L10n.t("Model cards count tokens from \(source) sessions saved on this Mac: uncached input plus output. They are not a share of the quota, and work on other devices is not included."))
                    if !minor.isEmpty {
                        let names = minor.map { "\($0.name) (\(ModelUsageTrend.compact(Double($0.tokens.total))))" }.joined(separator: ", ")
                        Text(L10n.t("Under 1 % of the tokens each, so without a card: \(names)"))
                    }
                }
            }.font(.system(size: 11)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func view(for card: Card, wide: Bool = false) -> some View {
        switch card {
        case .quota(let trend, let tokens):
            QuotaHistoryCard(trend: trend, tokens: tokens, wide: wide, start: model.start, end: model.end)
        case .model(let usage):
            ModelUsageCard(usage: usage, share: Double(usage.tokens.total) / Double(max(1, tokens)),
                           start: model.start, end: model.end, tint: tint)
        case .waiting(let title, let message):
            WaitingHistoryCard(title: title, message: message, tint: tint)
        }
    }
}

/// Holds a card's place while there is nothing to draw in it, so the leading
/// cards stay where they are on every service.
private struct WaitingHistoryCard: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(tint.opacity(0.4)).frame(width: 7, height: 7)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text("—").font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(dashboardMuted)
            Text(message).font(.system(size: 11)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxHeight: .infinity, alignment: .top).historyPanel()
    }
}

private struct QuotaHistoryCard: View {
    let trend: UsageHistoryTrend
    /// What the metered model spent in this Mac's own sessions, where known.
    var tokens: ModelUsageTrend?
    /// Spans the page: a taller chart, with the daily bars beside the calendar.
    var wide = false
    let start: Date
    let end: Date
    @State private var selectedDate: Date?
    private var tint: Color { DashboardBrand.color(trend.series.providerID) }
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
                .frame(height: wide ? 190 : 155)
            HStack {
                Text(L10n.t("Observed consumption")).foregroundStyle(dashboardMuted)
                Spacer(minLength: 4)
                Text(trend.series.formatted(consumed, delta: true)).foregroundStyle(tint).fontWeight(.semibold)
            }.font(.system(size: 11))
            if let tokens {
                HStack {
                    Text(L10n.t("Tokens on this Mac")).foregroundStyle(dashboardMuted)
                    Spacer(minLength: 4)
                    Text(ModelUsageTrend.compact(Double(tokens.tokens.total))).foregroundStyle(tint).fontWeight(.semibold)
                }.font(.system(size: 11))
            }
            Divider().overlay(.white.opacity(0.06))
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.t("Daily consumption · pp")).font(.system(size: 11, weight: .medium))
                        daily.frame(height: 145)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.t("Activity calendar")).font(.system(size: 11, weight: .medium))
                        HistoryCalendar(days: trend.days, tint: tint)
                    }.frame(width: 290, alignment: .leading)
                }
            } else {
                Text(L10n.t("Daily consumption · pp")).font(.system(size: 11, weight: .medium))
                daily.frame(height: 95)
                Text(L10n.t("Activity calendar")).font(.system(size: 11, weight: .medium))
                HistoryCalendar(days: trend.days, tint: tint)
            }
            Text(L10n.t("Saved readings: \(trend.points.count)"))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted)
        }.frame(maxHeight: .infinity, alignment: .top).historyPanel()
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
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: wide ? 5 : 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.05)); AxisValueLabel() } }
    }
}
