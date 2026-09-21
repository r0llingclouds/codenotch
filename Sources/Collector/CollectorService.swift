import AppKit
import Combine
import ServiceManagement

/// Registration belongs to the containing app. Quitting that app has no
/// effect on the launch agent, and pausing is an explicit, persistent choice.
@MainActor
final class CollectorService: ObservableObject {
    static let plistName = "com.r0llingclouds.codenotch.collector.plist"
    private let service = SMAppService.agent(plistName: plistName)
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    private var activationObserver: AnyCancellable?

    init() {
        status = service.status
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.status = self?.service.status ?? .notRegistered }
    }

    var enabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }
    var label: String {
        if error != nil { return L10n.t("Background updates need attention") }
        if needsApproval { return L10n.t("Allow background updates in System Settings") }
        return enabled ? L10n.t("Background updates on") : L10n.t("Background updates paused")
    }

    func startIfWanted() {
        guard !Runtime.isUnderTest, UserDefaults.codenotch.object(forKey: "backgroundCollectionEnabled") as? Bool != false else { return }
        enable()
    }

    func enable() {
        guard !Runtime.isUnderTest else { return }
        error = nil
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try CollectorSessionMigration.migrate(library: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0])
                try service.register()
            }
            UserDefaults.codenotch.set(true, forKey: "backgroundCollectionEnabled")
        } catch { self.error = error.localizedDescription }
        status = service.status
    }

    func pause() {
        guard !Runtime.isUnderTest else { return }
        Task {
            do {
                try await service.unregister()
                UserDefaults.codenotch.set(false, forKey: "backgroundCollectionEnabled")
                error = nil
            } catch { self.error = error.localizedDescription }
            status = service.status
        }
    }

    func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    /// Used by the installer before replacing the bundle, so KeepAlive cannot
    /// relaunch an executable halfway through an update. Does not change the
    /// user's persistent enable/pause choice.
    static func prepareForUpdate() async throws {
        let service = SMAppService.agent(plistName: plistName)
        if service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
    }
}

@MainActor
final class CollectorDashboardClient {
    let model: UsageDashboardModel
    let service = CollectorService()
    private var observers: [NSObjectProtocol] = []
    private var statusObserver: AnyCancellable?

    init() {
        model = UsageDashboardModel(history: UsageHistoryModel(url: UsageHistoryDatabase.defaultURL))
        model.collectorService = service
        statusObserver = service.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.load()
            self?.model.objectWillChange.send()
        }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: CollectorMessage.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.load() }
        })
        observers.append(center.addObserver(forName: CollectorMessage.history, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.history.reload() }
        })
        load()
        service.startIfWanted()
        CollectorMessage.send("publish")
    }

    deinit { for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) } }

    func load() {
        guard let state = CollectorState.read() else { return }
        model.snapshot = state.snapshot
        model.plans = state.plans
        model.refreshing = service.enabled && Date().timeIntervalSince(state.snapshot.generatedAt) < 120 ? state.refreshing : []
        model.history.recordingError = state.historyError
    }

    func send(_ command: String) {
        // A manual refresh does not silently override the user's pause choice.
        guard service.enabled else {
            if service.needsApproval { service.openApproval() }
            return
        }
        CollectorMessage.send(command)
    }
}
