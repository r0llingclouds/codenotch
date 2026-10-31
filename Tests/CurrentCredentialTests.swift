import SQLite3
import XCTest
@testable import Codenotch

final class CurrentCredentialTests: XCTestCase {
    func testKimiSelectsManagedGlobalCredentialWithoutReadingOtherProviders() {
        let config = """
        [providers."managed:kimi-code"]
        base_url = "https://api.kimi.ai/coding/v1"
        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code-env-012abc"
        [services.search.oauth]
        key = "oauth/unrelated"
        """
        XCTAssertEqual(KimiCredentials.managedOAuthKey(in: config), "kimi-code-env-012abc")
        XCTAssertEqual(KimiCredentials.usageEndpoint(in: config).host, "api.kimi.ai")
        XCTAssertEqual(KimiCredentials.usageEndpoint(in: config.replacingOccurrences(of: "api.kimi.ai", with: "attacker.example")).host, "api.kimi.com")
        XCTAssertNil(KimiCredentials.managedOAuthKey(in: config.replacingOccurrences(of: "oauth/kimi-code-env-012abc", with: "oauth/../../private")))
        XCTAssertNil(KimiCredentials.managedOAuthKey(in: config.replacingOccurrences(of: "storage = \"file\"", with: "storage = \"keychain\"")))
    }

    func testCurrentKimiMonthlyRatiosOverrideLegacyCounters() throws {
        let payload = #"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"6"}}],"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-20T13:21:00Z"},"limit_month_total":{"used_ratio":0.011,"reset_time":"2026-10-19T22:23:33Z"},"limit_month_code":{"used_ratio":0}}}"#
        let windows = try KimiUsage.read(fromJSON: payload).windows
        XCTAssertEqual(windows.map(\.id), ["rolling", "monthly", "monthly-code"])
        XCTAssertEqual(windows[0].usedFraction, 0)
        XCTAssertEqual(windows[1].usedFraction, 0.011)
        XCTAssertNotNil(windows[1].resetsAt)
        XCTAssertNil(windows[1].duration, "A calendar month has no fixed duration")
        XCTAssertThrowsError(try KimiUsage.read(fromJSON: #"{"usages":{"limit_5h":{"used_ratio":-1}}}"#))
    }

    func testOpenCodeReadsOnlyOneActiveGLMCredential() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("credential-test-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE credential (integration_id TEXT, active INTEGER, value TEXT);
        INSERT INTO credential VALUES ('zai-coding-plan',0,'{"type":"key","key":"old-account"}');
        INSERT INTO credential VALUES ('zai-coding-plan',1,'{"type":"key","key":"selected-account"}');
        INSERT INTO credential VALUES ('deepseek',1,'{"type":"key","key":"other-provider"}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(GLMCredentials.openCodeDatabase(url)?.token, "selected-account")
        XCTAssertEqual(GLMCredentials.openCodeDatabase(url)?.baseURL.host, "api.z.ai")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES ('zai-coding-plan',1,'{\"type\":\"key\",\"key\":\"ambiguous\"}');", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(GLMCredentials.openCodeDatabase(url))
    }
}
