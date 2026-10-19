import XCTest
import WebKit
@testable import Codenotch

/// Exercise real WebKit ownership with a local scheme, without signing into
/// a vendor or making network requests. A weak reference catches the original
/// regression: the provider kept the entire page after the reading finished.
@MainActor
final class WebSessionLifecycleTests: XCTestCase {
    private let id = "webview-lifecycle-\(UUID().uuidString)"
    private weak var latestWebView: WKWebView?
    private var createdWebViews = 0
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    override func tearDown() {
        UserDefaults.codenotch.removeObject(forKey: "\(id).signedIn")
        super.tearDown()
    }

    private func provider(
        reloadBeforeFetch: Bool = true,
        script: String = #"return JSON.stringify({status: 200, body: '{}'});"#,
        responds: Bool = true,
        parse: @escaping (String) throws -> [LimitWindow] = { _ in
            [LimitWindow(id: "current", label: "Current", usedFraction: 0.125)]
        }
    ) -> WebSessionProvider {
        let site = WebSessionProvider.Site(
            id: id, displayName: id, glyph: .geminiSpark,
            origin: URL(string: "codenotch-test://quota/")!, script: script,
            reloadBeforeFetch: reloadBeforeFetch, parse: parse
        )
        let provider = WebSessionProvider(site: site) { [weak self] configuration in
            guard let self else { fatalError("test fixture outlived its owner") }
            configuration.websiteDataStore = self.dataStore
            configuration.setURLSchemeHandler(PageHandler(responds: responds),
                                              forURLScheme: "codenotch-test")
            let view = WKWebView(frame: .zero, configuration: configuration)
            self.latestWebView = view
            self.createdWebViews += 1
            return view
        }
        provider.signInSheetDidOpen()
        return provider
    }

    private func assertPageReleased(file: StaticString = #filePath, line: UInt = #line) async {
        // WebKit/AppKit can drain autoreleased view references on the next turn.
        for _ in 0..<40 {
            if latestWebView == nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(latestWebView, "a finished reading must not retain the page", file: file, line: line)
    }

    func testGooglePagesOptIntoTheReloadAndReleaseLifecycle() {
        XCTAssertTrue(GoogleUsagePages.sites.allSatisfy(\.reloadBeforeFetch))
        XCTAssertTrue(GoogleUsagePages.sites.allSatisfy { $0.dataStoreIdentifier != nil },
                      "login cookies live in the persistent store, not the page")
        XCTAssertFalse(Sites.deepSeek.reloadBeforeFetch)
        XCTAssertFalse(Sites.minimax(region: .international).reloadBeforeFetch)
    }

    func testSuccessReleasesThePageButKeepsTheLoginForTheNextReading() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "fixture-session", .value: "signed-in", .domain: "quota", .path: "/"
        ]))
        await dataStore.httpCookieStore.setCookie(cookie)
        let provider = provider()

        let first = try await provider.fetchSnapshot()
        XCTAssertEqual(first.windows.first?.usedFraction, 0.125)
        await assertPageReleased()
        XCTAssertNotNil(provider.account())
        let cookies = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == cookie.name && $0.value == cookie.value })

        let next = try await provider.fetchSnapshot()
        XCTAssertEqual(next.windows.first?.usedFraction, 0.125)
        XCTAssertEqual(createdWebViews, 2, "the next reading builds a new page using the saved session")
        await assertPageReleased()
    }

    func testParseFailureStillReleasesThePage() async {
        let provider = provider(parse: { _ in throw UsageProviderError.badResponse(status: 99) })
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("the fixture must fail to parse")
        } catch { }
        XCTAssertEqual(createdWebViews, 1)
        await assertPageReleased()
        XCTAssertNotNil(provider.account(), "a parse failure must not sign the user out")
    }

    func testScriptFailureStillReleasesThePage() async {
        let provider = provider(script: "throw new Error('fixture failure');")
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("the fixture script must throw")
        } catch { }
        XCTAssertEqual(createdWebViews, 1)
        await assertPageReleased()
    }

    func testExpiredAuthenticationReleasesThePageAndClearsTheLogin() async {
        let provider = provider(script: #"return JSON.stringify({status: 401, body: ''});"#)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("the fixture session must be expired")
        } catch { }
        XCTAssertEqual(createdWebViews, 1)
        await assertPageReleased()
        XCTAssertNil(provider.account())
    }

    func testCancellationWhileLoadingReleasesThePage() async {
        let provider = provider(responds: false)
        let reading = Task { try await provider.fetchSnapshot() }
        while createdWebViews == 0 { await Task.yield() }
        reading.cancel()
        do {
            _ = try await reading.value
            XCTFail("the cancelled reading must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await assertPageReleased()
        XCTAssertNotNil(provider.account())
    }

    func testAnOpenSignInWindowSurvivesARefreshAndReleasesItsPageOnClose() async {
        let provider = provider()
        provider.presentSignIn()
        XCTAssertNotNil(latestWebView)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("background refresh must leave an open sign-in window alone")
        } catch { }
        XCTAssertNotNil(latestWebView)
        XCTAssertEqual(createdWebViews, 1)
        NSApp.windows.first { $0.title == "Sign in to \(id)" }?.close()
        await assertPageReleased()
    }

    func testAPIBackedProvidersKeepTheirReusablePage() async throws {
        let provider = provider(reloadBeforeFetch: false)
        _ = try await provider.fetchSnapshot()
        XCTAssertNotNil(latestWebView)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(createdWebViews, 1)
        await provider.signOut()
        await assertPageReleased()
    }
}

private final class PageHandler: NSObject, WKURLSchemeHandler {
    let responds: Bool
    init(responds: Bool) { self.responds = responds }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard responds else { return }
        let page = Data("<!doctype html><title>Usage fixture</title>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                            expectedContentLength: page.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(page)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
}
