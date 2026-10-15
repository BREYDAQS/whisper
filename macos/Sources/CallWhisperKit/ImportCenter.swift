import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CallWhisperCore

/// Pozycja biblioteki importów — odpowiednik notatki „video-transcript"
/// z whistlera.
public struct ImportItem: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, done, failed }

    /// Zrzut klatki wideo przypięty do chwili w nagraniu (`addShotToNote`).
    public struct Frame: Codable, Identifiable, Sendable, Equatable {
        public var id: String
        public var seconds: Double
        public var path: String
    }

    public var id: String
    public var title: String
    /// Kopia w bibliotece (po skopiowaniu) albo jeszcze oryginał.
    public var mediaPath: String
    public var originalPath: String
    public var createdAt: Date
    public var status: Status
    public var error: String?
    /// Ile razy import ruszył — przerwany przez zamknięcie aplikacji wraca
    /// przy starcie, ale nie w nieskończoność.
    public var attempts: Int
    public var model: String
    public var language: String
    public var diarize: Bool
    public var speakers: Int?
    public var duration: Double?
    public var segmentCount: Int
    public var speakerCount: Int
    /// Dlaczego nie było podziału na głosy, choć był zamówiony.
    public var note: String?
    public var frames: [Frame]

    public var isVideo: Bool {
        MediaImport.videoExtensions.contains(URL(fileURLWithPath: mediaPath).pathExtension.lowercased())
    }
}

/// Import nagrań i wideo z biblioteką — moduł `videoImportManager` +
/// `VideoLibraryView` z whistlera.
///
/// Jak w whistlerze: plik jest kopiowany do `~/Movies/call-whisper`, żeby
/// transkrypt i odtwarzacz działały po przeniesieniu oryginału, a import
/// przerwany zamknięciem aplikacji rusza ponownie przy starcie (najwyżej
/// dwa podejścia). Importy idą po kolei, w tle, na osobnym `whisper-server`
/// (port nasłuchu + 1) — nie przeszkadzają rozmowie na żywo.
@MainActor
public final class ImportCenter: ObservableObject {
    @Published public private(set) var items: [ImportItem] = []
    @Published public private(set) var activeID: String?
    @Published public private(set) var progress: MediaImport.Progress?
    /// Prośba o pokazanie pozycji w oknie, np. po upuszczeniu pliku na Dock.
    @Published public var focusRequest: String?

    static let maxAttempts = 2

    private let settings: AppSettings
    private let server = WhisperServer()
    /// Model i język, z którymi działa nasz serwer — przy zmianie restart.
    private var serverKey: String?
    private var worker: Task<Void, Never>?
    private let downloader = ModelDownloader()

