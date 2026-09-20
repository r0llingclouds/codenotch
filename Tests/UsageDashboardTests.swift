import AppKit
import XCTest
@testable import Codenotch

final class UsageDashboardRouteTests: XCTestCase {
    func testWidgetsAndExplicitSettingsReachDifferentDestinations() {
        XCTAssertEqual(UsageDashboardRoute(url: URL(string: "codenotch-usage://dashboard")!), .overview)
        XCTAssertEqual(UsageDashboardRoute(url: URL(string: "codenotch-usage://settings")!), .settings)
        for provider in UsageWidgetSnapshot.catalogue {
            XCTAssertEqual(UsageDashboardRoute(url: URL(string: "codenotch-usage://provider/\(provider.id)")!), .provider(provider.id))
        }
    }

    func testUnknownOrMalformedLinksAreIgnored() {
        for url in ["https://provider/claude", "codenotch-usage://provider/unknown",
                    "codenotch-usage://provider", "codenotch-usage://provider/claude/extra",
                    "codenotch-usage://settings/extra", "codenotch-usage://user@provider/claude",
                    "codenotch-usage://provider:80/claude", "codenotch-usage://unknown"] {
            XCTAssertNil(UsageDashboardRoute(url: URL(string: url)!), url)
        }
    }
}

@MainActor
final class UsageDashboardTests: XCTestCase {
    func testSelectionFollowsNewReadingsAndDisconnection() throws {
        let model = UsageDashboardModel()
        model.select("claude")
        XCTAssertEqual(model.selectedReading?.state, .notConnected)
        let now = Date()
        let meter = WidgetUsageMeter(id: "session", label: "Session", usedFraction: 0.24,
                                    value: "24% used", resetsAt: now.addingTimeInterval(500), resetDescription: nil)
        model.snapshot.providers[1] = WidgetProviderReading(id: "claude", name: "Claude", state: .ready,
                                                            measuredAt: now, meters: [meter])
        XCTAssertEqual(model.selectedReading?.meters.first?.usedFraction, 0.24)
        model.snapshot = .empty
        XCTAssertTrue(try XCTUnwrap(model.selectedReading).meters.isEmpty)
        model.select("unknown")
        XCTAssertNil(model.selectedReading)
        model.select("claude")
        model.select(nil)
        XCTAssertNil(model.selectedID)
    }

    func testAgedReadingRemainsExplicitlyHistorical() {
        let now = Date()
        let reading = WidgetProviderReading(id: "claude", name: "Claude", state: .ready,
                                            measuredAt: now.addingTimeInterval(-901), meters: [])
        XCTAssertEqual(DashboardCopy.state(reading, at: now), L10n.t("Last available reading"))
        XCTAssertNotEqual(DashboardCopy.state(reading, at: now.addingTimeInterval(-600)),
                          DashboardCopy.state(reading, at: now))
    }

    func testUnknownAndExpiredResetTimesAreNotGuessed() {
        let now = Date()
        func meter(date: Date?, detail: String? = nil) -> WidgetUsageMeter {
            WidgetUsageMeter(id: "credits", label: "Credits", usedFraction: nil, value: "1050",
                             resetsAt: date, resetDescription: detail)
        }
        XCTAssertNil(DashboardCopy.reset(meter(date: nil), at: now))
        XCTAssertEqual(DashboardCopy.reset(meter(date: nil, detail: "Se restablece a las 19:00"), at: now),
                       "Se restablece a las 19:00")
        XCTAssertEqual(DashboardCopy.reset(meter(date: now.addingTimeInterval(-1)), at: now),
                       L10n.t("Waiting for the next window"))
    }

    func testSmallUsageDoesNotRoundDownToZeroOrUpToLimit() {
        XCTAssertEqual(DashboardCopy.percentage(0.001), "<1%")
        XCTAssertEqual(DashboardCopy.percentage(0.999), "99%")
        XCTAssertEqual(DashboardCopy.percentage(1.02), "102%")
        XCTAssertEqual(DashboardCopy.percentage(.nan), "—")
    }

    func testMenuBarDashboardEntryInvokesItsOwnAction() throws {
        var openedDashboard = false
        var openedSettings = false
        let controller = StatusItemController { openedSettings = true }
        controller.onOpenDashboard = { openedDashboard = true }
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let entry = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(entry.title, L10n.t("Open AI Usage"))
        XCTAssertEqual(entry.keyEquivalent, "1")
        controller.perform(try XCTUnwrap(entry.action), with: entry)
        XCTAssertTrue(openedDashboard)
        XCTAssertFalse(openedSettings)
    }
}
