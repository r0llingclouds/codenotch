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
    default:
        if meter.label == "Weekly limit" { return L10n.t("Week") }
        return meter.label
    }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(((meter.usedFraction ?? 0) * 100).rounded()))")
                    .font(.system(size: narrow ? 15 : 16, weight: .semibold, design: .rounded))
                Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(widgetMuted)
                if !narrow {
                    Spacer(minLength: 2)
                    Text(compactLabel(meter)).font(.system(size: 8, weight: .medium))
                        .foregroundStyle(widgetMuted).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            if narrow {
                Text(compactLabel(meter)).font(.system(size: 7, weight: .medium)).foregroundStyle(widgetMuted).lineLimit(1)
            } else {
                MeterTrack(fraction: meter.usedFraction ?? 0, color: (meter.usedFraction ?? 0) >= 0.9 ? .red : color)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label), \(meter.value)")
    }
}

private struct CreditAmount: View {
    let meter: WidgetUsageMeter
    let color: Color
    var large = false
    var body: some View {
        // This remains a balance, never a fabricated percent of a plan limit.
        let amount = meter.value.replacingOccurrences(of: " left", with: "")
        HStack(alignment: .firstTextBaseline, spacing: 5) {
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
    var body: some View {
        let color = ProviderStyle(id: reading.id).color
        let state = reading.effectiveState(at: date)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderMark(id: reading.id, size: 13)
                Text(reading.name).font(.system(size: narrow ? 10 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if state == .stale {
                    Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.orange)
                        .accessibilityLabel(L10n.t("Out of date"))
                }
            }
            if (state == .ready || state == .stale), !reading.meters.isEmpty {
                let meters = Array(reading.meters.prefix(2))
                if let balance = meters.first, balance.usedFraction == nil {
                    CreditAmount(meter: balance, color: color)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    HStack(alignment: .top, spacing: narrow ? 5 : 10) {
                        ForEach(meters) { meter in CompactMeter(meter: meter, color: color, narrow: narrow) }
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: state == .notConnected ? "plus.circle" : "minus.circle")
                    Text(statusText(state)).lineLimit(1)
                }.font(.system(size: 10)).foregroundStyle(widgetMuted)
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
    var body: some View {
        let readings = snapshot.providers.filter { !googleOnly || ["gemini-chat", "notebooklm", "google-flow"].contains($0.id) }
        let ready = readings.filter { $0.effectiveState(at: date) == .ready }.count
        VStack(alignment: .leading, spacing: googleOnly ? 9 : 11) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CODENOTCH").font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(2).foregroundStyle(widgetMuted)
                    Text(googleOnly ? "Google AI Pro" : L10n.t("AI usage"))
                        .font(.system(size: googleOnly ? 17 : 20, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(ready == readings.count ? Color(red: 0.44, green: 0.86, blue: 0.72) : Color.orange)
                        .frame(width: 4, height: 4)
                    Text("\(ready)/\(readings.count)").monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(widgetMuted)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.04), in: Capsule())
                .accessibilityLabel(L10n.t("\(ready) providers with current readings"))
            }
            GeometryReader { geometry in
                let columns = googleOnly ? 3 : 2
                let rows = googleOnly ? 1 : 4
                let gap: CGFloat = 7
                let height = max(0, (geometry.size.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(Array(readings.dropFirst(row * columns).prefix(columns))) { reading in
                                Link(destination: URL(string: "codenotch-usage://provider/\(reading.id)")!) {
                                    CompactProviderCard(reading: reading, date: date, narrow: googleOnly)
                                }.buttonStyle(.plain)
                            }
                        }.frame(height: height)
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
                Text("\(Int((fraction * 100).rounded()))%")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProviderMark(id: reading.id, size: 19)
                Text(reading.name).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if state == .stale { Image(systemName: "clock").foregroundStyle(.orange) }
                else { Image(systemName: "arrow.up.right").foregroundStyle(widgetMuted) }
            }.font(.system(size: 9, weight: .medium))
            if usable, let meter = reading.meters.first {
                if let fraction = meter.usedFraction {
                    HStack(spacing: 19) {
                        VStack(spacing: 6) {
                            UsageRing(fraction: fraction, color: fraction >= 0.9 ? .red : color,
                                      caption: family == .systemSmall && reading.meters.count > 1 ? compactLabel(meter) : L10n.t("used"))
                                .frame(width: family == .systemSmall ? 66 : 68, height: family == .systemSmall ? 66 : 68)
                            if family == .systemSmall, let secondary = reading.meters.dropFirst().first {
                                HStack(spacing: 4) {
                                    Text(compactLabel(secondary)).foregroundStyle(widgetMuted)
                                    Text(secondary.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? secondary.value)
                                        .foregroundStyle(color).monospacedDigit()
                                }.font(.system(size: 9, weight: .medium))
                            } else {
                                Text(compactLabel(meter)).font(.system(size: 9, weight: .medium)).foregroundStyle(widgetMuted)
                            }
                        }.frame(maxWidth: family == .systemSmall ? .infinity : nil)
                        if family == .systemMedium {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(reading.meters.dropFirst().prefix(2))) { secondary in
                                    VStack(alignment: .leading, spacing: 4) {
                                        CompactMeter(meter: secondary, color: color)
                                        ResetCaption(meter: secondary, date: date)
                                    }
                                }
                                if reading.meters.count == 1 {
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
