import SwiftUI

let dashboardInk = Color(red: 0.93, green: 0.95, blue: 1)
let dashboardMuted = Color(red: 0.61, green: 0.66, blue: 0.76)

struct UsageDashboardView: View {
    @ObservedObject var model: UsageDashboardModel
    var refreshAll: () -> Void
    var refreshProvider: (String) -> Void
    var openSettings: () -> Void

    var body: some View {
        // Relative dates redraw locally once a minute. Only UsageStore makes
        // requests, at the existing idle/active cadence.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    overview(at: context.date, width: geometry.size.width)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let reading = model.selectedReading, !model.showsHistory {
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    DashboardDetail(reading: reading, plan: model.plans[reading.id],
                                    date: context.date, refreshing: model.refreshing.contains(reading.id), canRefresh: model.canRefresh,
                                    refresh: { refreshProvider(reading.id) },
                                    openSettings: openSettings, close: { model.select(nil) },
                                    showHistory: {
                                        model.history.selectProvider(reading.id)
                                        model.showsHistory = true
                                    })
                        .frame(width: 310)
                        .background(.black.opacity(0.14))
                }
            }
        }
        .foregroundStyle(dashboardInk)
        .background {
            ZStack {
                Color(red: 0.055, green: 0.065, blue: 0.10)
                RadialGradient(colors: [.indigo.opacity(0.14), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 750)
            }
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { model.select(nil) }
    }

    private func overview(at date: Date, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.t("AI usage")).font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(L10n.t("Your plans, limits & balances")).font(.system(size: 13)).foregroundStyle(dashboardMuted)
                }
                Spacer(minLength: 0)
                Button(action: refreshAll) {
                    Label(L10n.t("Refresh"), systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canRefresh || !model.refreshing.isEmpty)
                .help(L10n.t("Refresh all services"))
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                    .disabled(!model.canRefresh)
                    .accessibilityLabel(L10n.t("Manage accounts"))
                    .help(L10n.t("Manage accounts"))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 26)

            HStack(spacing: 16) {
                Picker(L10n.t("Dashboard view"), selection: $model.showsHistory) {
                    Label(L10n.t("Overview"), systemImage: "square.grid.2x2").tag(false)
                    Label(L10n.t("History"), systemImage: "chart.xyaxis.line").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                HistoryRecordingBadge(model: model.history)
            }.padding(.horizontal, 28).padding(.bottom, 18)

            if model.showsHistory {
                UsageHistoryView(model: model.history)
            } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                        count: width >= 740 ? 3 : 2), spacing: 14) {
                    ForEach(model.snapshot.providers) { reading in
                        DashboardProviderButton(reading: reading, plan: model.plans[reading.id], date: date,
                                                selected: model.selectedID == reading.id,
                                                refreshing: model.refreshing.contains(reading.id),
                                                select: { model.select(reading.id) })
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            }
            HStack(spacing: 7) {
                Image(systemName: model.refreshing.isEmpty ? "clock" : "arrow.clockwise")
                Text(!model.canRefresh ? L10n.t("Automatic updates paused") :
                    (model.refreshing.isEmpty ? L10n.t("Auto refresh · 5 min idle / 1 min active") : L10n.t("Updating readings…")))
                Spacer(minLength: 0)
                if let service = model.collectorService {
                    BackgroundCollectionControl(service: service)
                } else {
                    Text(L10n.t("Widgets stay in sync"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(dashboardMuted)
            .padding(.horizontal, 28)
            .padding(.vertical, 17)
            .background(.white.opacity(0.025))
        }
    }
}

private struct BackgroundCollectionControl: View {
    @ObservedObject var service: CollectorService
    var body: some View {
        Menu {
            if service.needsApproval {
                Button(L10n.t("Open System Settings")) { service.openApproval() }
            } else if service.enabled {
                Button(L10n.t("Pause background updates")) { service.pause() }
            } else {
                Button(L10n.t("Resume background updates")) { service.enable() }
            }
            if let error = service.error { Text(error) }
            Text(L10n.t("Updates and history continue after you quit the app."))
        } label: {
            Label(service.label, systemImage: service.enabled ? "checkmark.circle" : "pause.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(service.error ?? L10n.t("Manage background updates"))
    }
}

private struct DashboardProviderButton: View {
    let reading: WidgetProviderReading
    let plan: String?
    let date: Date
    let selected: Bool
    let refreshing: Bool
    let select: () -> Void

    // Keep string construction outside the view-builder expression. Xcode 26
    // on the CI runner times out resolving the nested map/Optional.map overloads
    // inside the grid's Button, even though Xcode 27 builds it locally.
    private var accessibilityValue: String {
        let descriptions: [String] = UsageMeterSelection.prioritizedMeters(for: reading).map { meter in
            let value: String
            if let fraction = meter.usedFraction { value = DashboardCopy.percentage(fraction) }
            else { value = meter.value }
            return "\(meter.label): \(value)"
        }
        return descriptions.joined(separator: ", ")
    }

    var body: some View {
        Button(action: select) {
            DashboardCard(reading: reading, plan: plan, date: date,
                          selected: selected, refreshing: refreshing)
        }
        .buttonStyle(DashboardCardButtonStyle())
        .accessibilityLabel(reading.name + ", " + DashboardCopy.state(reading, at: date))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.t("Show usage details"))
    }
}

private struct DashboardCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
    }
}

private struct DashboardCard: View {
    let reading: WidgetProviderReading
    let plan: String?
    let date: Date
    let selected: Bool
    let refreshing: Bool
    @State private var hovered = false

    var body: some View {
        let tint = DashboardBrand.color(reading.id)
        let meters = UsageMeterSelection.overviewMeters(for: reading)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DashboardBrand(id: reading.id, size: 23)
                Text(reading.name).font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: selected ? "sidebar.right" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(dashboardMuted)
            }
            Text(plan ?? DashboardBrand.category(reading.id))
                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                .lineLimit(1).padding(.top, 7)
            Spacer(minLength: 15)
            if reading.meters.isEmpty {
                Text(DashboardCopy.state(reading, at: date))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(dashboardMuted)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: meters.count > 2 ? 10 : 18) {
                    ForEach(meters) { meter in
                        DashboardMeter(meter: meter, tint: tint, compact: true,
                                       prominent: reading.id == "claude" && UsageMeterSelection.isFable(meter))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 5) {
                if refreshing {
                    Image(systemName: "arrow.clockwise")
                    Text(L10n.t("Updating…"))
                } else if reading.effectiveState(at: date) != .ready {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text(DashboardCopy.state(reading, at: date))
                } else if let measuredAt = reading.measuredAt {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(ElapsedCopy.ago(since: measuredAt, now: date))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(dashboardMuted).lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 190)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [tint.opacity(selected ? 0.14 : 0.08), .white.opacity(0.018)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(tint.opacity(selected ? 0.65 : hovered ? 0.4 : 0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { hovered = $0 }
    }
}

private struct DashboardMeter: View {
    let meter: WidgetUsageMeter
    let tint: Color
    var compact = false
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meter.usedFraction.map(DashboardCopy.percentage) ?? meter.value)
                .font(.system(size: compact ? 29 : 34, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                .foregroundStyle(meter.usedFraction == nil || prominent ? tint : dashboardInk)
            Text(compact && meter.id == "session" ? L10n.t("Session") : meter.label)
                .font(.system(size: 11)).foregroundStyle(dashboardMuted).lineLimit(1)
            if let fraction = meter.usedFraction, fraction.isFinite, fraction >= 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 4)
                .accessibilityLabel(L10n.t("Used"))
                .accessibilityValue(DashboardCopy.percentage(fraction))
            }
        }
    }
}

private struct DashboardDetail: View {
    let reading: WidgetProviderReading
    let plan: String?
    let date: Date
    let refreshing: Bool
    let canRefresh: Bool
    let refresh: () -> Void
    let openSettings: () -> Void
    let close: () -> Void
    let showHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("Usage details")).font(.system(size: 12, weight: .medium)).foregroundStyle(dashboardMuted)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L10n.t("Close details"))
                    .accessibilityLabel(L10n.t("Close details"))
                    .keyboardShortcut(.cancelAction)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    DashboardBrand(id: reading.id, size: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(reading.name).font(.system(size: 28, weight: .semibold, design: .rounded))
                        if let plan { Text(plan).font(.system(size: 13)).foregroundStyle(dashboardMuted) }
                        Text(DashboardCopy.state(reading, at: date))
                            .font(.system(size: 12)).foregroundStyle(reading.effectiveState(at: date) == .ready ? DashboardBrand.color(reading.id) : .orange)
                    }
                    Text(DashboardCopy.scope(reading.id))
                        .font(.system(size: 12)).foregroundStyle(dashboardMuted).fixedSize(horizontal: false, vertical: true)
                    ForEach(reading.meters) { meter in
                        VStack(alignment: .leading, spacing: 12) {
                            DashboardMeter(meter: meter, tint: DashboardBrand.color(reading.id))
                            if let reset = DashboardCopy.reset(meter, at: date) {
                                Label(reset, systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let resetsAt = meter.resetsAt {
                                Text(resetsAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                            }
                        }
                        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.t("Last reading")).font(.system(size: 11, weight: .medium))
                        if let measuredAt = reading.measuredAt {
                            Text(measuredAt.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: 11)).foregroundStyle(dashboardMuted)
                        } else {
                            Text(L10n.t("No reading yet")).font(.system(size: 11)).foregroundStyle(dashboardMuted)
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            VStack(spacing: 10) {
                Button(action: showHistory) {
                    Label(L10n.t("View history"), systemImage: "chart.xyaxis.line").frame(maxWidth: .infinity)
                }
                Button(action: refresh) {
                    Label(refreshing ? L10n.t("Updating…") : L10n.t("Refresh reading"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canRefresh || refreshing || reading.state == .disabled || reading.state == .notConnected)
                Button(action: openSettings) { Text(L10n.t("Manage accounts")).frame(maxWidth: .infinity) }
                    .disabled(!canRefresh)
            }.buttonStyle(.bordered).controlSize(.large).padding(24)
        }
    }
}

struct DashboardBrand: View {
    let id: String
    let size: CGFloat
    var body: some View {
        Group {
            if let glyph {
                ProviderGlyphView(glyph: glyph, size: size)
            } else {
                Image(systemName: id == "notebooklm" ? "book.closed" : "play.rectangle.fill")
                    .font(.system(size: size * 0.85)).frame(width: size, height: size)
            }
        }.foregroundStyle(Self.color(id)).accessibilityHidden(true)
    }

    private var glyph: ProviderGlyph? {
        switch id {
        case "codex": return .openai
        case "claude": return .claude
        case "cursor": return .cursor
        case "kimi": return .kimi
        case "glm": return .glm
        case "deepseek": return .deepseek
        case "gemini-chat": return .geminiSpark
        default: return nil
        }
    }

    static func category(_ id: String) -> String {
        switch id {
        case "codex": return L10n.t("ChatGPT · Codex")
        case "deepseek": return L10n.t("API balance")
        case "gemini-chat", "notebooklm": return L10n.t("Google AI")
        case "google-flow": return L10n.t("AI credits")
        default: return L10n.t("Coding plan")
        }
    }

    static func color(_ id: String) -> Color {
        switch id {
        case "codex": return Color(red: 0.44, green: 0.86, blue: 0.72)
        case "claude": return Color(red: 1, green: 0.64, blue: 0.44)
        case "cursor": return Color(red: 0.79, green: 0.84, blue: 0.94)
        case "kimi": return Color(red: 0.77, green: 0.65, blue: 1)
        case "glm": return Color(red: 0.46, green: 0.78, blue: 0.98)
        case "deepseek": return Color(red: 0.52, green: 0.65, blue: 1)
        case "gemini-chat": return Color(red: 0.65, green: 0.70, blue: 1)
        case "notebooklm": return Color(red: 0.44, green: 0.84, blue: 0.86)
        default: return Color(red: 1, green: 0.59, blue: 0.76)
        }
    }
}
