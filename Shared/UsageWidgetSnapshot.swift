import Foundation

/// Deliberately contains no credentials, account names, conversation text or API responses.
struct UsageWidgetSnapshot: Codable, Equatable {
    static let version = 1
    var schemaVersion = version
    var generatedAt: Date
    var providers: [WidgetProviderReading]

    static let catalogue: [(id: String, name: String)] = [
        ("codex", "Codex"), ("claude", "Claude"), ("cursor", "Cursor"), ("kimi", "Kimi"),
        ("glm", "GLM"), ("deepseek", "DeepSeek"), ("gemini-chat", "Gemini"),
        ("notebooklm", "NotebookLM"), ("google-flow", "Flow")
    ]

    static var empty: Self {
        Self(generatedAt: .distantPast, providers: catalogue.map {
            WidgetProviderReading(id: $0.id, name: $0.name, state: .notConnected,
                                  measuredAt: nil, meters: [])
        })
    }
}

struct WidgetProviderReading: Codable, Equatable, Identifiable {
    enum State: String, Codable { case ready, stale, notConnected, disabled, unavailable }
    let id: String
    let name: String
    var state: State
    let measuredAt: Date?
    let meters: [WidgetUsageMeter]

    func effectiveState(at now: Date) -> State {
        guard state == .ready else { return state }
        guard let measuredAt, now.timeIntervalSince(measuredAt) < 15 * 60 else { return .stale }
        return .ready
    }
}

struct WidgetUsageMeter: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let usedFraction: Double?
    let value: String
    let resetsAt: Date?
    let resetDescription: String?
}

/// One presentation order for the app and every widget size, so an important
/// model quota cannot be promoted in one surface and truncated in another.
enum UsageMeterSelection {
    static func isFable(_ meter: WidgetUsageMeter) -> Bool {
        // weekly_scoped can describe other models, so its label matters.
        meter.id == "weekly_fable" || meter.label.localizedCaseInsensitiveContains("fable")
    }

    static func prioritizedMeters(for reading: WidgetProviderReading) -> [WidgetUsageMeter] {
        var meters = reading.meters
        if reading.id == "claude", let index = meters.firstIndex(where: isFable) {
            let fable = meters.remove(at: index)
            meters.insert(fable, at: 0)
        }
        return meters
    }

    static func overviewMeters(for reading: WidgetProviderReading) -> [WidgetUsageMeter] {
        Array(prioritizedMeters(for: reading).prefix(reading.id == "claude" ? 3 : 2))
    }
}

enum UsageWidgetStorage {
    static let group = "group.com.r0llingclouds.codenotch"
    static let fileName = "usage-widget.json"
    static let bridgePort: UInt16 = 48531

    static var sharedURL: URL? {
        let setting = Bundle.main.object(forInfoDictionaryKey: "CodenotchUsesAppGroup")
        guard (setting as? Bool == true) || (setting as? NSString)?.boolValue == true else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(fileName)
    }

    static func decode(_ data: Data) -> UsageWidgetSnapshot? {
        guard data.count <= 256 * 1024,
              let result = try? JSONDecoder().decode(UsageWidgetSnapshot.self, from: data),
              result.schemaVersion == UsageWidgetSnapshot.version else { return nil }
        return result
    }
}