    public static var libraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/call-whisper")
    }
    static var dataDirectory: URL { Engines.supportDirectory.appendingPathComponent("imports") }
    static var indexURL: URL { dataDirectory.appendingPathComponent("index.json") }
    static func transcriptURL(_ id: String) -> URL { dataDirectory.appendingPathComponent("\(id).json") }

    public init(settings: AppSettings = .shared) {
        self.settings = settings
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([ImportItem].self, from: data) {
            items = saved
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(items).write(to: Self.indexURL, options: .atomic)
    }

    private func update(_ id: String, _ change: (inout ImportItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    public func item(_ id: String) -> ImportItem? { items.first { $0.id == id } }

    // MARK: - kolejka

    /// Dodaje plik do kolejki. Ustawienia (model, głosy) brane są z ustawień
    /// importu w chwili dodania, więc późniejsza zmiana nie przestawia kolejki.
    @discardableResult
    public func enqueue(_ url: URL) -> String {
        let speakers = settings.importSpeakers
        let item = ImportItem(
            id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent,
            mediaPath: url.path, originalPath: url.path, createdAt: Date(), status: .pending,
            attempts: 0, model: settings.importModel, language: settings.languageCode,
            diarize: settings.importDiarize, speakers: speakers > 0 ? speakers : nil,
            segmentCount: 0, speakerCount: 0, frames: [])
        items.insert(item, at: 0)
        save()
        focusRequest = item.id
        startWorker()
        return item.id
    }

    /// Wywoływane raz przy starcie: przerwane importy wracają do kolejki.
    public func resumePending() {
        for item in items where item.status == .pending && item.attempts >= Self.maxAttempts {
            update(item.id) {
                $0.status = .failed
                $0.error = "Import przerwany \(Self.maxAttempts) razy — spróbuj ponownie ręcznie."
            }
        }
        startWorker()
    }

    public func retry(_ id: String) {
        update(id) { $0.status = .pending; $0.error = nil; $0.attempts = 0 }
        startWorker()
    }

    public func cancel(_ id: String) {
        if activeID == id {
            worker?.cancel()
        } else {
            update(id) { $0.status = .failed; $0.error = "Przerwano" }
        }
    }

    /// Usuwa pozycję razem z kopią w bibliotece i klatkami. Oryginału spoza
    /// biblioteki nie ruszamy.
    public func delete(_ id: String) {
        guard let item = item(id), activeID != id else { return }
        let fm = FileManager.default
        if item.mediaPath.hasPrefix(Self.libraryDirectory.path + "/") { try? fm.removeItem(atPath: item.mediaPath) }
        for frame in item.frames { try? fm.removeItem(atPath: frame.path) }
        try? fm.removeItem(at: Self.transcriptURL(id))
        items.removeAll { $0.id == id }
        save()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // Najstarsza czekająca pozycja; `items` jest od najnowszej.
            while let self, let next = self.items.last(where: { $0.status == .pending }) {
                await self.process(next.id)
            }
            guard let self else { return }
            // Bez `await` między ostatnim sprawdzeniem kolejki a zwolnieniem
            // workera — inaczej plik dodany w trakcie gaszenia serwera utknąłby.
            self.worker = nil
            self.serverKey = nil
            await self.server.stop()
        }
    }

    private func report(_ message: String, _ fraction: Double) {
        progress = MediaImport.Progress(message: message, fraction: fraction)
    }

    private func process(_ id: String) async {
        guard var item = item(id) else { return }
        activeID = id
        defer { activeID = nil; progress = nil }
        update(id) { $0.attempts += 1 }

        do {
            item.mediaPath = try await copyToLibrary(item)
            update(id) { $0.mediaPath = item.mediaPath }

            let engine = try await prepareEngine(model: item.model, language: item.language)
            let options = MediaImport.Options(engine: engine, language: item.language,
                                              diarize: item.diarize, speakers: item.speakers)
            let result = try await MediaImport.run(URL(fileURLWithPath: item.mediaPath), options: options) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.activeID == id else { return }
                    self.progress = p
                }
            }
            var meta = result.meta
            meta.title = item.title
            let transcript = StoredTranscript(meta: meta, segments: result.segments)
            try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(transcript).write(to: Self.transcriptURL(id), options: .atomic)
            update(id) {
                $0.status = .done
                $0.error = nil
                $0.duration = (meta.endedAt ?? 0) / 1000 - (meta.startedAt ?? 0) / 1000
                $0.segmentCount = result.segments.count
                $0.speakerCount = result.speakerCount
                $0.note = result.diarizationNote
            }
        } catch is CancellationError {
            update(id) { $0.status = .failed; $0.error = "Przerwano" }
        } catch let error as URLError where error.code == .cancelled {
            update(id) { $0.status = .failed; $0.error = "Przerwano" }
        } catch {
            update(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
    }

    /// Kopia do `~/Movies/call-whisper` (whistler: `_copyToLibrary`).
    private func copyToLibrary(_ item: ImportItem) async throws -> String {
        let dir = Self.libraryDirectory
        if item.mediaPath.hasPrefix(dir.path + "/") { return item.mediaPath }
        report("Kopiuję do biblioteki…", 0)
        let source = URL(fileURLWithPath: item.mediaPath)
        return try await Task.detached {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            var target = dir.appendingPathComponent(source.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
                n += 1
            }
            try fm.copyItem(at: source, to: target)
            return target.path
        }.value
    }

    /// Pobiera brakujący model i silnik; dla whispera podnosi serwer importu.
    private func prepareEngine(model id: String, language: String) async throws -> MediaImport.Engine {
        guard let model = ModelDownloader.model(id) else {
            // Model whispera spoza katalogu, wgrany ręcznie.
            guard ModelDownloader.isInstalled(id) else { throw ModelDownloader.DownloadError.unknownModel(id) }
            return try await startWhisper(model: id, language: language)
        }
        if model.family == .parakeet && !Engines.isInstalled(.parakeetEngine) {
            try await Engines.install(.parakeetEngine) { [weak self] f in
                Task { @MainActor in self?.report("Pobieram silnik Parakeet — \(Int(f * 100))%", 0) }
            }
        }
        if !ModelDownloader.isInstalled(id) {
            try await downloader.download(id) { [weak self] p in
                Task { @MainActor in
                    self?.report(String(format: "Pobieram model %@ — %.0f%%", model.name, p.fraction * 100), 0)
                }
            }
            ModelStore.shared.objectWillChange.send()
        }
        switch model.family {
        case .parakeet: return .parakeet(model)
        case .whisper: return try await startWhisper(model: id, language: language)
        }
    }

    private func startWhisper(model: String, language: String) async throws -> MediaImport.Engine {
        if WhisperServer.locateBinary() == nil {
            report("Pobieram silnik mowy…", 0)
            try await Engines.install(.whisperServer)
        }
        let port = settings.whisperPort + 1
        let key = "\(model)|\(language)"
        if serverKey != key {
            await server.stop()
            report("Uruchamiam whisper-server (\(model))…", 0)
            try await server.ensureRunning(.init(model: model, port: port, language: language))
            serverKey = key
        }
        return .whisper(port: port)
    }

    // MARK: - transkrypt

    struct StoredTranscript: Codable {
        var meta: SessionMeta
        var segments: [Segment]
    }

    public func transcript(_ id: String) -> (meta: SessionMeta, segments: [Segment])? {
        guard let data = try? Data(contentsOf: Self.transcriptURL(id)),
              let stored = try? JSONDecoder().decode(StoredTranscript.self, from: data) else { return nil }
        return (stored.meta, stored.segments)
    }

    /// Markdown jak z rozmowy na żywo, z klatkami na końcu (ze znacznikami
    /// czasu, żeby dało się je dopasować do wypowiedzi).
    public func markdown(_ id: String) -> String? {
        guard let item = item(id), let transcript = transcript(id) else { return nil }
        var options = MarkdownOptions()
        options.locale = settings.markdownLocale
        options.absoluteTimestamps = settings.absoluteTimestamps
        var out = Markdown.render(Session(meta: transcript.meta, segments: transcript.segments), options: options)
        if !item.frames.isEmpty {
            out += "\n## Klatki\n\n"
            for frame in item.frames.sorted(by: { $0.seconds < $1.seconds }) {
                let stamp = TimeFormat.offset(frame.seconds * 1000)
                out += "**[\(stamp)]**\n\n![\(stamp)](\(URL(fileURLWithPath: frame.path).absoluteString))\n\n"
            }
        }
        return out
    }

    // MARK: - klatki

    /// Zrzut klatki wideo w danej chwili do `~/Movies/call-whisper/klatki`.
    public func addFrame(_ id: String, at seconds: Double) async throws {
        guard let item = item(id) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: item.mediaPath)))
        generator.appliesPreferredTrackTransform = true
        // Dokładnie ta klatka, którą widać w odtwarzaczu, a nie najbliższa kluczowa.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))

        let dir = Self.libraryDirectory.appendingPathComponent("klatki")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = TimeFormat.offset(actual.seconds * 1000).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(item.title)-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        update(id) {
            $0.frames.append(.init(id: UUID().uuidString, seconds: actual.seconds, path: url.path))
            $0.frames.sort { $0.seconds < $1.seconds }
        }
    }

    public func removeFrame(_ id: String, frame: String) {
        guard let path = item(id)?.frames.first(where: { $0.id == frame })?.path else { return }
        try? FileManager.default.removeItem(atPath: path)
        update(id) { $0.frames.removeAll { $0.id == frame } }
    }
}
