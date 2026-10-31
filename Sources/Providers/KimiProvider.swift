import Foundation
import os

/// Reads Kimi Code usage from the endpoint the CLI's own `/usage` asks, with
/// the OAuth token the CLI stores on sign-in — see `KimiCredentials`.
///
/// The numbers are Kimi's, so this is `.official`. The token expires every
/// fifteen minutes. Refreshes coordinate with the CLI's storage lock so
/// Codenotch can keep reading while the terminal is closed. A 404 is the
/// endpoint's answer for an account with no Kimi Code plan — readable, but metering
/// nothing, and not an error.
actor KimiProvider: UsageProvider {
    nonisolated let id = "kimi"
    nonisolated let displayName = "Kimi"
    nonisolated let glyph = ProviderGlyph.kimi

    private let session: URLSession
    private let refresher: KimiTokenRefresher

    init(session: URLSession = .shared, authURL: URL = KimiCredentials.authURL,
         refresher: KimiTokenRefresher? = nil) {
        self.session = session
        self.refresher = refresher ?? KimiTokenRefresher(authURL: authURL)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Run kimi and sign in with /login — Codenotch renews the saved session automatically."))
    }

    nonisolated func account() -> ProviderAccount? { KimiCredentials.account() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try await refresher.credentials()
        let body: String
        do { body = try await fetch(token: credentials.accessToken, endpoint: credentials.endpoint) }
        catch UsageProviderError.needsAuth {
            let renewed = try await refresher.credentials(rejectedAccessToken: credentials.accessToken)
            body = try await fetch(token: renewed.accessToken, endpoint: renewed.endpoint)
        }
        Log.usage.debug("kimi usages -> \(body.prefix(400), privacy: .public)")
        let read = try KimiUsage.read(fromJSON: body)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: read.windows,
            headlineID: "rolling",
            weeklyID: "weekly",
            plan: read.plan
        )
    }

    private func fetch(token: String, endpoint: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch/1.16.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        Log.usage.debug("GET Kimi coding usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("kimi usages endpoint answered \(status)")

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        // The endpoint's answer for an account without a Kimi Code plan — the
        // CLI's own message for it is "Usage endpoint not available".
        if status == 404 {
            throw UsageProviderError.nothingMetered(L10n.t("No Kimi Code plan on this account"))
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }
        return text
    }
}
