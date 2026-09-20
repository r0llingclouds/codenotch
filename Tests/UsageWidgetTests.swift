import XCTest
@testable import Codenotch

final class GoogleUsagePagesTests: XCTestCase {
    func testSpanishGeminiCountersKeepWindowsSeparate() throws {
        let windows = try GoogleUsagePages.parseQuota("""
        Límites de uso
        Actualizado justo ahora
        Uso actual
        24 % usado
        Se restablece a las 16:44
        Límite semanal
        Se restablece el 21 sept a las 12:44
        7 % usado
        Disfruta de 5 veces más uso con AI Ultra
        """)
        XCTAssertEqual(windows.map(\.id), ["current", "weekly"])
        XCTAssertEqual(windows[0].usedFraction, 0.24)
        XCTAssertEqual(windows[1].usedFraction, 0.07)
        XCTAssertEqual(windows[1].detail, "Se restablece el 21 sept a las 12:44")
    }

    func testNotebookZeroIsARealReading() throws {
        let windows = try GoogleUsagePages.parseQuota("""
        Uso actual de la IA de Gemini Notebook
        0 % usado
        Se restablecerá a las 3:49 PM
        Límite semanal
        0 % usado
        Se restablecerá el Sep 27 a las 12:49 AM
        """)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].usedFraction, 0)
        XCTAssertEqual(windows[0].detail, "Se restablecerá a las 3:49 PM")
    }

    func testRemainingPercentageIsConvertedToUsed() throws {
        let windows = try GoogleUsagePages.parseQuota("Current usage\n80% remaining\nWeekly limit\n95.5% left")
        XCTAssertEqual(windows[0].usedFraction!, 0.2, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction!, 0.045, accuracy: 0.0001)
    }

    func testMissingCurrentCannotBorrowWeeklyPercentage() throws {
        let windows = try GoogleUsagePages.parseQuota("Current usage\nUnavailable\nWeekly limit\n10% used")
        XCTAssertEqual(windows.map(\.id), ["weekly"])
    }

    func testNoInventedQuotaFromPageOrUpsell() {
        for text in ["Sign in", "Current usage\n1000 tokens", "Weekly limit\nSave 20%", "Current usage\n101% used"] {
            XCTAssertThrowsError(try GoogleUsagePages.parseQuota(text))
        }
    }

    func testFlowCreditsHaveNoInventedDenominator() throws {
        for text in ["1,000 AI credits", "1,000 Google Flow credits", "1.000 créditos de IA", "Remaining credits: 1000"] {
            let windows = try GoogleUsagePages.parseCredits(text)
            XCTAssertEqual(windows[0].remaining, 1000)
            XCTAssertNil(windows[0].usedFraction)
            XCTAssertNil(windows[0].resetsAt)
        }
    }

    func testAmbiguousFlowBalancesAreUnavailable() {
        XCTAssertThrowsError(try GoogleUsagePages.parseCredits("50 credits\n1000 credits"))
        XCTAssertThrowsError(try GoogleUsagePages.parseCredits("20.5 credits"))
    }
}

