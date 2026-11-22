import Foundation
import Darwin

/// Uses the managed CLI's OAuth protocol, including its proper-lockfile
/// directory/heartbeat convention. No chat request or CLI session is started.
/// Reference: MoonshotAI/kimi-code packages/oauth/src/{oauth-manager,oauth,storage}.ts.
actor KimiTokenRefresher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let authURL: URL
    private let transport: Transport
    private var pending: Task<KimiCredentials, Error>?
    private var rejectedToken: String?
    private var retryAfter = Date.distantPast

    init(authURL: URL, transport: @escaping Transport = { try await KimiTokenRefresher.send($0) }) {
        self.authURL = authURL
        self.transport = transport
    }

    func credentials(rejectedAccessToken: String? = nil) async throws -> KimiCredentials {
        if let pending { return try await pending.value }
        let current = try KimiCredentials.load(from: authURL)
        let force = rejectedAccessToken == current.accessToken
        guard force || current.expiresAt.timeIntervalSinceNow < 120 else { return current }
        guard let refresh = current.refreshToken, !refresh.isEmpty else {
            if !current.isExpired && !force { return current }
            throw UsageProviderError.credentialExpired
        }
        guard refresh != rejectedToken else { throw UsageProviderError.needsAuth }
        guard Date() >= retryAfter else {
            if !current.isExpired && !force { return current }
            throw UsageProviderError.rateLimited(retryAfter: retryAfter.timeIntervalSinceNow)
        }
        let task = Task { try await self.renew(rejectedAccessToken: rejectedAccessToken) }
        pending = task
        defer { pending = nil }
        do {
            let result = try await task.value
            retryAfter = .distantPast
            rejectedToken = nil
            return result
        } catch {
            if case UsageProviderError.needsAuth = error {
                rejectedToken = refresh
                throw error
            }
            retryAfter = Date().addingTimeInterval(60)
            // A transient renewal failure must not discard a still-valid token.
            if !current.isExpired && !force { return current }
            throw error
        }
    }

    private func renew(rejectedAccessToken: String?) async throws -> KimiCredentials {
        let lock = try await KimiRefreshLock.acquire(for: authURL)
        defer { lock.release() }
        // A CLI process may have renewed (or signed out) while we waited.
        let current = try KimiCredentials.load(from: authURL)
        let force = rejectedAccessToken == current.accessToken
        if !force && current.expiresAt.timeIntervalSinceNow >= 120 { return current }
        guard let refresh = current.refreshToken, !refresh.isEmpty,
              let endpoint = current.oauthEndpoint else { throw UsageProviderError.needsAuth }
        let original = try Data(contentsOf: authURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch/1.16.0", forHTTPHeaderField: "User-Agent")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = refresh.addingPercentEncoding(withAllowedCharacters: allowed)!
        request.httpBody = Data("client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=\(encoded)".utf8)
        let (data, response) = try await transport(request)
        if (try? Data(contentsOf: authURL)) != original {
            let newer = try KimiCredentials.load(from: authURL)
            guard !newer.isExpired else { throw UsageProviderError.credentialExpired }
            return newer
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if [400, 401, 403].contains(response.statusCode),
           response.statusCode != 400 || payload["error"] as? String == "invalid_grant" {
            // Keep the owner's file intact; a later CLI login can replace it.
            throw UsageProviderError.needsAuth
        }
        if response.statusCode == 429 { throw UsageProviderError.rateLimited(retryAfter: 60) }
        guard response.statusCode == 200,
              let access = payload["access_token"] as? String, !access.isEmpty,
              let rotated = payload["refresh_token"] as? String, !rotated.isEmpty,
              let lifetime = payload["expires_in"] as? NSNumber,
              CFGetTypeID(lifetime) != CFBooleanGetTypeID(),
              lifetime.doubleValue.isFinite, lifetime.doubleValue > 0,
              var saved = try JSONSerialization.jsonObject(with: original) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: response.statusCode) }
        // An owner logout/login or a lost lock wins over our in-flight result.
        guard lock.isOwned, (try? Data(contentsOf: authURL)) == original else {
            let newer = try KimiCredentials.load(from: authURL)
            guard !newer.isExpired else { throw UsageProviderError.credentialExpired }
            return newer
        }
        saved["access_token"] = access
        saved["refresh_token"] = rotated
        saved["expires_in"] = lifetime.doubleValue
        saved["expires_at"] = Date().timeIntervalSince1970 + lifetime.doubleValue
        saved["token_type"] = payload["token_type"] as? String ?? saved["token_type"] ?? "Bearer"
        if let scope = payload["scope"] as? String { saved["scope"] = scope }
        try Self.persist(try JSONSerialization.data(withJSONObject: saved), to: authURL)
        return try KimiCredentials.load(from: authURL)
    }

    private static func persist(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw UsageProviderError.accessDenied
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw UsageProviderError.accessDenied }
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: KimiOAuthRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageProviderError.badResponse(status: 0) }
        return (data, response)
    }
}

private final class KimiOAuthRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Matches proper-lockfile's <root>/oauth/<credential-name>.lock directory,
/// five-second stale window and heartbeat. An fd keeps ownership tied to the
/// original inode, so a delayed task cannot touch/remove another process's lock.
final class KimiRefreshLock: @unchecked Sendable {
    let url: URL
    private let fd: Int32
    private let inode: ino_t
    private let device: dev_t
    private var heartbeat: Task<Void, Never>?

    private init(url: URL, fd: Int32, info: stat) {
        self.url = url; self.fd = fd; inode = info.st_ino; device = info.st_dev
    }

    static func acquire(for authURL: URL, timeout: TimeInterval = 8) async throws -> KimiRefreshLock {
        let parent = authURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("oauth")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = parent.appendingPathComponent(authURL.deletingPathExtension().lastPathComponent + ".lock")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try Task.checkCancellation()
            if mkdir(url.path, 0o700) == 0 {
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                var info = stat()
                guard fd >= 0, fstat(fd, &info) == 0 else {
                    if fd >= 0 { close(fd) }; rmdir(url.path)
                    throw UsageProviderError.accessDenied
                }
                let lock = KimiRefreshLock(url: url, fd: fd, info: info)
                lock.heartbeat = Task.detached { [weak lock] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        guard let lock, lock.isOwned else { return }
                        _ = futimes(lock.fd, nil)
                    }
                }
                return lock
            }
            guard errno == EEXIST else { throw UsageProviderError.accessDenied }
            var info = stat()
            if lstat(url.path, &info) == 0,
               Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 6 {
                _ = rmdir(url.path) // Only an empty, expired directory can be reclaimed.
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        throw UsageProviderError.timedOut
    }

    var isOwned: Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_ino == inode && info.st_dev == device
    }

    func release() {
        heartbeat?.cancel()
        if isOwned { _ = rmdir(url.path) }
        // Closing in deinit keeps a concurrently finishing heartbeat away
        // from a recycled file descriptor.
    }

    deinit { heartbeat?.cancel(); close(fd) }
}
