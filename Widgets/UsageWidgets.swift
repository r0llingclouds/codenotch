import AppIntents
import SwiftUI
import WidgetKit

enum UsageProviderChoice: String, AppEnum {
    case codex, claude, kimi, glm, deepseek
    case gemini = "gemini-chat"
    case notebooklm
    case flow = "google-flow"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .codex: "Codex", .claude: "Claude", .kimi: "Kimi", .glm: "GLM",
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

struct ProviderTile: View {
    @Environment(\.widgetFamily) private var family
    let reading: WidgetProviderReading
    let date: Date
    var detailed = false

    var tint: Color {
        switch reading.id {
        case "claude": return .orange
        case "codex": return .green
        case "kimi": return .purple
        case "glm": return .cyan
        case "deepseek": return .blue
        case "gemini-chat": return .indigo
        case "notebooklm": return .teal
        default: return .pink
        }
    }
    var state: WidgetProviderReading.State { reading.effectiveState(at: date) }
    var statusText: String {
        switch state {
        case .ready: return ""
        case .stale: return "Out of date"
        case .notConnected: return "Connect account"
        case .disabled: return "Enable in app"
        case .unavailable: return "Usage unavailable"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: detailed ? 9 : 5) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(reading.name).font(.system(size: detailed ? 15 : 12, weight: .semibold))
                Spacer(minLength: 0)
                if state == .stale { Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.secondary) }
            }
            if !reading.meters.isEmpty && (state == .ready || state == .stale) {
                ForEach(Array(reading.meters.prefix(detailed && family != .systemSmall ? 3 : 2))) { meter in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text(meter.label).lineLimit(1)
                            Spacer(minLength: 1)
                            if let fraction = meter.usedFraction {
                                Text("\(Int((fraction * 100).rounded()))% used").monospacedDigit().foregroundStyle(.primary)
                            }
                        }.font(.system(size: detailed ? 11 : 9)).foregroundStyle(.secondary)
                        if let fraction = meter.usedFraction {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(tint.opacity(0.13))
                                    Capsule().fill(fraction >= 0.9 ? Color.red : tint)
                                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                                }
                            }.frame(height: detailed ? 5 : 3)
                        } else {
                            Text(meter.value).font(.system(size: detailed ? 17 : 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65)
                        }
                        if detailed, let reset = meter.resetsAt {
                            if reset > date {
                                HStack(spacing: 3) { Text("Resets"); Text(reset, style: .relative) }
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            } else {
                                Text("Reset due · refresh needed").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        } else if detailed, let reset = meter.resetDescription, !reset.isEmpty {
                            Text(reset).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } else {
                Text(statusText).font(.system(size: detailed ? 12 : 10)).foregroundStyle(.secondary)
                if detailed { Text("Open Codenotch to connect and refresh.").font(.caption2).foregroundStyle(.secondary) }
            }
            if detailed, let measured = reading.measuredAt {
                HStack(spacing: 3) { Text(state == .stale ? "Last reading" : "Updated"); Text(measured, style: .relative) }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct OverviewView: View {
    let entry: UsageEntry
    var googleOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(googleOnly ? "Google AI Pro" : "AI Usage", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("CODENOTCH").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            let readings = entry.snapshot.providers.filter { !googleOnly || ["gemini-chat", "notebooklm", "google-flow"].contains($0.id) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: googleOnly ? 3 : 2), alignment: .leading, spacing: 14) {
                ForEach(readings) { reading in
                    Link(destination: URL(string: "codenotch-usage://provider/\(reading.id)")!) {
                        ProviderTile(reading: reading, date: entry.date)
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if entry.snapshot.generatedAt == .distantPast { Text("Open Codenotch to get started") }
                else { Text("Updated"); Text(entry.snapshot.generatedAt, style: .relative) }
                Spacer()
                Image(systemName: "arrow.up.right")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "codenotch-usage://settings"))
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
        StaticConfiguration(kind: "CodenotchAllUsage", provider: OverviewTimeline()) { OverviewView(entry: $0) }
            .configurationDisplayName("All AI usage")
            .description("Your subscriptions and DeepSeek balance in one view.")
            .supportedFamilies([.systemLarge])
    }
}

struct GoogleUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodenotchGoogleUsage", provider: OverviewTimeline()) { OverviewView(entry: $0, googleOnly: true) }
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
            ProviderTile(reading: reading, date: entry.date, detailed: true)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "codenotch-usage://provider/\(entry.providerID)"))
        }
        .configurationDisplayName("Provider usage")
        .description("Pin one provider’s limits, balance and reset times.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
