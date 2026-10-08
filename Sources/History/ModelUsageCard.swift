import Charts
import SwiftUI

/// Tokens one model spent, from its CLI's own session logs. A different
/// measure from a quota card: neither service says which model spent its
/// allowance, so this is a count and not a share of a limit.
struct ModelUsageCard: View {
    let usage: ModelUsageTrend
    let share: Double
    let start: Date
    let end: Date
    let tint: Color
    private var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(usage.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(ModelUsageTrend.compact(Double(usage.tokens.total)))
                .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
            Text(L10n.t("Tokens on this Mac · selected period")).font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
            daily.frame(height: 155)
            row(L10n.t("Share of tokens"), "\((share * 100).formatted(.number.precision(.fractionLength(0)))) %", emphasized: true)
            Divider().overlay(.white.opacity(0.06))
            row(L10n.t("Uncached input"), ModelUsageTrend.compact(Double(usage.tokens.input)))
            row(L10n.t("Output"), ModelUsageTrend.compact(Double(usage.tokens.output)))
            row(L10n.t("Cached input · not counted"), ModelUsageTrend.compact(Double(usage.tokens.cached)))
            Text(L10n.t("Activity calendar")).font(.system(size: 11, weight: .medium))
            HistoryCalendar(days: usage.days, tint: tint, valueLabel: L10n.t("Tokens"))
            Text(L10n.t("Responses counted: \(usage.tokens.responses)"))
                .font(.system(size: 10)).foregroundStyle(dashboardMuted)
        }.frame(maxHeight: .infinity, alignment: .top).historyPanel()
    }

    private func row(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(dashboardMuted)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(emphasized ? tint : .primary).fontWeight(emphasized ? .semibold : .regular).monospacedDigit()
        }.font(.system(size: 11))
    }

    private var daily: some View {
        Chart(usage.days) { day in
            if let tokens = day.consumed {
                BarMark(x: .value(L10n.t("Day"), day.date, unit: .day), y: .value(L10n.t("Tokens"), tokens))
                    .foregroundStyle(tint.gradient).cornerRadius(3)
            }
        }
        .chartXScale(domain: start...endOfDay)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: start.distance(to: end) < 86_400 ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated)) }
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(.white.opacity(0.14)) }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.05))
                AxisValueLabel { if let tokens = value.as(Double.self) { Text(ModelUsageTrend.compact(tokens)) } }
            }
        }
    }
}