@MainActor
final class UsageWidgetTests: XCTestCase {
    func testFableLeadsEveryWidgetSizeWithoutDroppingOtherQuotas() throws {
        let windows = [LimitWindow(id: "session", label: "Current session", usedFraction: 0.08),
                       LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.18),
                       LimitWindow(id: "weekly_scoped", label: "Fable", usedFraction: 0.26)]
        let source = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                      fidelity: .official, status: .ok, windows: windows)
        let snapshot = WidgetSnapshotPublisher.makeSnapshot([source], disconnected: [], dates: ["claude": Date()])
        let roundTrip = try XCTUnwrap(UsageWidgetStorage.decode(JSONEncoder().encode(snapshot)))
        let claude = try XCTUnwrap(roundTrip.providers.first { $0.id == "claude" })
        let overview = UsageMeterSelection.overviewMeters(for: claude)
        let individual = UsageMeterSelection.prioritizedMeters(for: claude)
        XCTAssertEqual(overview.map(\.id), ["weekly_scoped", "session", "weekly_all"])
        XCTAssertEqual(individual, overview)
        XCTAssertEqual(individual.first?.label, "Fable")
        XCTAssertEqual(individual.first?.usedFraction, 0.26)
        XCTAssertEqual(individual.dropFirst().map(\.usedFraction), [0.08, 0.18])
        XCTAssertEqual(claude.meters.map(\.id), windows.map(\.id), "Presentation does not rewrite the shared data")
    }

    func testSnapshotContainsAllMetersAndDoesNotInventMissingValues() {
        let snapshot = WidgetSnapshotPublisher.makeSnapshot([], disconnected: [], dates: [:])
        XCTAssertEqual(snapshot.providers.map(\.id), ["codex", "claude", "cursor", "kimi", "glm", "deepseek", "gemini-chat", "notebooklm", "google-flow"])
        XCTAssertTrue(snapshot.providers.allSatisfy { $0.state == .notConnected && $0.meters.isEmpty && $0.measuredAt == nil })
    }

    func testCursorAutoAndAPIAllowancesArePublishedSeparately() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let windows = try CursorUsage.windows(fromJSON: #"{"individualUsage":{"plan":{"autoPercentUsed":12,"apiPercentUsed":37}}}"#)
        let source = ProviderSnapshot(id: "cursor", displayName: "Cursor", glyph: .cursor,
            fidelity: .official, status: .ok, windows: windows)
        let snapshot = WidgetSnapshotPublisher.makeSnapshot([source], disconnected: [], dates: ["cursor": now], now: now)
        let cursor = try XCTUnwrap(snapshot.providers.first { $0.id == "cursor" })
        XCTAssertEqual(cursor.effectiveState(at: now), .ready)
        XCTAssertEqual(cursor.meters.map(\.id), ["auto", "api"])
        XCTAssertEqual(cursor.meters.compactMap(\.usedFraction), [0.12, 0.37])
    }

    func testDisabledProviderCannotLeakArchivedReadings() {
        let source = ProviderSnapshot(id: "claude", displayName: "Private account", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)])
        let data = WidgetSnapshotPublisher.makeSnapshot([source], disconnected: ["claude"], dates: ["claude": Date()])
        let reading = data.providers.first { $0.id == "claude" }!
        XCTAssertEqual(reading.name, "Claude")
        XCTAssertEqual(reading.state, .disabled)
        XCTAssertTrue(reading.meters.isEmpty)
        XCTAssertNil(reading.measuredAt)
    }

    func testMoneyIsABalanceAndAgeIsTheMeasurementDate() throws {
        let measured = Date(timeIntervalSince1970: 1000)
        let source = ProviderSnapshot(id: "deepseek", displayName: "Private account", glyph: .deepseek,
            fidelity: .derived, status: .ok,
            windows: [LimitWindow(id: "balance", label: "Balance", usedFraction: 0.8,
                money: UsageMoneyBreakdown(currency: "USD", spent: 80, remaining: 20))])
        let data = WidgetSnapshotPublisher.makeSnapshot([source], disconnected: [], dates: ["deepseek": measured], now: measured.addingTimeInterval(1000))
        let reading = data.providers.first { $0.id == "deepseek" }!
        XCTAssertEqual(reading.measuredAt, measured)
        XCTAssertEqual(reading.effectiveState(at: measured.addingTimeInterval(1000)), .stale)
        XCTAssertEqual(reading.meters[0].value, "20.00 USD left")
        XCTAssertNil(reading.meters[0].usedFraction)
        let json = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
        XCTAssertFalse(json.contains("Private account"))
        XCTAssertEqual(UsageWidgetStorage.decode(Data(json.utf8)), data)
    }

    func testUnknownSchemaIsNotAccepted() throws {
        var snapshot = UsageWidgetSnapshot.empty
        snapshot.schemaVersion = 999
        XCTAssertNil(UsageWidgetStorage.decode(try JSONEncoder().encode(snapshot)))
    }
}
