import AppKit
import SwiftUI

@MainActor
final class UsageDashboardWindowController: NSObject, NSWindowDelegate {
    let model: UsageDashboardModel
    private(set) var window: NSWindow?
    private let preferences: Preferences
    private let refreshAll: () -> Void
    private let refreshProvider: (String) -> Void
    private let openSettings: () -> Void
    var keepRegularPresence: () -> Bool = { false }

    var isVisible: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    init(model: UsageDashboardModel, preferences: Preferences,
         refreshAll: @escaping () -> Void, refreshProvider: @escaping (String) -> Void,
         openSettings: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.refreshAll = refreshAll
        self.refreshProvider = refreshProvider
        self.openSettings = openSettings
    }

    func show(providerID: String? = nil) {
        model.select(providerID)
        if providerID != nil { model.showsHistory = false }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = L10n.t("AI Usage")
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.10, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentMinSize = NSSize(width: 880, height: 600)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: UsageDashboardView(
                model: model, refreshAll: refreshAll, refreshProvider: refreshProvider,
                openSettings: openSettings))
            window.center()
            window.setFrameAutosaveName("UsageDashboard")
            self.window = window
        }
        guard let window else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the app in the Dock while Settings is still open. Closing the
        // dashboard only hides a window; UsageStore and the widgets keep going.
        NSApp.setActivationPolicy(keepRegularPresence() ? .regular : preferences.appPresence.activationPolicy)
    }
}
