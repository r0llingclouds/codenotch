import SwiftUI

@main
struct CodenotchMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppKit owns the dashboard and settings windows; SwiftUI supplies
        // their contents and application commands.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    if Runtime.isCollector {
                        Button(L10n.t("Close account settings")) { appDelegate.closeCollectorSettings() }
                            .keyboardShortcut("q", modifiers: .command)
                    } else {
                        Button(L10n.t("Quit Codenotch")) { NSApp.terminate(nil) }
                            .keyboardShortcut("q", modifiers: .command)
                    }
                }

                CommandGroup(replacing: .newItem) {
                    Button(L10n.t("Close Window")) { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w", modifiers: .command)
                }
                CommandGroup(before: .appSettings) {
                    Button(L10n.t("Open AI Usage")) { appDelegate.openDashboard() }
                        .keyboardShortcut("1", modifiers: .command)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
