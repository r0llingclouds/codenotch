import Combine
import XCTest
@testable import Codenotch

final class UsageHistoryTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_020_800) // 2026-09-22 UTC
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func point(_ minutes: Double, _ value: Double, reset: Date? = nil) -> UsageHistoryPoint {
        UsageHistoryPoint(date: day.addingTimeInterval(minutes * 60), value: value, resetsAt: reset)
    }

    private func snapshot(_ windows: [LimitWindow], id: String = "claude", status: ProviderStatus = .ok) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: "Provider", glyph: .claude, fidelity: .official,
                         status: status, windows: windows)
    }

    func testRecordsOnlyFreshSupportedNumericalReadings() {
        let windows = [LimitWindow(id: "fable", label: "Fable", usedFraction: 0.26),
                       LimitWindow(id: "invalid", label: "Invalid", usedFraction: .nan),
                       LimitWindow(id: "unknown", label: "Unknown", detail: "No denominator")]
        let records = UsageHistoryRecord.readings(from: snapshot(windows), at: day)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.point.value, 26)
        XCTAssertEqual(records.first?.series.kind, .quota)
        for status in [ProviderStatus.stale(since: day), .needsAuth, .error("Offline"), .signedOutByOwner] {
            XCTAssertTrue(UsageHistoryRecord.readings(from: snapshot(windows, status: status), at: day).isEmpty)
        }
        XCTAssertTrue(UsageHistoryRecord.readings(from: snapshot(windows, id: "unknown"), at: day).isEmpty)
    }

    func testBalancesAndCreditsKeepUnitsInsteadOfFabricatedPercentages() throws {
        let money = LimitWindow(id: "balance", label: "Balance", usedFraction: 0.3,
            money: UsageMoneyBreakdown(currency: "USD", spent: 10, remaining: 49.99))
        let record = try XCTUnwrap(UsageHistoryRecord.readings(from: snapshot([money], id: "deepseek"), at: day).first)
        XCTAssertEqual(record.series.kind, .balance)
        XCTAssertEqual(record.series.unit, "USD")
        XCTAssertEqual(record.point.value, 49.99)
        let credits = LimitWindow(id: "credits", label: "Credits", remaining: 1050)
        let flow = try XCTUnwrap(UsageHistoryRecord.readings(from: snapshot([credits], id: "google-flow"), at: day).first)
        XCTAssertEqual(flow.series.kind, .remaining)
        XCTAssertEqual(flow.series.unit, "credits")
        XCTAssertEqual(flow.point.value, 1050)
    }

    func testModelLabelAndCurrencyChangesCannotMergeUnrelatedSeries() {
        func id(_ label: String) -> String? {
            UsageHistoryRecord.readings(from: snapshot([LimitWindow(id: "weekly_scoped", label: label, usedFraction: 0.2)]), at: day).first?.series.id
        }
        XCTAssertNotEqual(id("Fable"), id("Sonnet"))
        XCTAssertEqual(id("Fable"), id("Fable"))
    }

    func testDatabasePersistsAcrossInstancesAndDeduplicatesReplayedReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let records = UsageHistoryRecord.readings(from: snapshot([
            LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.26, resetsAt: day.addingTimeInterval(3600)),
            LimitWindow(id: "session", label: "Session", usedFraction: 0.08)]), at: day)
        let database = UsageHistoryDatabase(url: url)
        try await database.append(records)
        try await database.append(records)
        let reopened = UsageHistoryDatabase(url: url)
        let catalogue = try await reopened.catalogue()
        XCTAssertEqual(catalogue.count, 2)
        let fable = try XCTUnwrap(catalogue.first { $0.isFable })
        let points = try await reopened.points(for: fable.id, from: day, through: day.addingTimeInterval(60))
        XCTAssertEqual(points, [records[0].point])
        let outside = try await reopened.points(for: fable.id, from: day.addingTimeInterval(1), through: day.addingTimeInterval(60))
        XCTAssertTrue(outside.isEmpty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOutOfOrderWritesKeepEarliestAndLatestMeasurementDates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let reading = snapshot([LimitWindow(id: "session", label: "Session", usedFraction: 0.2)])
        try await database.append(UsageHistoryRecord.readings(from: reading, at: day.addingTimeInterval(300)))
        try await database.append(UsageHistoryRecord.readings(from: reading, at: day))
        let catalogue = try await database.catalogue()
        XCTAssertEqual(catalogue.first?.firstAt, day)
        XCTAssertEqual(catalogue.first?.lastAt, day.addingTimeInterval(300))
    }

    func testInitialValueIsBaselineAndQuotaCorrectionsAreNotDoubleCounted() throws {
        let points = [point(0, 26), point(5, 28), point(10, 27), point(15, 28), point(20, 30)]
        let days = UsageHistoryAnalysis.daily(points, kind: .quota, from: day,
            through: day.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(days.first?.consumed, 4)
        XCTAssertEqual(days.first?.peak, 30)
        XCTAssertNil(days.last?.consumed, "No readings must not appear as zero usage")
        let single = UsageHistoryAnalysis.daily([point(0, 26)], kind: .quota, from: day, through: day, calendar: calendar)
        XCTAssertNil(single.first?.consumed)
    }

    func testResetsGapsAndMidnightDoNotCreateFalseConsumption() {
        let reset1 = day.addingTimeInterval(600)
        let reset2 = day.addingTimeInterval(20_000)
        let points = [point(0, 80, reset: reset1), point(5, 90, reset: reset1),
                      point(10, 5, reset: reset2), point(15, 8, reset: reset2),
                      point(90, 50, reset: reset2), point(95, 51, reset: reset2)]
        let days = UsageHistoryAnalysis.daily(points, kind: .quota, from: day,
            through: day.addingTimeInterval(7200), calendar: calendar)
        XCTAssertEqual(days.first?.consumed, 14)
        let midnight = calendar.startOfDay(for: day).addingTimeInterval(86_400)
        let crossDay = [UsageHistoryPoint(date: midnight.addingTimeInterval(-300), value: 10, resetsAt: nil),
                        UsageHistoryPoint(date: midnight.addingTimeInterval(300), value: 15, resetsAt: nil)]
        let split = UsageHistoryAnalysis.daily(crossDay, kind: .quota, from: crossDay[0].date,
            through: crossDay[1].date, calendar: calendar)
        XCTAssertTrue(split.allSatisfy { $0.consumed == nil })
    }

    func testBalanceRefillsAreNotNegativeConsumption() {
        let days = UsageHistoryAnalysis.daily([point(0, 50), point(5, 48), point(10, 100), point(15, 99)],
            kind: .balance, from: day, through: day.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(days.first?.consumed, 3)
    }

    func testMeasuredZeroIsDifferentFromMissingData() {
        let days = UsageHistoryAnalysis.daily([point(0, 0), point(5, 0)], kind: .quota, from: day,
            through: day.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(days.first?.consumed, 0)
        XCTAssertEqual(days.first?.readings, 2)
        XCTAssertNil(days.last?.consumed)
        XCTAssertEqual(days.last?.readings, 0)
    }

    func testCalendarDaysFollowDSTInsteadOfAssuming24Hours() {
        var madrid = calendar
        madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = madrid.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let end = madrid.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let days = UsageHistoryAnalysis.daily([], kind: .quota, from: start, through: end, calendar: madrid)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[2].date.timeIntervalSince(days[1].date), 25 * 3600)
    }

    func testChartSegmentsDoNotBridgeOfflinePeriodsOrResets() {
        let points = [point(0, 10), point(5, 15), point(60, 30), point(65, 5, reset: day)]
        XCTAssertEqual(UsageHistoryAnalysis.chartPoints(points).map(\.segment), [0, 0, 1, 2])
        var many = (0..<5000).map { point(Double($0), 10) }
        many[2250] = point(2250, 99)
        let plotted = UsageHistoryAnalysis.chartPoints(many)
        XCTAssertLessThanOrEqual(plotted.count, 600)
        XCTAssertTrue(plotted.contains { $0.point.value == 99 })
        XCTAssertEqual(plotted.first?.point, many.first)
        XCTAssertEqual(plotted.last?.point, many.last)
    }

    func testGlobalViewKeepsFableAndDoesNotAddOverlappingClaudeQuotas() throws {
        let records = UsageHistoryRecord.readings(from: snapshot([
            LimitWindow(id: "session", label: "Session", usedFraction: 0.1),
            LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.2),
            LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.3)]), at: day)
        let chosen = try XCTUnwrap(UsageHistoryGlobal.primarySeries(providerID: "claude", catalogue: records.map(\.series)))
        XCTAssertTrue(chosen.isFable)
        XCTAssertEqual(chosen.meterID, "weekly_scoped")
        XCTAssertNil(UsageHistoryGlobal.primarySeries(providerID: "deepseek", catalogue: records.map(\.series)))
    }

    func testGlobalActivityCountsServicesInsteadOfAddingIncompatibleUnits() {
        func trend(_ id: String, kind: UsageHistorySeries.Kind, unit: String, values: [Double]) -> UsageHistoryTrend {
            let series = UsageHistorySeries(id: id, providerID: id, meterID: "meter", label: "Usage", kind: kind,
                unit: unit, firstAt: day, lastAt: day.addingTimeInterval(300))
            let points = values.enumerated().map { point(Double($0.offset) * 5, $0.element) }
            let days = UsageHistoryAnalysis.daily(points, kind: kind, from: day,
                through: day.addingTimeInterval(86_400), calendar: calendar)
            return UsageHistoryTrend(series: series, points: points, days: days,
                chartPoints: UsageHistoryAnalysis.chartPoints(points))
        }
        let trends = [trend("claude", kind: .quota, unit: "%", values: [26, 28]),
                      trend("deepseek", kind: .balance, unit: "USD", values: [50, 49]),
                      trend("google-flow", kind: .remaining, unit: "credits", values: [1050, 950]),
                      trend("codex", kind: .quota, unit: "%", values: [20, 20])]
        let activity = UsageHistoryGlobal.activity(trends, from: day, through: day.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(activity.first?.consumed, 3, "Three services, not 103 mixed units")
        XCTAssertEqual(activity.first?.readings, 4)
        XCTAssertNil(activity.last?.consumed)
        XCTAssertEqual(activity.last?.readings, 0)
    }

    func testGlobalSelectionDoesNotPreferAnObsoleteFableSeries() throws {
        let old = UsageHistoryRecord.readings(from: snapshot([LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.3)]), at: day)
        let fresh = UsageHistoryRecord.readings(from: snapshot([LimitWindow(id: "weekly_scoped", label: "Fable 5.1", usedFraction: 0.1)]), at: day.addingTimeInterval(3600))
        let chosen = UsageHistoryGlobal.primarySeries(providerID: "claude", catalogue: (old + fresh).map(\.series))
        XCTAssertEqual(chosen?.label, "Fable 5.1")
    }

    @MainActor
    func testClaudeLoadsEveryQuotaTogetherAndAppliesRangeToAllCharts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let database = UsageHistoryDatabase(url: url)
        let now = Date().addingTimeInterval(-60)
        let earlier = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let reading = snapshot([
            LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.19),
            LimitWindow(id: "session", label: "Current session", usedFraction: 0.12),
            LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.26)])
        try await database.append(UsageHistoryRecord.readings(from: reading, at: earlier))
        try await database.append(UsageHistoryRecord.readings(from: reading, at: now))
        let model = UsageHistoryModel(url: url)
        let loaded = expectation(description: "All Claude quotas loaded")
        let subscription = model.$isLoading.dropFirst().filter { !$0 }.first().sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        model.selectProvider("claude")
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.showsAllQuotas)
        XCTAssertEqual(model.providerTrends.map(\.series.meterID), ["weekly_scoped", "session", "weekly_all"])
        XCTAssertEqual(Set(model.providerTrends.map(\.series.id)).count, 3)
        XCTAssertEqual(model.providerTrends.map { $0.points.count }, [2, 2, 2])
        XCTAssertEqual(model.exportableTrends.count, 3)
        XCTAssertEqual(model.providerTrends.compactMap { $0.points.last?.value }, [26, 12, 19])

        let narrowed = expectation(description: "Date range applied to every quota")
        let rangeSubscription = model.$isLoading.dropFirst().filter { !$0 }.first().sink { _ in narrowed.fulfill() }
        defer { rangeSubscription.cancel() }
        model.range = 7
        await fulfillment(of: [narrowed], timeout: 5)
        XCTAssertEqual(model.providerTrends.map { $0.points.count }, [1, 1, 1])
        XCTAssertEqual(model.providerTrends.map { $0.days.count }, [7, 7, 7])
        model.selectProvider("deepseek")
        XCTAssertFalse(model.showsAllQuotas)
        XCTAssertTrue(model.providerTrends.isEmpty, "Switching provider clears the Claude charts immediately")
    }

    func testClaudeCSVIncludesEveryQuotaAndItsOwnValues() {
        let records = UsageHistoryRecord.readings(from: snapshot([
            LimitWindow(id: "session", label: "Current session", usedFraction: 0.12),
            LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.19),
            LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.26)]), at: day)
        let trends = records.map { UsageHistoryTrend(series: $0.series, points: [$0.point], days: [], chartPoints: []) }
        let csv = UsageHistoryCSV.encode(trends)
        XCTAssertEqual(csv.split(separator: "\n").count, 4)
        XCTAssertTrue(csv.contains("\"session\",\"Current session\",\"%\",\"12.0\""))
        XCTAssertTrue(csv.contains("\"weekly_all\",\"All models\",\"%\",\"19.0\""))
        XCTAssertTrue(csv.contains("\"weekly_scoped\",\"Fable\",\"%\",\"26.0\""))
    }

    func testSingleBalanceCSVPreservesMoneyAndEscapesLabels() throws {
        let record = try XCTUnwrap(UsageHistoryRecord.readings(from: snapshot([
            LimitWindow(id: "spend", label: "Balance, \"USD\"", money: UsageMoneyBreakdown(currency: "USD", spent: 10, remaining: 49.99))
        ], id: "deepseek"), at: day).first)
        let csv = UsageHistoryCSV.encode([UsageHistoryTrend(series: record.series, points: [record.point], days: [], chartPoints: [])])
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
        XCTAssertTrue(csv.contains("\"Balance, \"\"USD\"\"\",\"USD\",\"49.99\""))
    }
}
