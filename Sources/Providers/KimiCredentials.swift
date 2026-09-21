import Foundation

/// Token from `~/.kimi-code/credentials/kimi-code.json`.
///
/// Kimi Code CLI signs in through auth.kimi.com and writes the OAuth session
/// here — one file per managed provider, and `kimi-code` is the Kimi Code
/// account itself. Renewal uses the CLI's per-credential lock and atomic
/// storage format so its rotating refresh token is shared safely.
/// `KIMI_CODE_HOME` moves the whole data root, so the path honours it.
struct KimiCredentials {
    static var authURL: URL {
        let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            .flatMap { value -> String? in value.isEmpty ? nil : value }
        let root = override.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-code")
        return authURL(root: root)
    }

    static func authURL(root: URL) -> URL {
        let legacy = root.appendingPathComponent("credentials/kimi-code.json")
        guard let config = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8),
              let key = managedOAuthKey(in: config) else { return legacy }
        return root.appendingPathComponent("credentials/\(key).json")
    }

    /// Read only the managed Kimi provider's file reference. Custom providers,
    /// unrelated OAuth services and path traversal are deliberately ineligible.
    static func managedOAuthKey(in config: String) -> String? {
        var inSection = false
        var fileStorage = false
        var key: String?
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[providers.\"managed:kimi-code\".oauth]"
                continue
            }
            guard inSection else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[1].hasPrefix("\""),
                  let end = pair[1].dropFirst().firstIndex(of: "\"") else { continue }
            let value = String(pair[1][pair[1].index(after: pair[1].startIndex)..<end])
            if pair[0] == "storage" { fileStorage = value == "file" }
            if pair[0] == "key", value.hasPrefix("oauth/") {
                let filename = String(value.dropFirst(6))
                if filename.range(of: "^kimi-code(?:-env-[a-zA-Z0-9]+)?$", options: .regularExpression) != nil { key = filename }
            }
        }
        return fileStorage ? key : nil
    }

    static func usageEndpoint(in config: String) -> URL {
        var inSection = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[providers.\"managed:kimi-code\"]"
                continue
            }
            guard inSection else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0] == "base_url" else { continue }
            // Never send the managed OAuth token to a custom provider host.
            if pair[1] == "\"https://api.kimi.ai/coding/v1\"" { return URL(string: "https://api.kimi.ai/coding/v1/usages")! }
        }
        return KimiUsage.endpoint
    }

    /// Only official OAuth hosts may receive a saved refresh token. The
    /// explicit region in the CLI's login takes precedence over the API URL.
    static func oauthEndpoint(in config: String) -> URL? {
        var inSection = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[providers.\"managed:kimi-code\".oauth]"
                continue
            }
            guard inSection else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0] == "oauth_host" else { continue }
            guard ["\"https://auth.kimi.com\"", "\"https://auth.kimi.ai\""].contains(pair[1]) else { return nil }
            return URL(string: String(pair[1].dropFirst().dropLast()) + "/api/oauth/token")
        }
        return URL(string: usageEndpoint(in: config).host == "api.kimi.ai"
                   ? "https://auth.kimi.ai/api/oauth/token" : "https://auth.kimi.com/api/oauth/token")
    }

    let accessToken: String
    let expiresAt: Date
    var endpoint: URL = KimiUsage.endpoint
    var refreshToken: String?
    var oauthEndpoint: URL?

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let credentials = try? load(from: url) else { return nil }
        return ProviderAccount(
            label: nil,   // the token carries no address
            plan: nil,
            source: "Kimi Code",
            manageURL: URL(string: credentials.endpoint.host == "api.kimi.ai"
                ? "https://www.kimi.ai/code/console" : "https://www.kimi.com/code/console")
        )
    }

    static func load(from url: URL = authURL) throws -> KimiCredentials {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else { throw UsageProviderError.needsAuth }

        // `expires_at` is epoch seconds. A file without one is not a session
        // to trust with a request that cannot succeed.
        guard let expires = (root["expires_at"] as? NSNumber)?.doubleValue, expires > 0
        else { throw UsageProviderError.needsAuth }

        let configURL = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.toml")
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return KimiCredentials(accessToken: token,
                               expiresAt: Date(timeIntervalSince1970: expires),
                               endpoint: usageEndpoint(in: config),
                               refreshToken: root["refresh_token"] as? String,
                               oauthEndpoint: oauthEndpoint(in: config))
    }
}
