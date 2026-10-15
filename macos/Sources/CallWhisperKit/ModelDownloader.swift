import Foundation

/// Darmowy model mowy do pobrania: whisper.cpp (ggml) albo Parakeet
/// (NeMo przez sherpa-onnx). Lista jak w whistlerze (`modelRegistryData.json`).
public struct SpeechModel: Sendable, Identifiable, Hashable {
    public enum Family: String, Sendable { case whisper, parakeet }

    public var id: String
    public var family: Family
    public var name: String
    public var bytes: Int64
    /// Pobieramy duże pliki z cudzych serwerów — suma przypięta jak w `Engines`.
    public var sha256: String
    public var note: String
    var url: String
    /// Parakeet: katalog w archiwum `.tar.bz2`.
    var archiveDir: String?
}

/// Pobieranie modeli mowy.
///
/// Bez tego pierwszym krokiem użytkownika jest ręczne `curl` po 465 MB do
/// katalogu, o którym nie ma skąd wiedzieć. To jest dokładnie ten rodzaj
/// kroku, po którym aplikacja „nie działa".
public actor ModelDownloader {
    public struct Progress: Sendable {
        public var fraction: Double
        public var receivedBytes: Int64
        public var totalBytes: Int64
    }

    public enum DownloadError: LocalizedError {
        case unknownModel(String)
        case http(Int)
        case checksum(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let name): return "Nie znam modelu \(name)."
            case .http(let status): return "Pobieranie zwróciło \(status)."
            case .checksum(let name): return "Suma kontrolna \(name) się nie zgadza — plik odrzucony."
            }
        }
    }

    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let sherpaBase = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

    private static func whisper(_ id: String, _ bytes: Int64, _ sha: String, _ name: String, _ note: String) -> SpeechModel {
        SpeechModel(id: id, family: .whisper, name: name, bytes: bytes, sha256: sha, note: note,
                    url: "\(whisperBase)/ggml-\(id).bin")
    }

    private static func parakeet(_ id: String, _ dir: String, _ bytes: Int64, _ sha: String,
                                 _ name: String, _ note: String) -> SpeechModel {
        SpeechModel(id: id, family: .parakeet, name: name, bytes: bytes, sha256: sha, note: note,
                    url: "\(sherpaBase)/\(dir).tar.bz2", archiveDir: dir)
    }

    /// Rozmiary i sumy z repozytoriów (HF `x-linked-etag`, GitHub `digest`).
    public static let catalog: [SpeechModel] = [
        whisper("tiny", 77_691_713, "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
                "Whisper Tiny", "najszybszy, po polsku słaby"),
        whisper("base", 147_951_465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
                "Whisper Base", "mały, wyraźnie gorszy po polsku"),
        whisper("small", 487_601_967, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
                "Whisper Small", "domyślny, 13,3 % błędnych słów po polsku, ~930 ms"),
        whisper("medium", 1_533_763_059, "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
                "Whisper Medium", "dokładniejszy od small, wolniejszy"),
        whisper("large-v3-turbo", 1_624_555_275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
                "Whisper Turbo", "dokładniejszy: 10,0 %, ale ~1,6 s i 1,6 GB pamięci"),
        whisper("large-v3", 3_095_033_483, "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
                "Whisper Large v3", "najdokładniejszy i najwolniejszy — raczej do importu plików"),
        parakeet("parakeet-tdt-0.6b-v3", "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", 487_170_055,
                 "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
                 "Parakeet TDT 0.6B v3", "25 języków z polskim, bardzo szybki, bez podpowiedzi słownictwa"),
        parakeet("parakeet-unified-en-0.6b", "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming", 501_350_460,
                 "99f63605b3a85a54c250c0869670a687b7d6598a47bf2421515e1f839a76e150",
                 "Parakeet Unified EN 0.6B", "tylko angielski, bardzo dokładny"),
    ]

    public static func model(_ id: String) -> SpeechModel? { catalog.first { $0.id == id } }

    /// Katalog modeli Parakeet: encoder/decoder/joiner + tokens.
    public static var parakeetDirectory: URL { Engines.supportDirectory.appendingPathComponent("parakeet") }

    static let parakeetFiles = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]

    public static func location(_ model: SpeechModel) -> URL {
        switch model.family {
        case .whisper: return WhisperServer.modelURL(model.id)
        case .parakeet: return parakeetDirectory.appendingPathComponent(model.id)
        }
    }

    /// Modele whispera spoza katalogu (wgrane ręcznie) też się liczą.
    public static func isInstalled(_ id: String) -> Bool {
        guard let model = model(id), model.family == .parakeet else {
            return FileManager.default.isReadableFile(atPath: WhisperServer.modelURL(id).path)
        }
        let dir = location(model)
        return parakeetFiles.allSatisfy { FileManager.default.isReadableFile(atPath: dir.appendingPathComponent($0).path) }
    }

    public static func delete(_ id: String) throws {
        let url = model(id).map(location) ?? WhisperServer.modelURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public init() {}

    /// Pobiera model, jeśli go nie ma. Anulowanie zadania przerywa pobieranie.
    ///
    /// Zadanie pobierania, a nie `URLSession.bytes`: ten drugi oddaje strumień
    /// bajt po bajcie i na 148 MB spalał 12 s czasu procesora na samą pętlę.
    public func download(_ id: String,
                         onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        guard let model = Self.model(id) else { throw DownloadError.unknownModel(id) }
        if Self.isInstalled(id) { return }

        let reporter = ProgressReporter(expected: model.bytes, onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: model.url)!, delegate: reporter)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.http(http.statusCode)
        }
        try Task.checkCancellation()
        guard try Engines.sha256(of: temporary) == model.sha256 else { throw DownloadError.checksum(model.name) }

        let target = Self.location(model)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)

        switch model.family {
        case .whisper:
            try FileManager.default.moveItem(at: temporary, to: target)
        case .parakeet:
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("cw-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try Engines.run("/usr/bin/tar", ["-xjf", temporary.path, "-C", work.path])
            let extracted = work.appendingPathComponent(model.archiveDir ?? "")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            // Tylko to, czego potrzebuje sherpa — bez przykładowych nagrań i opisów.
            for file in Self.parakeetFiles {
                try FileManager.default.moveItem(at: extracted.appendingPathComponent(file),
                                                 to: target.appendingPathComponent(file))
            }
        }
        onProgress(Progress(fraction: 1, receivedBytes: model.bytes, totalBytes: model.bytes))
    }
}

/// Postęp pobierania. Osobna klasa, bo `URLSession` chce delegata.
final class ProgressReporter: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let onProgress: @Sendable (ModelDownloader.Progress) -> Void
    private var lastReport = Date.distantPast

    init(expected: Int64, onProgress: @escaping @Sendable (ModelDownloader.Progress) -> Void) {
        self.expected = expected
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Co 200 ms wystarczy — pasek postępu nie potrzebuje więcej, a każde
        // odświeżenie przechodzi na główny wątek.
        guard Date().timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = Date()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        onProgress(ModelDownloader.Progress(
            fraction: total > 0 ? Double(totalBytesWritten) / Double(total) : 0,
            receivedBytes: totalBytesWritten,
            totalBytes: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Plik odbiera `download(from:)`; tutaj nic nie robimy.
    }
}
