import Foundation
import CallWhisperCore

/// Transkrypcja pliku modelem Parakeet przez `sherpa-onnx-offline` (jak
/// `parakeetServer.js` w whistlerze, tylko bez serwera WebSocket — przy
/// pliku nie ma po co go trzymać).
///
/// Zmierzone 2026-10-15 na M-serii: RTF 0,03, czyli godzina nagrania w ~2 min.
public enum Parakeet {
    public enum ParakeetError: LocalizedError {
        case notInstalled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Brak silnika albo modelu Parakeet. Pobierz go w Ustawieniach → Modele."
            case .failed(let detail): return "Parakeet nie zadziałał: \(detail)"
            }
        }
    }

    /// Kawałki po ~25 s: Parakeet trzyma całe wejście w pamięci, a ~30 s to
    /// długość, na której był uczony.
    static let chunkSeconds = 25
    /// Tyle kawałków na jedno uruchomienie: model wczytuje się raz na partię,
    /// a pasek postępu i tak żyje.
    static let batch = 16

    public static func transcribe(_ pcm: [Float], model: SpeechModel,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        guard let binary = Engines.parakeetEngine, ModelDownloader.isInstalled(model.id) else {
            throw ParakeetError.notInstalled
        }
        let dir = ModelDownloader.location(model)
        let rate = Int(asrSampleRate)
        let bounds = MediaImport.chunkBounds(count: pcm.count, target: chunkSeconds * rate,
                                             window: 5 * rate, samples: pcm)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cw-parakeet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var texts: [TimedText] = []
        var first = 0
        while first < bounds.count {
            try Task.checkCancellation()
            let part = Array(bounds[first..<min(bounds.count, first + batch)])
            var files: [String] = []
            for (i, range) in part.enumerated() {
                let url = work.appendingPathComponent("chunk-\(first + i).wav")
                try Wav.encode(Array(pcm[range])).write(to: url)
                files.append(url.path)
            }
            let output = try await run(binary, [
                "--tokens=\(dir.appendingPathComponent("tokens.txt").path)",
                "--encoder=\(dir.appendingPathComponent("encoder.int8.onnx").path)",
                "--decoder=\(dir.appendingPathComponent("decoder.int8.onnx").path)",
                "--joiner=\(dir.appendingPathComponent("joiner.int8.onnx").path)",
                "--model-type=nemo_transducer",
                "--num-threads=\(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))",
            ] + files)
            let results = ParakeetOutput.parse(output)
            guard results.count == part.count else {
                throw ParakeetError.failed("oczekiwano \(part.count) wyników, jest \(results.count)")
            }
            for (range, sentences) in zip(part, results) {
                let offset = Double(range.lowerBound) / asrSampleRate
                texts += sentences.map { TimedText(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            }
            first += part.count
            progress(Double(first) / Double(bounds.count))
        }
        return texts
    }

    /// Wynik leci na stderr razem z konfiguracją — oba strumienie do plików,
    /// bo nieczytany potok blokuje proces po 64 kB (patrz `NeuralDiarizer`).
    static func run(_ binary: URL, _ arguments: [String]) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("cw-parakeet-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("cw-parakeet-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let task = Process()
        task.executableURL = binary
        task.arguments = arguments
        task.standardOutput = try FileHandle(forWritingTo: outURL)
        task.standardError = try FileHandle(forWritingTo: errURL)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try task.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            task.terminate()
        }
        try Task.checkCancellation()
        let output = ((try? String(contentsOf: outURL, encoding: .utf8)) ?? "") + "\n"
            + ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
        guard status == 0 else { throw ParakeetError.failed(String(output.suffix(300))) }
        return output
    }
}
