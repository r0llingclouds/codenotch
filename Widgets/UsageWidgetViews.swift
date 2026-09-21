import SwiftUI
import WidgetKit

private let widgetInk = Color(red: 0.93, green: 0.95, blue: 1)
private let widgetMuted = Color(red: 0.58, green: 0.63, blue: 0.73)

struct WidgetBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.055, blue: 0.085)
            LinearGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.20), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.indigo.opacity(0.13), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 290)
        }
    }
}

private struct ProviderStyle {
    let id: String
    var color: Color {
        switch id {
        case "codex": return Color(red: 0.44, green: 0.86, blue: 0.72)
        case "cursor": return Color(red: 0.79, green: 0.84, blue: 0.94)
        case "claude": return Color(red: 1, green: 0.64, blue: 0.44)
        case "kimi": return Color(red: 0.77, green: 0.65, blue: 1)
        case "glm": return Color(red: 0.46, green: 0.78, blue: 0.98)
        case "deepseek": return Color(red: 0.52, green: 0.65, blue: 1)
        case "gemini-chat": return Color(red: 0.65, green: 0.70, blue: 1)
        case "notebooklm": return Color(red: 0.44, green: 0.84, blue: 0.86)
        default: return Color(red: 1, green: 0.59, blue: 0.76)
        }
    }
    var outline: [[CGPoint]] {
        switch id {
        case "codex": return GlyphOutline.openai
        case "claude": return GlyphOutline.claude
        case "cursor": return GlyphOutline.cursor
        case "kimi": return GlyphOutline.kimi
        case "glm": return GlyphOutline.glm
        case "gemini-chat": return GlyphOutline.gemini
        default: return []
        }
    }
}

private struct WidgetLogoShape: Shape {
    let outline: [[CGPoint]]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline where !loop.isEmpty {
            let points = loop.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            path.addLines(points)
            path.closeSubpath()
        }
        return path
    }
}

private struct ProviderMark: View {
    let id: String
    var size: CGFloat = 16
    var body: some View {
        let style = ProviderStyle(id: id)
        Group {
            if ["kimi", "glm", "deepseek"].contains(id), let image = NSImage(named: "glyph-\(id)") {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
            } else if !style.outline.isEmpty {
                WidgetLogoShape(outline: style.outline).fill(style: FillStyle(eoFill: true))
            } else {
                Image(systemName: id == "notebooklm" ? "book.closed.fill" : id == "google-flow" ? "play.rectangle.fill" : "water.waves")
                    .resizable().scaledToFit()
            }
        }
        .foregroundStyle(style.color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private func statusText(_ state: WidgetProviderReading.State) -> String {
    switch state {
    case .ready: return ""
    case .stale: return L10n.t("Out of date")
    case .notConnected: return L10n.t("Connect account")
    case .disabled: return L10n.t("Enable in app")
    case .unavailable: return L10n.t("Usage unavailable")
    }
}

private func compactLabel(_ meter: WidgetUsageMeter) -> String {
    switch meter.id {
    case "session", "current": return L10n.t("Session")
    case "weekly", "weekly_all": return L10n.t("Week")
    case "monthly": return L10n.t("Month")
    case "monthly-code": return L10n.t("Code")
    case "rolling": return "5h"
    case "auto": return L10n.t("Auto")
    case "api": return "API"
    default:
        if meter.label == "Weekly limit" { return L10n.t("Week") }
        return meter.label
    }
}

private func percentageNumber(_ fraction: Double) -> String {
    if fraction > 0 && fraction < 0.01 { return "<1" }
    return String(Int((fraction * 100).rounded()))
}

private struct MeterTrack: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.13))
                if fraction > 0 {
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
        }.frame(height: 3)
            .accessibilityHidden(true)
    }
}

