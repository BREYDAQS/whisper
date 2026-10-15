import Foundation

/// Wyjście `sherpa-onnx-offline` z modelem Parakeet (NeMo TDT).
///
/// Na każdy plik wejściowy sherpa wypisuje na stderr linię ze ścieżką, linię
/// JSON i `----`. W JSON-ie są tokeny z czasem startu, ale bez podziału na
/// zdania — whisper oddaje segmenty, Parakeet jeden blok na plik. Tniemy więc
/// sami na końcach zdań: diaryzacja przypisuje mówcę per fragment, a jeden
/// 25-sekundowy blok to zwykle dwie osoby.
public enum ParakeetOutput {
    struct Result: Decodable {
        var text: String
        var timestamps: [Double]
        var durations: [Double]?
        var tokens: [String]
    }

    /// Wyniki w kolejności plików na wejściu. Wszystko poza liniami JSON
    /// (konfiguracja, ścieżki, czas działania) jest pomijane.
    public static func parse(_ output: String) -> [[TimedText]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("{"), line.contains("\"text\""),
                  let result = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) else { return nil }
            return sentences(result)
        }
    }

    static func sentences(_ result: Result) -> [TimedText] {
        guard result.tokens.count == result.timestamps.count, !result.tokens.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [TimedText(start: 0, end: 0, text: text)]
        }
        var out: [TimedText] = []
        var text = ""
        var start: Double?
        for (i, token) in result.tokens.enumerated() {
            if start == nil { start = result.timestamps[i] }
            text += token
            let isLast = i == result.tokens.count - 1
            guard isLast || token.hasSuffix(".") || token.hasSuffix("?") || token.hasSuffix("!") else { continue }
            let end = result.timestamps[i] + (result.durations?[safe: i] ?? 0)
            let sentence = text.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { out.append(TimedText(start: start ?? 0, end: end, text: sentence)) }
            text = ""
            start = nil
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
