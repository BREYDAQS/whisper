import Foundation
import CoreText

/// Fonty marki Breydaqs w paczce (Resources/Fonts, licencje OFL obok).
/// Rejestrowane dla procesu przy starcie, zanim powstanie pierwszy widok.
enum BrandFonts {
    static let sans = "Inter Tight"
    static let display = "Geist"
    static let mono = "JetBrains Mono"

    static func register() {
        // `.app`: Contents/Resources/Fonts. `swift run` / testy: katalog
        // źródeł obok tego pliku (macos/Resources/Fonts).
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/Fonts").standardizedFileURL,
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
