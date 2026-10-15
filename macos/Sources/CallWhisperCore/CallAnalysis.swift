import Foundation

/// Analiza rozmowy po fakcie: podsumowanie, zadania, decyzje i pytania na
/// kolejną rozmowę. Zamiast podpowiadania w trakcie — na żądanie, gdy
/// transkrypt jest już kompletny.
public enum CallAnalysis {
    public static let sectionTitles = ["Podsumowanie", "Zadania", "Decyzje", "Pytania na kolejną rozmowę"]

    /// Ile transkryptu oddajemy modelowi. Claude Code ma duży kontekst, ale
    /// kilkugodzinne nagranie i tak warto przyciąć — od końca, bo tam zwykle
    /// padają ustalenia.
    public static let maxTranscriptChars = 150_000

    public static func prompt(transcript: String, title: String = "") -> String {
        let body = transcript.count > maxTranscriptChars
            ? "[…początek pominięty…]\n" + String(transcript.suffix(maxTranscriptChars))
            : transcript
        return """
        Poniżej transkrypt rozmowy\(title.isEmpty ? "" : " „\(title)”") z oznaczeniem osób i znacznikami czasu [HH:MM:SS].
        Przeanalizuj go i odpowiedz w Markdownie, w języku transkryptu, dokładnie w tych sekcjach:

        ## Podsumowanie
        3-5 zdań: o czym była rozmowa i z czym się skończyła.

        ## Zadania
        Lista `- [ ] zadanie — kto (jeśli wiadomo) — termin (jeśli padł) [HH:MM:SS]`.
        Tylko to, co ktoś faktycznie ma zrobić. Brak zadań: „- brak”.

        ## Decyzje
        Lista ustaleń z [HH:MM:SS]. Brak: „- brak”.

        ## Pytania na kolejną rozmowę
        Lista otwartych kwestii, niejasności i rzeczy do dopytania następnym razem,
        każda z krótkim uzasadnieniem, skąd się wzięła.

        Bez wstępu i zakończenia, nie wymyślaj niczego spoza transkryptu.

        \(body)
        """
    }

    /// Podział odpowiedzi na sekcje `## Tytuł` (do wyświetlenia). Tekst przed
    /// pierwszym nagłówkiem trafia do sekcji bez tytułu.
    public static func sections(_ markdown: String) -> [(title: String, body: String)] {
        var out: [(title: String, body: String)] = []
        var title = ""
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty || !title.isEmpty { out.append((title, body)) }
            lines = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                flush()
                title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    /// Analiza wstawiona do pliku Markdown transkryptu: pod nagłówkiem
    /// dokumentu, przed tabelą osób (jak podsumowanie w „Kopiuj dla Claude").
    public static func insert(_ analysis: String, into transcript: String) -> String {
        let block = "\n## Analiza\n\n" + analysis
            .replacingOccurrences(of: "\n## ", with: "\n### ")
            .replacingOccurrences(of: "## ", with: "### ", options: .anchored)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let range = transcript.range(of: "\n## ") else { return transcript + "\n" + block }
        var out = transcript
        out.insert(contentsOf: block, at: range.lowerBound)
        return out
    }
}
