import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class UsageHistoryModel: ObservableObject {
    @Published private(set) var catalogue: [UsageHistorySeries] = []
    @Published private(set) var points: [UsageHistoryPoint] = []
    @Published private(set) var days: [UsageHistoryDay] = []
    @Published private(set) var chartPoints: [UsageHistoryPoint] = []
    @Published private(set) var trends: [UsageHistoryTrend] = []
    @Published private(set) var globalDays: [UsageHistoryDay] = []
    @Published private(set) var providerTrends: [UsageHistoryTrend] = []
    @Published private(set) var modelUsage: [ModelUsageTrend] = []
    @Published private(set) var isLoadingModelUsage = false
    @Published private(set) var isLoading = false
    @Published var recordingError = false
    @Published private(set) var error: String?
    @Published var providerID = "all" { didSet { if oldValue != providerID { selectionChanged() } } }
    @Published var seriesID = "" { didSet { if oldValue != seriesID { selectionChanged() } } }
    @Published var range = 30 { didSet { if oldValue != range { selectionChanged() } } }
    @Published private(set) var start = Calendar.current.startOfDay(for: Date())
    @Published private(set) var end = Date()
    private let database: UsageHistoryDatabase?
    private let localUsage: LocalModelUsage?
    private var loadTask: Task<Void, Never>?
    private var modelUsageTask: Task<Void, Never>?
    private var selecting = false

    init(url: URL? = nil, localUsage: LocalModelUsage? = nil) {
        self.localUsage = localUsage
        database = url.map { UsageHistoryDatabase(url: $0) }
        if database != nil { reload() }
    }

    /// What a dashboard shows: this Mac's saved readings beside its own session
    /// logs. Every dashboard is built from here, so none can be left without one
    /// of the two.
    static func live() -> UsageHistoryModel {
        UsageHistoryModel(url: UsageHistoryDatabase.defaultURL, localUsage: LocalModelUsage())
    }

    var availableSeries: [UsageHistorySeries] {
        catalogue.filter { $0.providerID == providerID }.sorted(by: UsageHistorySeries.displayOrder)
    }
    var showsAllQuotas: Bool { Self.showsAllQuotas(providerID) }
    var showsModelUsage: Bool { localUsage != nil && showsAllQuotas }
    /// Services whose page is one card per quota rather than one picked series.
    static func showsAllQuotas(_ providerID: String) -> Bool { ["claude", "codex"].contains(providerID) }
    var exportableTrends: [UsageHistoryTrend] {
        if showsAllQuotas { return providerTrends.filter { !$0.points.isEmpty } }
        guard let series = selectedSeries, !points.isEmpty else { return [] }
        return [UsageHistoryTrend(series: series, points: points, days: days, chartPoints: chartPoints)]
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
        points = []; chartPoints = []; days = []; trends = []; globalDays = []; providerTrends = []
        modelUsageTask?.cancel(); modelUsageTask = nil
        modelUsage = []; isLoadingModelUsage = false
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
        reloadModelUsage(provider: provider, from: since, through: now, calendar: calendar)
        loadTask = Task {
            do {
                let catalogue = try await database.catalogue()
                let available = catalogue.filter { $0.providerID == provider }.sorted(by: UsageHistorySeries.displayOrder)
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
                var providerTrends: [UsageHistoryTrend] = []
                if Self.showsAllQuotas(provider) {
                    for quota in UsageHistoryGlobal.quotas(available) {
                        guard !Task.isCancelled else { return }
                        var readings: [UsageHistoryPoint] = []
                        for series in quota {
                            if series.id == selected?.id { readings += points }
                            else { readings += try await database.points(for: series.id, from: since, through: now) }
                        }
                        if quota.count > 1 { readings.sort { $0.date < $1.date } }
                        let series = quota[0]
                        providerTrends.append(UsageHistoryTrend(series: series, points: readings,
                            days: UsageHistoryAnalysis.daily(readings, kind: series.kind, from: since, through: now, calendar: calendar),
                            chartPoints: UsageHistoryAnalysis.chartPoints(readings)))
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
                self.providerTrends = providerTrends
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

    private func reloadModelUsage(provider: String, from start: Date, through end: Date, calendar: Calendar) {
        // The first read of a month of session logs takes seconds. It runs
        // beside the quota cards rather than holding them back, and a reload
        // that arrives meanwhile must not start it over.
        guard let localUsage, Self.showsAllQuotas(provider), modelUsageTask == nil else { return }
        isLoadingModelUsage = modelUsage.isEmpty
        modelUsageTask = Task {
            let usage = await localUsage.usage(providerID: provider, from: start, through: end, calendar: calendar)
            guard !Task.isCancelled else { return }
            modelUsage = usage
            isLoadingModelUsage = false
            modelUsageTask = nil
        }
    }

    func formatted(_ value: Double?, delta: Bool = false) -> String {
        selectedSeries?.formatted(value, delta: delta) ?? "—"
    }

    func exportCSV() {
        let entries = exportableTrends
        guard let series = entries.first?.series else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = showsAllQuotas ? "codenotch-\(series.providerID)-history.csv" : "codenotch-\(series.providerID)-\(series.meterID).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try UsageHistoryCSV.encode(entries).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = L10n.t("The CSV could not be saved to the selected location.") }
    }
}
