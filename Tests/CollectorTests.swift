import XCTest
@testable import Codenotch

final class CollectorTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMigrationPreservesOriginalAndNeverReplacesNewerCollectorSession() throws {
        let source = directory.appendingPathComponent("WebKit/com.r0llingclouds.codenotch/WebsiteDataStore/profile")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original session".utf8).write(to: source.appendingPathComponent("cookies"))
        let cookies = directory.appendingPathComponent("HTTPStorages/com.r0llingclouds.codenotch.binarycookies")
        try FileManager.default.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("http session".utf8).write(to: cookies)
        try CollectorSessionMigration.migrate(library: directory)
        let target = directory.appendingPathComponent("WebKit/com.r0llingclouds.codenotch.collector/WebsiteDataStore/profile/cookies")
        XCTAssertEqual(try Data(contentsOf: target), Data("original session".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("HTTPStorages/com.r0llingclouds.codenotch.collector.binarycookies")), Data("http session".utf8))
        try Data("new session".utf8).write(to: target)
        try CollectorSessionMigration.migrate(library: directory)
        XCTAssertEqual(try Data(contentsOf: target), Data("new session".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("cookies")), Data("original session".utf8))
    }

    func testMigrationOnFreshInstallDoesNotCreateEmptyProfile() throws {
        try CollectorSessionMigration.migrate(library: directory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testStateSurvivesRestartWithRestrictedPermissionsAndCorruptionFailsClosed() throws {
        let url = directory.appendingPathComponent("state/collector.json")
        let state = CollectorState(snapshot: .empty, plans: ["claude": "Max"], refreshing: ["claude"], historyError: true)
        try state.save(to: url)
        let loaded = try XCTUnwrap(CollectorState.read(from: url))
        XCTAssertEqual(loaded.plans, state.plans)
        XCTAssertEqual(loaded.refreshing, ["claude"])
        XCTAssertTrue(loaded.historyError)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        try Data("invalid".utf8).write(to: url)
        XCTAssertNil(CollectorState.read(from: url))
    }

    func testCommandsAllowOnlyKnownRefreshTargetsAndBoundedActions() {
        let ids: Set<String> = ["claude", "cursor"]
        XCTAssertEqual(CollectorMessage.Command("refresh:claude", providers: ids), .refresh("claude"))
        XCTAssertEqual(CollectorMessage.Command("refreshAll", providers: ids), .refreshAll)
        XCTAssertEqual(CollectorMessage.Command("settings", providers: ids), .settings)
        XCTAssertEqual(CollectorMessage.Command("publish", providers: ids), .publish)
        for invalid in ["refresh:", "refresh:unknown", "refresh:claude:extra", "quit", "exec:/bin/sh"] {
            XCTAssertNil(CollectorMessage.Command(invalid, providers: ids))
        }
    }
}
