import Foundation
import CSherpa

/// Parakeet na żywo w procesie aplikacji, przez C API sherpa-onnx.
///
/// Wcześniej był tu `sherpa-onnx-offline-websocket-server`, ale on nasłuchuje
/// na wszystkich interfejsach (`*:port`) i nie ma opcji `--host` — każdy
/// w tej samej sieci mógł do niego wysyłać dźwięk. Model w procesie nie
/// otwiera żadnego portu, a i tak zostaje w pamięci między rundami
/// (uruchamianie `sherpa-onnx-offline` na rundę płaciłoby ~2 s za wczytanie).
public actor ParakeetRecognizer {
    public enum RecognizerError: LocalizedError {
        case notInstalled
        case load(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Brak silnika albo modelu Parakeet. Pobierz go w Ustawieniach → Modele."
            case .load(let detail): return "Nie udało się wczytać Parakeet: \(detail)"
            }
        }
    }

    private var handle: UnsafeMutableRawPointer?
    private var modelID: String?

    public init() {}

    /// Wczytuje model (~1,5 s), jeśli nie jest już wczytany.
    public func load(model: SpeechModel) throws {
        if handle != nil, modelID == model.id { return }
        unload()
        guard let library = Engines.parakeetLibrary, ModelDownloader.isInstalled(model.id) else {
            throw RecognizerError.notInstalled
        }
        var error = [CChar](repeating: 0, count: 512)
        guard cw_sherpa_load(library.path, &error, Int32(error.count)) == 0 else {
            throw RecognizerError.load(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        let dir = ModelDownloader.location(model)
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
        guard let created = cw_parakeet_create(path("encoder.int8.onnx"), path("decoder.int8.onnx"),
                                               path("joiner.int8.onnx"), path("tokens.txt"), 4) else {
            throw RecognizerError.load("model \(model.name) odrzucony przez sherpa-onnx")
        }
        handle = created
        modelID = model.id
    }

    public func transcribe(_ pcm: [Float]) throws -> String {
        guard let handle else { throw RecognizerError.notInstalled }
        guard let raw = pcm.withUnsafeBufferPointer({ cw_parakeet_decode(handle, $0.baseAddress, Int32($0.count)) }) else {
            return ""
        }
        defer { free(raw) }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zwalnia model (~700 MB) po nasłuchu.
    public func unload() {
        if let handle { cw_parakeet_destroy(handle) }
        handle = nil
        modelID = nil
    }
}
