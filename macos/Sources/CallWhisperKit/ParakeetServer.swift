import Foundation

/// Parakeet na żywo: `sherpa-onnx-offline-websocket-server` trzyma model
/// w pamięci (jak `parakeetWsServer.js` w whistlerze). Uruchamianie
/// `sherpa-onnx-offline` na każdą rundę płaciłoby ~2 s za wczytanie 650 MB
/// enkodera — przy rundach co 1,2 s to nie wchodzi w grę.
public actor ParakeetServer {
    public enum ServerError: LocalizedError {
        case notInstalled
        case portBusy(Int)
        case didNotStart(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Brak silnika albo modelu Parakeet. Pobierz go w Ustawieniach → Modele."
            case .portBusy(let port): return "Port \(port) zajmuje inny program — Parakeet nie może wystartować."
            case .didNotStart(let detail): return "Serwer Parakeet nie wystartował: \(detail)"
            }
        }
    }

    private var process: Process?
    private var modelID: String?

    public init() {}

    /// Startuje serwer z modelem, jeśli nie działa już z tym samym.
    public func ensureRunning(model: SpeechModel, port: Int) async throws {
        if let process, process.isRunning, modelID == model.id { return }
        stop()
        if WhisperServer.reapOrphans() > 0 { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Self.isListening(port) else { throw ServerError.portBusy(port) }
        guard let binary = Engines.parakeetServer, ModelDownloader.isInstalled(model.id) else {
            throw ServerError.notInstalled
        }
        let dir = ModelDownloader.location(model)
        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "--port=\(port)",
            "--tokens=\(dir.appendingPathComponent("tokens.txt").path)",
            "--encoder=\(dir.appendingPathComponent("encoder.int8.onnx").path)",
            "--decoder=\(dir.appendingPathComponent("decoder.int8.onnx").path)",
            "--joiner=\(dir.appendingPathComponent("joiner.int8.onnx").path)",
            "--model-type=nemo_transducer",
            "--num-threads=4",
            // Dwa źródła (system + mikrofon) to najwyżej dwa żądania naraz.
            "--num-work-threads=2",
        ]
        // Log do pliku, nie do potoku — patrz `WhisperServer`.
        let logURL = WhisperServer.logDirectory.appendingPathComponent("parakeet-\(port).log")
        try? FileManager.default.createDirectory(at: WhisperServer.logDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            task.standardOutput = handle
            task.standardError = handle
        }
        do { try task.run() } catch { throw ServerError.didNotStart(error.localizedDescription) }
        process = task
        modelID = model.id
        WhisperServer.registerChild(task.processIdentifier)

        // Wczytanie modelu: zmierzone ~1,5 s; zapas na zimny dysk.
        for _ in 0..<120 {
            if Self.isListening(port) { return }
            if !task.isRunning {
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                stop()
                throw ServerError.didNotStart(String(output.suffix(200)))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw ServerError.didNotStart("brak odpowiedzi po 30 s")
    }

    public func stop() {
        if let process {
            WhisperServer.unregisterChild(process.processIdentifier)
            process.terminate()
        }
        process = nil
        modelID = nil
    }

    /// Czy ktoś słucha na porcie (zwykłe `connect`, bez wysyłania danych).
    static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// Jedno żądanie do serwera Parakeet: nagłówek (częstotliwość, liczba bajtów)
/// + próbki Float32, odpowiedź to JSON z polem `text`, potem „Done".
public struct ParakeetClient: Sendable {
    public var port: Int
    public var timeout: Double = 30

    public init(port: Int) { self.port = port }

    public func transcribe(_ pcm: [Float]) async throws -> String {
        var message = Data(capacity: 8 + pcm.count * 4)
        withUnsafeBytes(of: Int32(asrSampleRate).littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(pcm.count * 4).littleEndian) { message.append(contentsOf: $0) }
        pcm.withUnsafeBytes { message.append(contentsOf: $0) }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        // Duże wypowiedzi (25 s = 1,6 MB) przekraczają domyślny limit 1 MB.
        task.maximumMessageSize = 16 << 20
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // Zawieszony serwer nie może zatrzymać rundy na zawsze.
        let watchdog = Task { [timeout] in
            try await Task.sleep(for: .seconds(timeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let payload = message
        try await task.send(.data(payload))
        let reply = try await task.receive()
        try? await task.send(.string("Done"))

        guard case .string(let json) = reply,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let text = object["text"] as? String else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
