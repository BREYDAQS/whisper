import AppKit

/// Sprzątanie po dawnej nazwie (call-whisper.app -> brqs-whisper.app).
///
/// Dane zostają tam, gdzie były (ustawienia, modele, logi, biblioteka) —
/// nowa apka z nich korzysta. Usuwamy tylko to, co zostało po starej
/// aplikacji: jej paczkę obok nowej i jej ikonę w Docku, która po usunięciu
/// paczki pokazywałaby znak zapytania.
enum LegacyCleanup {
    private static let oldName = "call-whisper.app"
    private static let newName = "brqs-whisper.app"

    static func run() {
        guard Bundle.main.bundleURL.lastPathComponent == newName else { return }
        removeOldBundle()
        fixDock()
    }

    /// Stara paczka obok nowej — do kosza (da się odzyskać), nie na stałe.
    private static func removeOldBundle() {
        let old = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(oldName)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
    }

    /// Ikona starej apki w Docku -> ta sama pozycja, nowa apka. Gdy nowa już
    /// jest przypięta, stara pozycja po prostu znika.
    private static func fixDock() {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let apps = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else { return }

        func url(_ app: [String: Any]) -> String? {
            ((app["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String
        }
        var hasNew = apps.contains { url($0)?.contains("/\(newName)") == true }
        var changed = false
        let updated: [[String: Any]] = apps.compactMap { app in
            guard let u = url(app), u.contains("/\(oldName)") else { return app }
            changed = true
            if hasNew { return nil }
            hasNew = true
            var app = app
            var tile = app["tile-data"] as? [String: Any] ?? [:]
            var file = tile["file-data"] as? [String: Any] ?? [:]
            file["_CFURLString"] = Bundle.main.bundleURL.absoluteString
            file["_CFURLStringType"] = 15
            tile["file-data"] = file
            tile["file-label"] = "brqs-whisper"
            // Zakładka wskazuje na starą ścieżkę — bez niej Dock czyta URL.
            tile.removeValue(forKey: "book")
            app["tile-data"] = tile
            return app
        }
        guard changed else { return }
        CFPreferencesSetAppValue(key, updated as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        // Dock czyta swoje ustawienia tylko przy starcie.
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        try? restart.run()
    }
}
