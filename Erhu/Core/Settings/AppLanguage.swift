import SwiftUI
import UIKit

/// The app's display language. iOS keeps the per-app language choice in the Settings app (Settings →
/// Erhu → Language), so Erhu shows the current language and opens that page rather than switching
/// languages itself, which would need a relaunch and could disagree with the system's choice.
enum AppLanguage {
    /// The language Erhu is showing, named in that language ("Polski", "日本語").
    static var currentName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.capitalized(with: locale)
    }

    /// Opens Erhu's page in the Settings app, where its Language option lives.
    @MainActor static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
