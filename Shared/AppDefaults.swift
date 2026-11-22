import Foundation

extension UserDefaults {
    /// The collector owns account settings, using the existing app's domain.
    /// Widgets and test-injected suites retain their own defaults.
    static let codenotch: UserDefaults =
        Bundle.main.object(forInfoDictionaryKey: "CodenotchCollector") as? Bool == true
        ? UserDefaults(suiteName: "com.r0llingclouds.codenotch")! : .standard
}
