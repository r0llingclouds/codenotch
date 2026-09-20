import AppIntents
import SwiftUI
import WidgetKit

enum UsageProviderChoice: String, AppEnum {
    case codex, claude, cursor, kimi, glm, deepseek
    case gemini = "gemini-chat"
    case notebooklm
    case flow = "google-flow"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .codex: "Codex", .claude: "Claude", .cursor: "Cursor", .kimi: "Kimi", .glm: "GLM",
        .deepseek: "DeepSeek", .gemini: "Gemini chat", .notebooklm: "NotebookLM", .flow: "Google Flow"
    ]
}

struct ProviderWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a provider"
    @Parameter(title: "Provider", default: .codex) var provider: UsageProviderChoice
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageWidgetSnapshot
    var providerID: String = "codex"
}

enum UsageTimeline {
    static func make(snapshot: UsageWidgetSnapshot, providerID: String = "codex", now: Date = Date()) -> Timeline<UsageEntry> {
        // Future entries age the reading even if the app quits and the OS
        // postpones its next background refresh.
        let staleDates = snapshot.providers.compactMap(\.measuredAt).map { $0.addingTimeInterval(15 * 60) }
        let resetDates = snapshot.providers.flatMap(\.meters).compactMap(\.resetsAt)
        let dates = [now] + Array(Set((staleDates + resetDates).filter { $0 > now })).sorted()
        return Timeline(entries: dates.map { UsageEntry(date: $0, snapshot: snapshot, providerID: providerID) },
                        policy: .after(now.addingTimeInterval(300)))
    }
}

enum WidgetReader {
    static func read() async -> UsageWidgetSnapshot {
        if let url = UsageWidgetStorage.sharedURL,
           let data = try? Data(contentsOf: url), let snapshot = UsageWidgetStorage.decode(data),
           Date().timeIntervalSince(snapshot.generatedAt) < 15 * 60 { return snapshot }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(UsageWidgetStorage.fileName)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(UsageWidgetStorage.bridgePort)/widget-snapshot")!)
        request.timeoutInterval = 3
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let snapshot = UsageWidgetStorage.decode(data) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return snapshot
        }
        if let url = UsageWidgetStorage.sharedURL,
           let data = try? Data(contentsOf: url), let snapshot = UsageWidgetStorage.decode(data) { return snapshot }
        return (try? Data(contentsOf: cache)).flatMap(UsageWidgetStorage.decode) ?? .empty
    }
}

struct OverviewTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        Task { completion(UsageEntry(date: Date(), snapshot: await WidgetReader.read())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            completion(UsageTimeline.make(snapshot: await WidgetReader.read()))
        }
    }
}

struct ProviderTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: .empty) }
    func snapshot(for configuration: ProviderWidgetIntent, in context: Context) async -> UsageEntry {
        UsageEntry(date: Date(), snapshot: await WidgetReader.read(), providerID: configuration.provider.rawValue)
    }
    func timeline(for configuration: ProviderWidgetIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = await snapshot(for: configuration, in: context)
        return UsageTimeline.make(snapshot: entry.snapshot, providerID: entry.providerID, now: entry.date)
    }
}

@main
struct UsageWidgets: WidgetBundle {
    var body: some Widget {
        AllUsageWidget()
        OneProviderWidget()
        GoogleUsageWidget()
    }
}

struct AllUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodenotchAllUsage", provider: OverviewTimeline()) { entry in
            UsageOverview(snapshot: entry.snapshot, date: entry.date)
                .containerBackground(for: .widget) { WidgetBackdrop() }
                .widgetURL(URL(string: "codenotch-usage://settings"))
        }
            .contentMarginsDisabled()
            .configurationDisplayName("All AI usage")
            .description("Your subscriptions and DeepSeek balance in one view.")
            .supportedFamilies([.systemLarge])
    }
}

struct GoogleUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodenotchGoogleUsage", provider: OverviewTimeline()) { entry in
            UsageOverview(snapshot: entry.snapshot, date: entry.date, googleOnly: true)
                .containerBackground(for: .widget) { WidgetBackdrop() }
                .widgetURL(URL(string: "codenotch-usage://settings"))
        }
            .contentMarginsDisabled()
            .configurationDisplayName("Google AI Pro")
            .description("Gemini chat, NotebookLM and Flow as separate allowances.")
            .supportedFamilies([.systemMedium])
    }
}

struct OneProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CodenotchProviderUsage", intent: ProviderWidgetIntent.self, provider: ProviderTimeline()) { entry in
            let reading = entry.snapshot.providers.first { $0.id == entry.providerID }
                ?? UsageWidgetSnapshot.empty.providers.first { $0.id == entry.providerID }!
            ProviderWidgetContent(reading: reading, date: entry.date)
                .containerBackground(for: .widget) { WidgetBackdrop() }
                .widgetURL(URL(string: "codenotch-usage://provider/\(entry.providerID)"))
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Provider usage")
        .description("Pin one provider’s limits, balance and reset times.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ProviderWidgetContent: View {
    @Environment(\.widgetFamily) private var family
    let reading: WidgetProviderReading
    let date: Date
    var body: some View { SingleProviderView(reading: reading, date: date, family: family) }
}
