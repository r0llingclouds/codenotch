import XCTest
@testable import Codenotch

final class KimiTokenRefresherTests: XCTestCase {
    private var root: URL!
    private var auth: URL { root.appendingPathComponent("credentials/kimi-code-env-test.json") }
    private let rotated = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":900,"token_type":"Bearer"}"#

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kimi-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("credentials"), withIntermediateDirectories: true)
        try "[providers.\"managed:kimi-code\".oauth]\noauth_host = \"https://auth.kimi.ai\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try save()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func save(access: String = "old-access", refresh: String = "old+refresh&=", remaining: Double = -60) throws {
        try Self.write(auth, access: access, refresh: refresh, remaining: remaining)
    }

    private static func write(_ url: URL, access: String, refresh: String, remaining: Double) throws {
        let fields: [String: Any] = ["access_token": access, "refresh_token": refresh,
            "expires_at": Date().timeIntervalSince1970 + remaining, "expires_in": 900,
            "scope": "existing-scope", "extra_cli_field": "keep"]
        try JSONSerialization.data(withJSONObject: fields).write(to: url, options: .atomic)
    }

    private static func reply(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func testExpiredSessionRenewsForItsRegionAndPersistsRotatedTokensPrivately() async throws {
        let calls = KimiRefreshCalls()
        let body = rotated
        let refresher = KimiTokenRefresher(authURL: auth) { request in
            await calls.record(request)
            return Self.reply(request, body)
        }
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "new-access")
        XCTAssertEqual(credential.refreshToken, "new-refresh")
        XCTAssertGreaterThan(credential.expiresAt.timeIntervalSinceNow, 890)
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://auth.kimi.ai/api/oauth/token")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        let form = String(data: try XCTUnwrap(requests.first?.httpBody), encoding: .utf8)!
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=old%2Brefresh%26%3D"))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as! [String: Any]
        XCTAssertEqual(saved["scope"] as? String, "existing-scope")
        XCTAssertEqual(saved["extra_cli_field"] as? String, "keep")
        let attributes = try FileManager.default.attributesOfItem(atPath: auth.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("oauth/kimi-code-env-test.lock").path))
    }

    func testHealthySessionDoesNotRenew() async throws {
        try save(remaining: 600)
        let refresher = KimiTokenRefresher(authURL: auth) { _ in
            XCTFail("A healthy token should not use the network")
            throw URLError(.badURL)
        }
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "old-access")
    }

    func testLaterExpiryRenewsAgainUsingTheRotatedRefreshToken() async throws {
        let calls = KimiRefreshCalls()
        let body = rotated
        let refresher = KimiTokenRefresher(authURL: auth) { request in
            await calls.record(request)
            return Self.reply(request, body)
        }
        _ = try await refresher.credentials()
        // Advance the fixture to the next expiry, without waiting fifteen minutes.
        try save(access: "new-access", refresh: "new-refresh", remaining: -1)
        let next = try await refresher.credentials()
        XCTAssertFalse(next.isExpired)
        let requests = await calls.requests
        XCTAssertEqual(requests.count, 2)
        let form = String(data: try XCTUnwrap(requests.last?.httpBody), encoding: .utf8)!
        XCTAssertTrue(form.contains("refresh_token=new-refresh"))
    }

    func testRejectedAccessTokenForcesExactlyOneRenewal() async throws {
        try save(remaining: 600)
        let calls = KimiRefreshCalls()
        let body = rotated
        let refresher = KimiTokenRefresher(authURL: auth) { request in
            await calls.record(request)
            return Self.reply(request, body)
        }
        let credential = try await refresher.credentials(rejectedAccessToken: "old-access")
        _ = try await refresher.credentials(rejectedAccessToken: "old-access")
        XCTAssertEqual(credential.accessToken, "new-access")
        let count = await calls.requests.count
        XCTAssertEqual(count, 1)
    }

    func testConcurrentReadersAndSeparateInstancesUseOneRotation() async throws {
        let calls = KimiRefreshCalls()
        let body = rotated
        let transport: KimiTokenRefresher.Transport = { request in
            await calls.record(request)
            try await Task.sleep(nanoseconds: 100_000_000)
            return Self.reply(request, body)
        }
        let first = KimiTokenRefresher(authURL: auth, transport: transport)
        let peer = KimiTokenRefresher(authURL: auth, transport: transport)
        async let a = first.credentials()
        async let b = first.credentials()
        async let c = peer.credentials()
        let credentials = try await [a, b, c]
        XCTAssertEqual(credentials.map(\.accessToken), Array(repeating: "new-access", count: 3))
        let count = await calls.requests.count
        XCTAssertEqual(count, 1)
    }

    func testRevokedRefreshTokenIsNotRetriedOrDeletedAndNewLoginRecovers() async throws {
        let original = try Data(contentsOf: auth)
        let calls = KimiRefreshCalls()
        let refresher = KimiTokenRefresher(authURL: auth) { request in
            await calls.record(request)
            return Self.reply(request, #"{"error":"invalid_grant"}"#, status: 400)
        }
        for _ in 0..<2 {
            do { _ = try await refresher.credentials(); XCTFail("Expected sign-in required") }
            catch UsageProviderError.needsAuth {} catch { XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: auth), original)
        let count = await calls.requests.count
        XCTAssertEqual(count, 1)
        try save(access: "owner-login", refresh: "owner-refresh", remaining: 600)
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "owner-login")
    }

    func testTransientFailurePreservesSessionAndBacksOff() async throws {
        let original = try Data(contentsOf: auth)
        let calls = KimiRefreshCalls()
        let refresher = KimiTokenRefresher(authURL: auth) { request in
            await calls.record(request)
            return Self.reply(request, "{}", status: 503)
        }
        for _ in 0..<2 {
            do { _ = try await refresher.credentials(); XCTFail("Expected temporary failure") } catch {}
        }
        let count = await calls.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: auth), original)
    }

    func testEarlyRefreshFailureCanStillUseUnexpiredAccessToken() async throws {
        try save(remaining: 90)
        let refresher = KimiTokenRefresher(authURL: auth) { _ in throw URLError(.notConnectedToInternet) }
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "old-access")
    }

    func testMalformedSuccessNeverReplacesCredentials() async throws {
        let original = try Data(contentsOf: auth)
        for response in [#"{"access_token":"new","expires_in":900}"#,
                         #"{"access_token":"new","refresh_token":"new","expires_in":0}"#,
                         #"{"access_token":"new","refresh_token":"new","expires_in":true}"#] {
            let refresher = KimiTokenRefresher(authURL: auth) { Self.reply($0, response) }
            do { _ = try await refresher.credentials(); XCTFail("Expected malformed response") } catch {}
            XCTAssertEqual(try Data(contentsOf: auth), original)
        }
    }

    func testCustomOAuthHostCannotReceiveRefreshToken() async throws {
        try "[providers.\"managed:kimi-code\".oauth]\noauth_host = \"https://example.com\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let refresher = KimiTokenRefresher(authURL: auth) { _ in
            XCTFail("A custom host must not receive the credential")
            throw URLError(.badURL)
        }
        do { _ = try await refresher.credentials(); XCTFail("Expected refusal") }
        catch UsageProviderError.needsAuth {}
    }

    func testOwnerLogoutDuringRefreshIsNotUndone() async throws {
        let url = auth
        let body = rotated
        let refresher = KimiTokenRefresher(authURL: url) { request in
            try FileManager.default.removeItem(at: url)
            return Self.reply(request, body)
        }
        do { _ = try await refresher.credentials(); XCTFail("Expected missing session") }
        catch UsageProviderError.needsAuth {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOwnerReplacementDuringRefreshIsPreserved() async throws {
        let url = auth
        let body = rotated
        let refresher = KimiTokenRefresher(authURL: url) { request in
            try Self.write(url, access: "owner-login", refresh: "owner-refresh", remaining: 600)
            return Self.reply(request, body)
        }
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "owner-login")
        XCTAssertEqual(try KimiCredentials.load(from: auth).refreshToken, "owner-refresh")
    }

    func testRejectedOldTokenDoesNotInvalidateConcurrentOwnerLogin() async throws {
        let url = auth
        let refresher = KimiTokenRefresher(authURL: url) { request in
            try Self.write(url, access: "owner-login", refresh: "owner-refresh", remaining: 600)
            return Self.reply(request, #"{"error":"invalid_grant"}"#, status: 400)
        }
        let credential = try await refresher.credentials()
        XCTAssertEqual(credential.accessToken, "owner-login")
    }

    func testMissingRefreshTokenDoesNotMakeAnyRequest() async throws {
        try save(refresh: "")
        let refresher = KimiTokenRefresher(authURL: auth) { _ in
            XCTFail("There is no credential to renew")
            throw URLError(.badURL)
        }
        do { _ = try await refresher.credentials(); XCTFail("Expected an expired session") }
        catch UsageProviderError.credentialExpired {}
    }

    func testActiveCLILockIsRespectedAndAbandonedLockCanBeRecovered() async throws {
        let lock = try await KimiRefreshLock.acquire(for: auth)
        let before = try FileManager.default.attributesOfItem(atPath: lock.url.path)[.modificationDate] as! Date
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let after = try FileManager.default.attributesOfItem(atPath: lock.url.path)[.modificationDate] as! Date
        XCTAssertGreaterThan(after, before, "The CLI must see a heartbeat during slow requests")
        do { _ = try await KimiRefreshLock.acquire(for: auth, timeout: 0.1); XCTFail("Expected active lock timeout") }
        catch UsageProviderError.timedOut {}
        lock.release()
        try FileManager.default.createDirectory(at: lock.url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: lock.url.path)
        let recovered = try await KimiRefreshLock.acquire(for: auth)
        XCTAssertTrue(recovered.isOwned)
        recovered.release()
    }
}

private actor KimiRefreshCalls {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
