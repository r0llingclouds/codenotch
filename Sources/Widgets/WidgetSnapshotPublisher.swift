import Foundation
import Network
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    private final class Payload: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func read() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func write(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            self.data = data
        }
    }

    private var listener: NWListener?
    private let payload = Payload()
    private let queue = DispatchQueue(label: "com.r0llingclouds.codenotch.widget-bridge", qos: .userInitiated)
    private let reloadTimelines: () -> Void

    var bridgePort: UInt16? {
        guard let port = listener?.port?.rawValue, port != 0 else { return nil }
        return port
    }

    init(port: UInt16 = UsageWidgetStorage.bridgePort,
         reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.reloadTimelines = reloadTimelines
        // A loopback-only fallback lets locally ad-hoc signed widgets work even
        // when macOS cannot grant the shared App Group container.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        // WidgetKit's three-second read must not wait behind provider work on
        // the main actor. Only the already-normalized payload crosses queues.
        let payload = self.payload
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      request.hasPrefix("GET /widget-snapshot HTTP/1.") else {
                    connection.cancel(); return
                }
                let body = payload.read()
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener?.cancel() }
    deinit { listener?.cancel() }

    static func makeSnapshot(_ snapshots: [ProviderSnapshot], disconnected: Set<String>,
                             dates: [String: Date], now: Date = Date()) -> UsageWidgetSnapshot {
        let readings = UsageWidgetSnapshot.catalogue.map { item -> WidgetProviderReading in
            guard let snapshot = snapshots.first(where: { $0.id == item.id }), !disconnected.contains(item.id) else {
                return WidgetProviderReading(id: item.id, name: item.name,
                    state: disconnected.contains(item.id) ? .disabled : .notConnected, measuredAt: nil, meters: [])
            }
            let state: WidgetProviderReading.State
            switch snapshot.status {
            case .ok: state = .ready
            case .stale, .signedOutByOwner: state = .stale
            case .needsAuth, .accessDenied: state = .notConnected
            case .unsupported, .error: state = .unavailable
            }
            let meters = snapshot.windows.map { window -> WidgetUsageMeter in
                let fraction = window.usedFraction.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let value: String
                // A funded/spent ratio is not a resetting DeepSeek allowance.
                if let money = window.money {
                    value = String(format: "%.2f %@ left", money.remaining, money.currency)
                } else { value = window.summary }
                let label = Self.meterLabel(for: window, in: snapshot.windows, providerID: snapshot.id)
                return WidgetUsageMeter(id: window.id, label: label,
                    usedFraction: window.money == nil ? fraction : nil, value: value,
                    resetsAt: window.resetsAt, resetDescription: window.detail)
            }
            return WidgetProviderReading(id: item.id, name: item.name, state: state,
                measuredAt: dates[item.id] ?? snapshot.status.staleSince, meters: meters)
        }
        return UsageWidgetSnapshot(generatedAt: now, providers: readings)
    }

    /// Flat surfaces (dashboard details, widgets, history) do not render group
    /// headers around windows, so multi-group Antigravity windows carry their
    /// model family in the meter label.
    nonisolated static func meterLabel(for window: LimitWindow, in windows: [LimitWindow], providerID: String) -> String {
        if providerID == "gemini" {
            switch window.id.lowercased() {
            case "gemini-5h", "gemini-hourly": return L10n.t("Gemini 5h")
            case "gemini-weekly": return L10n.t("Gemini Weekly")
            case "3p-5h", "3p-hourly": return L10n.t("Claude/GPT 5h")
            case "3p-weekly": return L10n.t("Claude/GPT Weekly")
            case "gemini-argon-weekly": return L10n.t("Argon Weekly")
            default: break
            }
        }
        guard let group = window.group, !group.isEmpty else { return window.label }
        let duplicate = windows.filter { $0.label == window.label }.count > 1
        return duplicate ? "\(group) · \(window.label)" : window.label
    }

    func publish(_ snapshot: UsageWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        payload.write(data)
        if let url = UsageWidgetStorage.sharedURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        reloadTimelines()
    }
}
