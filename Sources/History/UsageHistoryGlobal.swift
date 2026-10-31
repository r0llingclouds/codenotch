import Foundation

struct UsageHistoryTrend: Identifiable {
    var id: String { series.providerID }
    let series: UsageHistorySeries
    let points: [UsageHistoryPoint]
    let days: [UsageHistoryDay]
    let chartPoints: [UsageHistoryPoint]
    var name: String { UsageWidgetSnapshot.catalogue.first { $0.id == id }?.name ?? id }
}

enum UsageHistoryGlobal {
    /// Keep one labeled quota per service. Overlapping session/model/weekly
    /// meters describe the same work and must never be added together.
    static func primarySeries(providerID: String, catalogue: [UsageHistorySeries]) -> UsageHistorySeries? {
        let series = catalogue.filter { $0.providerID == providerID }
        guard let latest = series.map(\.lastAt).max() else { return nil }
        let current = series.filter { latest.timeIntervalSince($0.lastAt) < UsageHistoryAnalysis.maximumGap }
        let preferred: [String]
        switch providerID {
        case "claude": preferred = ["weekly_all", "session"]
        case "codex": preferred = ["primary", "secondary"]
        case "kimi": preferred = ["monthly", "rolling"]
        case "glm": preferred = ["weekly", "session"]
        case "gemini-chat", "notebooklm": preferred = ["weekly", "current"]
        default: preferred = []
        }
        for id in preferred {
            if let match = current.first(where: { $0.meterID == id }) { return match }
        }
        return current.first
    }

    /// The quota that covers everything a service runs: its weekly window,
    /// where it reports one.
    static func totalQuota(_ trends: [UsageHistoryTrend]) -> UsageHistoryTrend? {
        for id in ["weekly_all", "secondary", "primary"] {
            if let match = trends.first(where: { $0.series.meterID == id }) { return match }
        }
        return trends.first
    }

    /// Series that are one quota saved under two names. Claude's CLI names its
    /// model quota after the model (`weekly_fable`), while the endpoint calls
    /// the same window `weekly_scoped` and names the model only in the label.
    static func quotas(_ series: [UsageHistorySeries]) -> [[UsageHistorySeries]] {
        func model(_ item: UsageHistorySeries) -> String? {
            guard item.providerID == "claude", item.meterID.hasPrefix("weekly_"), item.meterID != "weekly_all" else { return nil }
            return item.isFable ? "fable" : item.label.lowercased()
        }
        return series.reduce(into: []) { groups, item in
            if let name = model(item), let index = groups.firstIndex(where: { model($0[0]) == name && $0[0].kind == item.kind }) {
                groups[index].append(item)
            } else { groups.append([item]) }
        }
    }

    static func activity(_ trends: [UsageHistoryTrend], from start: Date, through end: Date,
                         calendar: Calendar = .current) -> [UsageHistoryDay] {
        let emptyDays = UsageHistoryAnalysis.daily([], kind: .quota, from: start, through: end, calendar: calendar)
        return emptyDays.map { day in
            let observations = trends.compactMap { $0.days.first { $0.date == day.date } }
            let comparable = observations.compactMap(\.consumed)
            return UsageHistoryDay(date: day.date, readings: observations.filter { $0.readings > 0 }.count,
                peak: nil, consumed: comparable.isEmpty ? nil : Double(comparable.filter { $0 > 0 }.count))
        }
    }
}

extension UsageHistorySeries {
    static func displayOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        // The whole allowance first, then the model that has a quota of its own.
        func rank(_ series: Self) -> Int { ["weekly_all", "primary"].contains(series.meterID) ? 0 : series.isFable ? 1 : 2 }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        if lhs.meterID != rhs.meterID { return lhs.meterID < rhs.meterID }
        return lhs.label < rhs.label
    }

    func formatted(_ value: Double?, delta: Bool = false) -> String {
        guard let value else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(0...(kind == .balance ? 2 : 1))))
        let suffix = kind == .quota && delta ? L10n.t("pp") : unit
        return "\(number) \(suffix == "credits" ? L10n.t("credits") : suffix)"
    }
}

enum UsageHistoryCSV {
    static func encode(_ trends: [UsageHistoryTrend]) -> String {
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["date,provider,meter,label,unit,value,resets_at"]
        for trend in trends {
            lines += trend.points.map { point in
                [formatter.string(from: point.date), trend.series.providerID, trend.series.meterID,
                 trend.series.label, trend.series.unit, String(point.value),
                 point.resetsAt.map(formatter.string) ?? ""].map(cell).joined(separator: ",")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
