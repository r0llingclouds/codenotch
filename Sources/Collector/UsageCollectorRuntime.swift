import AppKit
import Combine

/// The only polling/history owner in personal builds. No dashboard, notch or
/// status item is constructed here; account windows are created on demand.
@MainActor
final class UsageCollectorRuntime {
    private let preferences: Preferences
    private let store: UsageStore
    private let publisher = WidgetSnapshotPublisher()
    private let database = UsageHistoryDatabase(url: UsageHistoryDatabase.defaultURL)
    private var settings: SettingsWindowController?
    private var activity: ActivityCoordinator?
    private var tokenRefresher: ClaudeTokenRefresher?
    private var observer: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var historyError = false

    init(preferences: Preferences) {
        self.preferences = preferences
        let claudeProfiles = ClaudeProfile.discover()
        let codexProfiles = CodexProfile.discover()
        let antigravityProfiles = AntigravityProfile.discover()
        let claude = claudeProfiles.map { ClaudeOAuthProvider(profile: $0) }
        let miniMax = WebSessionProvider(site: Sites.minimax(region: preferences.minimaxRegion))
        let web = [WebSessionProvider(site: Sites.deepSeek), WebSessionProvider(site: Sites.qianwen)]
            + GoogleUsagePages.sites.map { WebSessionProvider(site: $0) }
        let providers: [UsageProvider] = claude + [CursorLocalProvider()]
            + codexProfiles.map { CodexLocalProvider(profile: $0) }
            + antigravityProfiles.map { AntigravityProvider(profile: $0) }
            + [GLMProvider(), MiniMaxProvider(web: miniMax), GrokLocalProvider(), DevinLocalProvider(),
               OpenCodeProvider(), CommandCodeProvider(), GitHubCopilotProvider(), KimiProvider(), KiroProvider(),
               OllamaLocalProvider(endpoint: URL(string: preferences.ollamaEndpoint)!),
               LMStudioLocalProvider(endpoint: URL(string: preferences.lmstudioEndpoint)!), OllamaProvider(),
               GeminiAPIProvider(budget: { Preferences.storedGeminiAPIMonthlyTokenBudget() })] + web
        preferences.reconcile(discoveredIDs: providers.map(\.id))
        let store = UsageStore(providers: providers,
            disconnected: preferences.disconnectedIDs(among: providers.map(\.id)), order: preferences.providerOrder)
        self.store = store
        for provider in web + [miniMax] {
            provider.onAuthenticated = { [weak store, weak provider] in
                guard let provider else { return }
                store?.providerAuthenticationChanged(providerID: provider.id)
            }
        }
        store.onHistoryReading = { [weak self] snapshot, date in
            guard let self else { return }
            let records = UsageHistoryRecord.readings(from: snapshot, at: date)
            guard !records.isEmpty else { return }
            Task {
                let previousError = self.historyError
                do {
                    try await self.database.append(records)
                    self.historyError = false
                    CollectorMessage.notify(CollectorMessage.history)
                } catch { self.historyError = true }
                // Snapshot publications are already coalesced below. A history
                // write per provider must not spend a widget reload per row.
                if self.historyError != previousError { self.publish() }
            }
        }
        Publishers.CombineLatest3(store.$snapshots, store.$disconnected, store.$refreshing)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.publish() }.store(in: &subscriptions)
        Publishers.CombineLatest(preferences.$connectedProviders, preferences.$disabledModels)
            .receive(on: RunLoop.main)
            .sink { [weak store, weak preferences] _, _ in
                guard let store, let preferences else { return }
                store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
            }.store(in: &subscriptions)
        preferences.$providerOrder.receive(on: RunLoop.main)
            .sink { [weak store] in store?.order = $0 }.store(in: &subscriptions)
        preferences.$minimaxRegion.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak miniMax, weak store] region in
                miniMax?.apply(site: Sites.minimax(region: region)); store?.refresh(providerID: "minimax")
            }.store(in: &subscriptions)
        preferences.$ollamaEndpoint.receive(on: RunLoop.main).sink { [weak store] address in
            guard let url = try? OllamaEndpoint.parse(address) else { return }; store?.updateOllamaEndpoint(url)
        }.store(in: &subscriptions)
        preferences.$lmstudioEndpoint.receive(on: RunLoop.main).sink { [weak store] address in
            guard let url = try? LMStudioEndpoint.parse(address) else { return }; store?.updateLMStudioEndpoint(url)
        }.store(in: &subscriptions)
        preferences.$geminiAPIMonthlyTokenBudget.dropFirst().receive(on: RunLoop.main)
            .sink { [weak store] _ in store?.refresh(providerID: "gemini-api") }.store(in: &subscriptions)

        let muted: (String) -> Bool = { [weak preferences] in preferences?.isMutedAlerts(for: $0) ?? false }
        let threshold = ThresholdNotifier(isMuted: muted, deliver: { ThresholdAlerts.deliver($0) })
        let resets = UsageResetWatcher(isMuted: muted) { [weak preferences] event in
            guard let preferences else { return }
            if preferences.usageResetSound { SessionChime.play(preferences.usageResetSoundName) }
            if preferences.announceUsageReset { UsageAlertNotifications.deliver(event) }
        }
        let limits = UsageLimitWatcher(isMuted: muted) { [weak preferences] event in
            guard let preferences else { return }
            let enabled: Bool
            switch event.kind {
            case .sessionLimitReached: enabled = preferences.announceSessionLimitReached
            case .weeklyLimitReached: enabled = preferences.announceWeeklyLimitReached
            case .reset: enabled = preferences.announceUsageReset
            }
            guard enabled else { return }
            if preferences.limitReachedSound { SessionChime.play(preferences.limitReachedSoundName) }
            UsageAlertNotifications.deliver(event)
        }
        store.$snapshots.receive(on: RunLoop.main).sink { snapshots in
            threshold.observe(snapshots); resets.observe(snapshots); limits.observe(snapshots)
        }.store(in: &subscriptions)

        var monitors: [String: any AgentActivityMonitor] = [
            "cursor": CursorActivityMonitor(), "grok": GrokActivityMonitor(),
            "gemini-api": GeminiAPIActivityMonitor(), "kimi": KimiActivityMonitor()
        ]
        for profile in codexProfiles { monitors[profile.id] = CodexActivityMonitor(profile: profile) }
        for profile in antigravityProfiles { monitors[profile.id] = AntigravityActivityMonitor(profile: profile) }
        var claudeMonitors: [ClaudeSessionMonitor] = []
        for profile in claudeProfiles {
            let monitor = ClaudeSessionMonitor(directory: profile.sessionsDirectory, projects: profile.projectsDirectory)
            monitors[profile.id] = monitor; claudeMonitors.append(monitor)
        }
        if let provider = claude.first(where: { $0.profile.slug == nil }) {
            let refresher = ClaudeTokenRefresher(expiry: { await provider.tokenExpiry },
                                                reload: { await provider.reloadTokenExpiry() })
            for monitor in claudeMonitors {
                monitor.ignoredPIDs = { [weak refresher] in refresher?.launchedPID.map { [$0] } ?? [] }
            }
            refresher.$outcome.receive(on: RunLoop.main).sink { [weak store] outcome in
                if case .failed = outcome { store?.reportRenewalFailed(providerID: provider.id) }
            }.store(in: &subscriptions)
            tokenRefresher = refresher
            refresher.start()
        }
        let activity = ActivityCoordinator(monitors: monitors) { _, _ in }
        self.activity = activity
        let monitorIDs = Set(monitors.keys)
        preferences.$connectedProviders.receive(on: RunLoop.main).sink { [weak activity, weak preferences] _ in
            guard let preferences else { return }
            activity?.setEnabled(Set(monitorIDs.filter { preferences.isConnected($0) }))
        }.store(in: &subscriptions)
        store.isBusy = { [weak activity] in activity?.isBusy ?? false }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: CollectorMessage.command, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.object as? String else { return }
                Task { @MainActor in self?.handle(raw) }
            }
        publish()
        store.start()
    }

    func publish() {
        let snapshot = WidgetSnapshotPublisher.makeSnapshot(store.snapshots,
            disconnected: store.disconnected, dates: store.widgetMeasurementDates)
        let plans = Dictionary(uniqueKeysWithValues: store.snapshots.compactMap { reading -> (String, String)? in
            guard !store.disconnected.contains(reading.id), let plan = reading.plan else { return nil }
            return (reading.id, plan)
        })
        do {
            try CollectorState(snapshot: snapshot, plans: plans, refreshing: store.refreshing, historyError: historyError).save()
            CollectorMessage.notify(CollectorMessage.changed)
        } catch { Log.usage.error("Unable to publish collector state: \(error.localizedDescription, privacy: .public)") }
        publisher.publish(snapshot)
    }

    private func handle(_ raw: String) {
        guard let command = CollectorMessage.Command(raw, providers: Set(store.knownIDs)) else { return }
        switch command {
        case .refreshAll: store.refreshNow()
        case .refresh(let id): store.refresh(providerID: id)
        case .settings: openSettings()
        case .publish: publish()
        }
    }

    func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(preferences: preferences,
                providers: { [weak store] in store?.providerSummaries ?? [] }, updater: Updater(),
                signOut: { [weak store] in store?.signOut(providerID: $0) },
                signIn: { [weak store] in store?.signIn(providerID: $0) ?? false },
                switchAccount: { [weak store] in store?.openAccountSource(providerID: $0, switching: true) ?? false },
                retry: { [weak store] in store?.reauthorize(providerID: $0) }, resetPosition: {},
                quit: { [weak self] in self?.closeSettings() }, usageStore: store)
        }
        settings?.show()
    }

    func closeSettings() { settings?.close(); NSApp.setActivationPolicy(.accessory) }
    func stop() {
        store.stop(); activity?.stop(); tokenRefresher?.stop()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
