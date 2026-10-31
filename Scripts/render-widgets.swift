// Native SwiftUI render of the actual widget views. No example usage is invented.
// swiftc this file with UsageWidgetViews, UsageWidgetSnapshot, GlyphOutline,
// L10n and AppLanguage. Pass a normalized snapshot JSON and an output directory.
import AppKit
import SwiftUI
import WidgetKit

@main
struct RenderWidgets {
    @MainActor static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let snapshot = try JSONDecoder().decode(UsageWidgetSnapshot.self, from: Data(contentsOf: input))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, view: V) throws {
            let canvas = view.frame(width: width, height: height)
                .background(WidgetBackdrop()).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw NSError(domain: "WidgetRender", code: 1)
            }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
        try render("overview", width: 345, height: 345, view: UsageOverview(snapshot: snapshot, date: now))
        try render("google", width: 345, height: 164, view: UsageOverview(snapshot: snapshot, date: now, googleOnly: true))
        if let claude = snapshot.providers.first(where: { $0.id == "claude" }) {
            try render("provider-small", width: 164, height: 164, view: SingleProviderView(reading: claude, date: now))
            try render("provider-medium", width: 345, height: 164, view: SingleProviderView(reading: claude, date: now, family: .systemMedium))
        }
        try render("unconnected", width: 345, height: 345, view: UsageOverview(snapshot: .empty, date: now))
    }
}
