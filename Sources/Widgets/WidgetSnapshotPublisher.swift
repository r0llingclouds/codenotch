import Foundation
import Network
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    private var listener: NWListener?
    private var latestData = Data()

    init() {
        // A loopback-only fallback lets locally ad-hoc signed widgets work even
        // when macOS cannot grant the shared App Group container.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UsageWidgetStorage.bridgePort)!)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                Task { @MainActor in
                    guard let self, let data,
                          let request = String(data: data, encoding: .utf8),
                          request.hasPrefix("GET /widget-snapshot HTTP/1.") else {
                        connection.cancel(); return
                    }
                    let body = self.latestData
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }

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
                return WidgetUsageMeter(id: window.id, label: window.label,
                    usedFraction: window.money == nil ? fraction : nil, value: value,
                    resetsAt: window.resetsAt, resetDescription: window.detail)
            }
            return WidgetProviderReading(id: item.id, name: item.name, state: state,
                measuredAt: dates[item.id] ?? snapshot.status.staleSince, meters: meters)
        }
        return UsageWidgetSnapshot(generatedAt: now, providers: readings)
    }

    func publish(_ snapshot: UsageWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        latestData = data
        if let url = UsageWidgetStorage.sharedURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