private struct CompactMeter: View {
    let meter: WidgetUsageMeter
    let color: Color
    var narrow = false
    var condensed = false
    var emphasized = false
    var large = false
    var body: some View {
        VStack(alignment: .leading, spacing: condensed ? 2 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percentageNumber(meter.usedFraction ?? 0))
                    .font(.system(size: condensed ? 11 : large ? 22 : narrow ? 15 : 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(emphasized ? color : widgetInk)
                Text("%").font(.system(size: condensed ? 7 : large ? 10 : 9, weight: .medium)).foregroundStyle(widgetMuted)
                if !narrow {
                    Spacer(minLength: 2)
                    Text(compactLabel(meter)).font(.system(size: 8, weight: .medium))
                        .foregroundStyle(widgetMuted).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            if narrow {
                Text(compactLabel(meter)).font(.system(size: large ? 8 : 7, weight: .medium))
                    .foregroundStyle(widgetMuted).lineLimit(1).minimumScaleFactor(0.8)
            }
            MeterTrack(fraction: meter.usedFraction ?? 0, color: (meter.usedFraction ?? 0) >= 0.9 ? .red : color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(meter.value)")
    }
}

private struct FeaturedQuota: View {
    let meter: WidgetUsageMeter
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(compactLabel(meter)).font(.system(size: 8, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(meter.usedFraction.map { "\(percentageNumber($0))%" } ?? meter.value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            if let fraction = meter.usedFraction { MeterTrack(fraction: fraction, color: color) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(meter.value)")
    }
}

private struct CreditAmount: View {
    let meter: WidgetUsageMeter
    let color: Color
    var large = false
    var stacked = false
    var body: some View {
        // This remains a balance, never a fabricated percent of a plan limit.
        let amount = meter.value.replacingOccurrences(of: " left", with: "")
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 5))
        layout {
            Text(amount).font(.system(size: large ? 29 : 21, weight: .semibold, design: .rounded))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            if !large {
                Text(meter.id == "credits" ? L10n.t("credits") : L10n.t("available"))
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(widgetMuted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(meter.value)")
    }
}

private struct CompactProviderCard: View {
    let reading: WidgetProviderReading
    let date: Date
    var narrow = false
    var expanded = false
    var body: some View {
        let color = ProviderStyle(id: reading.id).color
        let state = reading.effectiveState(at: date)
        VStack(alignment: .leading, spacing: expanded ? 8 : 4) {
            HStack(spacing: 6) {
                ProviderMark(id: reading.id, size: expanded ? 15 : 13)
                Text(reading.name).font(.system(size: expanded ? 12 : narrow ? 10 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if state == .stale {
                    Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.orange)
                        .accessibilityLabel(L10n.t("Out of date"))
                }
            }
            if (state == .ready || state == .stale), !reading.meters.isEmpty {
                let meters = UsageMeterSelection.overviewMeters(for: reading)
                if let balance = meters.first, balance.usedFraction == nil {
                    CreditAmount(meter: balance, color: color, stacked: narrow)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else if expanded {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(meters) { meter in
                            CompactMeter(meter: meter, color: color, narrow: true,
                                         emphasized: UsageMeterSelection.isFable(meter), large: true)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                } else if narrow, meters.count == 3, let featured = meters.first {
                    VStack(spacing: 2) {
                        FeaturedQuota(meter: featured, color: color)
                        HStack(alignment: .top, spacing: 5) {
                            ForEach(Array(meters.dropFirst())) { meter in
                                CompactMeter(meter: meter, color: color, narrow: true, condensed: true)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: narrow ? 5 : 10) {
                        ForEach(meters) { meter in
                            CompactMeter(meter: meter, color: color, narrow: narrow,
                                         emphasized: reading.id == "claude" && UsageMeterSelection.isFable(meter))
                        }
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: state == .notConnected ? "plus.circle" : "minus.circle")
                    Text(statusText(state)).lineLimit(narrow ? 2 : 1)
                        .multilineTextAlignment(.leading)
                }.font(.system(size: narrow ? 9 : 10)).foregroundStyle(widgetMuted)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, narrow ? 8 : 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.075), Color.white.opacity(0.022)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [color.opacity(0.19), .white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                }
        }
    }
}

private struct WidgetFooter: View {
    let snapshot: UsageWidgetSnapshot
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8, weight: .medium))
            if snapshot.generatedAt == .distantPast {
                Text(L10n.t("Open Codenotch to get started"))
            } else {
                Text(snapshot.generatedAt, style: .relative).monospacedDigit()
            }
            Spacer()
            Text(L10n.t("Usage & balances")).tracking(0.3)
            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 8, weight: .medium)).foregroundStyle(widgetMuted)
    }
}

struct UsageOverview: View {
    let snapshot: UsageWidgetSnapshot
    let date: Date
    var googleOnly = false

    private func columnSpan(for reading: WidgetProviderReading) -> Int {
        !googleOnly && reading.id == "claude" ? 2 : 1
    }

    private var cardRows: [[WidgetProviderReading]] {
        let readings = snapshot.providers.filter {
            googleOnly ? ["gemini-chat", "notebooklm", "google-flow"].contains($0.id)
                       : $0.id != "google-flow"
        }
        var rows: [[WidgetProviderReading]] = []
        var row: [WidgetProviderReading] = []
        var columnsUsed = 0
        for reading in readings {
            let span = columnSpan(for: reading)
            if columnsUsed + span > 3 {
                rows.append(row)
                row = []
                columnsUsed = 0
            }
            row.append(reading)
            columnsUsed += span
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    var body: some View {
        let rows = cardRows
        VStack(alignment: .leading, spacing: 8) {
            Text(googleOnly ? "Google AI Pro" : L10n.t("AI usage"))
                .font(.system(size: googleOnly ? 17 : 18, weight: .semibold, design: .rounded))
                .tracking(-0.5)
            GeometryReader { geometry in
                let gap: CGFloat = 7
                let rowCount = max(1, rows.count)
                let height = max(0, (geometry.size.height - CGFloat(rowCount - 1) * gap) / CGFloat(rowCount))
                let columnWidth = max(0, (geometry.size.width - 2 * gap) / 3)
                VStack(spacing: gap) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(rows[row]) { reading in
                                let span = columnSpan(for: reading)
                                Link(destination: URL(string: "codenotch-usage://provider/\(reading.id)")!) {
                                    CompactProviderCard(reading: reading, date: date,
                                                        narrow: span == 1, expanded: span == 2)
                                }
                                .buttonStyle(.plain)
                                .frame(width: columnWidth * CGFloat(span) + gap * CGFloat(span - 1))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
                    }
                }
            }
            WidgetFooter(snapshot: snapshot, date: date)
        }
        .foregroundStyle(widgetInk)
        .padding(16)
    }
}

private struct UsageRing: View {
    let fraction: Double
    let color: Color
    var caption = L10n.t("used")
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.12), lineWidth: 7)
            if fraction > 0 {
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(AngularGradient(colors: [color.opacity(0.5), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * min(fraction, 1))),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(percentageNumber(fraction))%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(caption).font(.system(size: 9, weight: .medium)).foregroundStyle(widgetMuted)
            }
        }.accessibilityHidden(true)
    }
}

private struct ResetCaption: View {
    let meter: WidgetUsageMeter
    let date: Date
    var body: some View {
        Group {
            if let reset = meter.resetsAt {
                if reset > date {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                        Text(reset, style: .relative)
                    }
                } else { Text(L10n.t("Reset due · refresh needed")) }
            } else if let description = meter.resetDescription {
                Text(description)
            }
        }
        .font(.system(size: 9, weight: .medium)).foregroundStyle(widgetMuted).lineLimit(1).minimumScaleFactor(0.7)
    }
}

struct SingleProviderView: View {
    let reading: WidgetProviderReading
    let date: Date
    var family: WidgetFamily = .systemSmall
    var body: some View {
        let color = ProviderStyle(id: reading.id).color
        let state = reading.effectiveState(at: date)
        let usable = state == .ready || state == .stale
        let meters = UsageMeterSelection.prioritizedMeters(for: reading)
        let smallWithThree = family == .systemSmall && meters.count > 2
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProviderMark(id: reading.id, size: 19)
                Text(reading.name).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if state == .stale { Image(systemName: "clock").foregroundStyle(.orange) }
                else { Image(systemName: "arrow.up.right").foregroundStyle(widgetMuted) }
            }.font(.system(size: 9, weight: .medium))
            if usable, let meter = meters.first {
                if let fraction = meter.usedFraction {
                    HStack(spacing: 19) {
                        VStack(spacing: smallWithThree ? 4 : 6) {
                            UsageRing(fraction: fraction, color: fraction >= 0.9 ? .red : color,
                                      caption: family == .systemSmall && meters.count > 1 ? compactLabel(meter) : L10n.t("used"))
                                .frame(width: smallWithThree ? 60 : family == .systemSmall ? 66 : 68,
                                       height: smallWithThree ? 60 : family == .systemSmall ? 66 : 68)
                            if family == .systemSmall, meters.count > 1 {
                                VStack(spacing: 2) {
                                    ForEach(Array(meters.dropFirst().prefix(2))) { secondary in
                                        HStack(spacing: 4) {
                                            Text(compactLabel(secondary)).foregroundStyle(widgetMuted)
                                            Text(secondary.usedFraction.map { "\(percentageNumber($0))%" } ?? secondary.value)
                                                .foregroundStyle(color).monospacedDigit()
                                        }.font(.system(size: 9, weight: .medium))
                                    }
                                }
                            } else {
                                Text(compactLabel(meter)).font(.system(size: 9, weight: .medium)).foregroundStyle(widgetMuted)
                            }
                        }.frame(maxWidth: family == .systemSmall ? .infinity : nil)
                        if family == .systemMedium {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(meters.dropFirst().prefix(2))) { secondary in
                                    VStack(alignment: .leading, spacing: 4) {
                                        CompactMeter(meter: secondary, color: color)
                                        ResetCaption(meter: secondary, date: date)
                                    }
                                }
                                if meters.count == 1 {
                                    Text(L10n.t("Your allowance, at a glance.")).font(.system(size: 12)).foregroundStyle(widgetMuted)
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }.frame(maxHeight: .infinity)
                    ResetCaption(meter: meter, date: date)
                        .frame(maxWidth: .infinity, alignment: family == .systemSmall ? .center : .leading)
                } else {
                    Spacer(minLength: 0)
                    CreditAmount(meter: meter, color: color, large: true)
                    Text(reading.id == "google-flow" ? L10n.t("credits available") : L10n.t("available balance"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(widgetMuted)
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
                Image(systemName: "link.badge.plus").font(.system(size: 25, weight: .light)).foregroundStyle(color)
                Text(statusText(state)).font(.system(size: 12, weight: .medium))
                Text(L10n.t("Open Codenotch to connect.")).font(.system(size: 10)).foregroundStyle(widgetMuted)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(widgetInk).padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([reading.name, statusText(state)] + (usable ? reading.meters.map { "\($0.label), \($0.value)" } : [])).filter { !$0.isEmpty }.joined(separator: ". "))
    }
}
