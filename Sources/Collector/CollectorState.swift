import Foundation

/// Only normalized usage leaves the collector. Tokens, cookies and account
/// identities never enter this file or the distributed notifications.
struct CollectorState: Codable {
    var snapshot: UsageWidgetSnapshot
    var plans: [String: String]
    var refreshing: Set<String>
    var historyError: Bool

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/collector-state.json")
    }

    func save(to url: URL = Self.url) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(from url: URL = Self.url) -> Self? {
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum CollectorMessage {
    static let changed = Notification.Name("com.r0llingclouds.codenotch.collector.changed")
    static let command = Notification.Name("com.r0llingclouds.codenotch.collector.command")
    static let history = Notification.Name("com.r0llingclouds.codenotch.collector.history")

    enum Command: Equatable {
        case refreshAll, refresh(String), settings, publish
        init?(_ raw: String, providers: Set<String>) {
            switch raw {
            case "refreshAll": self = .refreshAll
            case "settings": self = .settings
            case "publish": self = .publish
            default:
                guard raw.hasPrefix("refresh:"), providers.contains(String(raw.dropFirst(8))) else { return nil }
                self = .refresh(String(raw.dropFirst(8)))
            }
        }
    }

    static func send(_ raw: String) {
        DistributedNotificationCenter.default().postNotificationName(command, object: raw,
            userInfo: nil, deliverImmediately: true)
    }
    static func notify(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil,
            userInfo: nil, deliverImmediately: true)
    }
}

enum CollectorSessionMigration {
    /// Copy once, with the old app stopped and before the helper is launched.
    /// Original sessions remain intact; existing helper sessions always win.
    static func migrate(library: URL) throws {
        let fm = FileManager.default
        for relative in ["WebKit/com.r0llingclouds.codenotch",
                         "HTTPStorages/com.r0llingclouds.codenotch",
                         "HTTPStorages/com.r0llingclouds.codenotch.binarycookies"] {
            let source = library.appendingPathComponent(relative)
            let target = library.appendingPathComponent(relative.replacingOccurrences(
                of: "com.r0llingclouds.codenotch", with: "com.r0llingclouds.codenotch.collector"))
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            let staging = target.deletingLastPathComponent().appendingPathComponent(".collector-migration-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try fm.moveItem(at: staging, to: target)
        }
    }
}
