import Combine
import Foundation

enum UsageDashboardRoute: Equatable {
    case overview
    case provider(String)
    case settings

    init?(url: URL) {
        guard url.scheme == "codenotch-usage", url.user == nil,
              url.password == nil, url.port == nil else { return nil }
        switch url.host {
        case "dashboard" where url.path.isEmpty || url.path == "/": self = .overview
        case "settings" where url.path.isEmpty || url.path == "/": self = .settings
        case "provider":
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 1, UsageWidgetSnapshot.catalogue.contains(where: { $0.id == parts[0] }) else { return nil }
            self = .provider(parts[0])
        default: return nil
        }
    }
}

/// The window observes the same normalized readings as the widgets. Opening,
/// selecting or closing it never creates a second polling loop.
@MainActor
final class UsageDashboardModel: ObservableObject {
    var collectorService: CollectorService?
    var canRefresh: Bool { collectorService?.enabled ?? true }
    let history: UsageHistoryModel
    @Published var showsHistory = false

    init(history: UsageHistoryModel? = nil) { self.history = history ?? UsageHistoryModel() }

    @Published var snapshot: UsageWidgetSnapshot = .empty
    @Published var refreshing: Set<String> = []
    @Published var plans: [String: String] = [:]
    @Published var selectedID: String?

    var selectedReading: WidgetProviderReading? {
        snapshot.providers.first { $0.id == selectedID }
    }

    func select(_ id: String?) {
        selectedID = id.flatMap { id in snapshot.providers.contains { $0.id == id } ? id : nil }
    }
}

enum DashboardCopy {
    static func state(_ reading: WidgetProviderReading, at now: Date) -> String {
        switch reading.effectiveState(at: now) {
        case .ready: return L10n.t("Up to date")
        case .stale: return L10n.t("Last available reading")
        case .notConnected: return L10n.t("Connect account")
        case .disabled: return L10n.t("Tracking paused")
        case .unavailable: return L10n.t("Reading unavailable")
        }
    }

    static func percentage(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction >= 0 else { return "—" }
        return Percent.whole(for: fraction) + "%"
    }

    static func reset(_ meter: WidgetUsageMeter, at now: Date) -> String? {
        guard let date = meter.resetsAt else { return meter.resetDescription }
        guard date > now else { return L10n.t("Waiting for the next window") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = date.timeIntervalSince(now) >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let remaining = formatter.string(from: max(60, date.timeIntervalSince(now))) ?? "—"
        return L10n.t("Resets in \(remaining)")
    }

    static func scope(_ id: String) -> String {
        switch id {
        case "codex": return L10n.t("Codex usage on your ChatGPT plan. ChatGPT chat has separate limits.")
        case "claude": return L10n.t("Session and weekly limits reported by Claude.")
        case "cursor": return L10n.t("Cursor's Auto and API allowances are tracked separately.")
        case "kimi": return L10n.t("Kimi Code session and monthly allowances.")
        case "glm": return L10n.t("Usage on your Z.ai GLM Coding Plan.")
        case "deepseek": return L10n.t("Your remaining DeepSeek API balance, in the account currency.")
        case "gemini-chat": return L10n.t("Limits reported by Gemini chat for your signed-in Google account.")
        case "notebooklm": return L10n.t("Limits reported by NotebookLM for your signed-in Google account.")
        default: return L10n.t("AI credits reported by Flow. Credits are separate from chat usage limits.")
        }
    }
}
