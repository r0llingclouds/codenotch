import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class UsageHistoryModel: ObservableObject {
    @Published private(set) var catalogue: [UsageHistorySeries] = []
    @Published private(set) var points: [UsageHistoryPoint] = []
    @Published private(set) var days: [UsageHistoryDay] = []
    @Published private(set) var chartPoints: [UsageHistoryChartPoint] = []
    @Published private(set) var trends: [UsageHistoryTrend] = []
    @Published private(set) var globalDays: [UsageHistoryDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var providerID = "all" { didSet { if oldValue != providerID { selectionChanged() } } }
    @Published var seriesID = "" { didSet { if oldValue != seriesID { selectionChanged() } } }
    @Published var range = 30 { didSet { if oldValue != range { selectionChanged() } } }
    @Published private(set) var start = Calendar.current.startOfDay(for: Date())
    @Published private(set) var end = Date()
    private let database: UsageHistoryDatabase?
    private var loadTask: Task<Void, Never>?
    private var selecting = false

    init(url: URL? = nil) {
        database = url.map { UsageHistoryDatabase(url: $0) }
        if database != nil { reload() }
    }

    var availableSeries: [UsageHistorySeries] {
        catalogue.filter { $0.providerID == providerID }.sorted {
            if $0.isFable != $1.isFable { return $0.isFable }
            return $0.meterID < $1.meterID
        }
    }
    var selectedSeries: UsageHistorySeries? { availableSeries.first { $0.id == seriesID } }
    var firstRecordedAt: Date? { catalogue.map(\.firstAt).min() }
    var recordedDays: Int { days.filter { $0.readings > 0 }.count }
    var consumed: Double? {
        let values = days.compactMap(\.consumed)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    func record(_ snapshot: ProviderSnapshot, at date: Date) {
        let records = UsageHistoryRecord.readings(from: snapshot, at: date)
        guard let database, !records.isEmpty else { return }
        Task {
            do {
                try await database.append(records)
                reload()
            } catch {
                self.error = L10n.t("History could not be saved. Check available disk space and folder access.")
            }
        }
    }

    func selectProvider(_ id: String) { providerID = id }

    private func selectionChanged() {
        guard !selecting else { return }
        // Never briefly display the previous provider's numbers with new units.
        points = []; chartPoints = []; days = []; trends = []; globalDays = []
        reload()
    }

    func reload() {
        guard let database, !selecting else { return }
        loadTask?.cancel()
        let provider = providerID
        let requestedSeries = seriesID
        let now = Date()
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -(range - 1), to: calendar.startOfDay(for: now))!
        isLoading = true
        loadTask = Task {
            do {
                let catalogue = try await database.catalogue()
                let available = catalogue.filter { $0.providerID == provider }
                let selected = available.first { $0.id == requestedSeries }
                    ?? available.first { $0.isFable } ?? available.first
                let points: [UsageHistoryPoint]
                if let selected { points = try await database.points(for: selected.id, from: since, through: now) }
                else { points = [] }
                var trends: [UsageHistoryTrend] = []
                if provider == "all" {
                    for item in UsageWidgetSnapshot.catalogue {
                        guard !Task.isCancelled else { return }
                        guard let series = UsageHistoryGlobal.primarySeries(providerID: item.id, catalogue: catalogue) else { continue }
                        let readings = try await database.points(for: series.id, from: since, through: now)
                        trends.append(UsageHistoryTrend(series: series, points: readings,
                            days: UsageHistoryAnalysis.daily(readings, kind: series.kind, from: since, through: now, calendar: calendar),
                            chartPoints: UsageHistoryAnalysis.chartPoints(readings, limit: 240)))
                    }
                }
                guard !Task.isCancelled else { return }
                self.catalogue = catalogue
                selecting = true
                seriesID = selected?.id ?? ""
                selecting = false
                self.points = points
                self.chartPoints = UsageHistoryAnalysis.chartPoints(points)
                self.trends = trends
                self.globalDays = UsageHistoryGlobal.activity(trends, from: since, through: now, calendar: calendar)
                self.days = UsageHistoryAnalysis.daily(points, kind: selected?.kind ?? .quota,
                    from: since, through: now, calendar: calendar)
                start = since; end = now
                error = nil; isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = L10n.t("History could not be loaded. Your saved data has not been changed.")
                isLoading = false
            }
        }
    }

    func formatted(_ value: Double?, delta: Bool = false) -> String {
        selectedSeries?.formatted(value, delta: delta) ?? "—"
    }

    func exportCSV() {
        guard let series = selectedSeries, !points.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codenotch-\(series.providerID)-\(series.meterID).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["date,provider,meter,unit,value,resets_at"]
        lines += points.map { point in
            [formatter.string(from: point.date), series.providerID, series.meterID, series.unit,
             String(point.value), point.resetsAt.map(formatter.string) ?? ""].map(cell).joined(separator: ",")
        }
        do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = L10n.t("The CSV could not be saved to the selected location.") }
    }
}
