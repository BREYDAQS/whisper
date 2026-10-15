import Foundation

/// Stan pobierania modeli dla interfejsu: Ustawienia i import patrzą na te
/// same paski postępu, więc pobieranie zaczęte w jednym miejscu widać w drugim.
@MainActor
public final class ModelStore: ObservableObject {
    public static let shared = ModelStore()

    /// Rozpoznawanie głosów jako jedna pozycja: silnik + dwa modele.
    public static let diarizationID = "diarization"

    /// Postęp 0…1 trwających pobrań.
    @Published public private(set) var progress: [String: Double] = [:]
    @Published public private(set) var errors: [String: String] = [:]
    /// Podbijane po instalacji i usunięciu — stan dysku nie jest obserwowalny.
    @Published public private(set) var revision = 0

    private var tasks: [String: Task<Void, Never>] = [:]
    private let downloader = ModelDownloader()

    public init() {}

    public func isInstalled(_ id: String) -> Bool {
        _ = revision
        return id == Self.diarizationID ? Engines.canDiarize : ModelDownloader.isInstalled(id)
    }

    public var installedSpeechModels: [SpeechModel] {
        ModelDownloader.catalog.filter { isInstalled($0.id) }
    }

    public static var diarizationBytes: Int64 {
        Engines.downloadBytes(.diarizer) + Engines.downloadBytes(.diarizationModels)
    }

    public func download(_ id: String) {
        guard tasks[id] == nil else { return }
        errors[id] = nil
        progress[id] = 0
        tasks[id] = Task { [weak self] in
            do {
                if id == Self.diarizationID {
                    try await NeuralDiarizer.ensureInstalled { _ in }
                } else {
                    // Parakeet bez silnika sherpa nic nie zrobi — dociągamy go razem z modelem.
                    if ModelDownloader.model(id)?.family == .parakeet, !Engines.isInstalled(.parakeetEngine) {
                        try await Engines.install(.parakeetEngine)
                    }
                    try await self?.downloader.download(id) { p in
                        Task { @MainActor in self?.progress[id] = p.fraction }
                    }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.errors[id] = error.localizedDescription
            }
            self?.tasks[id] = nil
            self?.progress[id] = nil
            self?.revision += 1
        }
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    public func delete(_ id: String) {
        do {
            if id == Self.diarizationID {
                try Engines.uninstall(.diarizer)
                try Engines.uninstall(.diarizationModels)
            } else {
                try ModelDownloader.delete(id)
            }
            errors[id] = nil
        } catch {
            errors[id] = error.localizedDescription
        }
        revision += 1
    }
}
