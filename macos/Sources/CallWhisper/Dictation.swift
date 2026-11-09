import SwiftUI
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import CallWhisperKit

/// Skrót dyktowania ustawiany w Ustawieniach.
///
/// Dwa rodzaje, bo system obsługuje je zupełnie inaczej:
///  - sam modyfikator (fn, ⌃⌥) — `keyCode == nil`, czytany z `flagsChanged`;
///  - modyfikator + klawisz (⌥Space, ⌘⇧D) albo klawisz F — rejestrowany
///    w Carbon (`RegisterEventHotKey`). System go połyka, więc ⌥Space nie
///    wpisze przy okazji spacji do pola, i nie wymaga zgody „Dostępność".
struct DictationHotkey: Codable, Equatable {
    var keyCode: UInt16?
    var modifiers: UInt
    var label: String

    static let fn = DictationHotkey(keyCode: nil, modifiers: NSEvent.ModifierFlags.function.rawValue, label: "fn")
    static let standard = DictationHotkey(keyCode: UInt16(kVK_ANSI_J), modifiers: NSEvent.ModifierFlags.command.rawValue,
                                          label: "⌘J")
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    static let comboMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isModifierOnly: Bool { keyCode == nil }

    static func load(_ json: String) -> DictationHotkey {
        guard let hotkey = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return .standard }
        return hotkey
    }

    var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.function) { out += "fn" }
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    static let fKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    static func keyName(_ code: UInt16, characters: String?) -> String {
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
                                         123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = special[code] ?? fKeys[code] { return name }
        return characters?.uppercased() ?? "#\(code)"
    }

    /// Modyfikatory w formacie Carbon.
    var carbonModifiers: UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }
}

/// Dyktowanie do dowolnego pola tekstowego, port z whistlera (OpenWhispr):
/// skrót → mikrofon → whisper-server → schowek + ⌘V → stary schowek wraca.
///
/// Tryby jak tam: `push` — trzymasz skrót i mówisz; `toggle` — naciśnięcie
/// zaczyna, kolejne kończy.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording, transcribing, pasted, error(String) }
    enum ServerState: Equatable { case off, starting, ready, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var hotkey: DictationHotkey
    /// Skrót wciśnięty teraz — lampka w Ustawieniach.
    @Published private(set) var hotkeyHeld = false
    @Published private(set) var hotkeyError: String?
    /// Ustawienia nagrywają nowy skrót: obecny nie działa, żeby nie zaczął dyktowania.
    @Published private(set) var capturing = false
    @Published private(set) var captureHint: String?
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    /// Serwer dyktowania. Rozgrzewany od razu po włączeniu — zimny start
    /// (model + shadery Metal) to ~7 s, których nie może zjeść pierwsze dyktowanie.
    @Published private(set) var serverState: ServerState = .off

    private let settings = AppSettings.shared
    private let whisper = WhisperServer()
    private let pill = DictationPill()
    private let output = OutputMute()
    private var mic: MicrophoneCapture?
    private let buffer = SampleBuffer()

    private var running = false
    private var monitors: [Any] = []
    private var globalMonitors: [Any] = []
    private var captureMonitor: Any?
    private var capturePeak: NSEvent.ModifierFlags = []
    private var captureSawKey = false
    private var trustPoll: Timer?
    private var carbonHandler: EventHandlerRef?
    private var carbonHotKey: EventHotKeyRef?

    private var modHeld = false
    private var comboDown = false
    /// Przy skrócie z samych modyfikatorów: w trakcie wciśnięto inny klawisz,
    /// więc to był zwykły skrót klawiszowy (⌥+a = „ą"), a nie dyktowanie.
    private var chord = false
    private var pressedAt = Date.distantPast
    private var pressID = 0
    private var holdStarted = false
    /// Start nagrania — żeby odróżnić muśnięcie skrótu od pustego mikrofonu.
    private var recordingStarted: Date?
    private var lastStop: Date = .distantPast

    private static let minHoldMs = 150
    /// Dłużej trzymany modyfikator w trybie `toggle` to nie tapnięcie.
    private static let maxTap: TimeInterval = 0.6
    private static let postStopCooldown: TimeInterval = 0.3
    /// Krótsze nagranie to przypadkowe dotknięcie — whisper zmyśliłby zdanie.
    private static let minSamples = Int(asrSampleRate * 0.4)
    /// Tyle czekamy, zanim przywrócimy schowek (jak whistler na macOS).
    private static let restoreDelay: TimeInterval = 2

    init() {
        hotkey = DictationHotkey.load(AppSettings.shared.dictationHotkey)
    }

    // MARK: - cykl życia

    func start() {
        guard !running else { return }
        running = true
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        } as Any)
        if AXIsProcessTrusted() {
            installGlobalMonitors()
        } else {
            requestTrust()
        }
        registerCombo()
        prewarm()
    }

    func stop() {
        guard running else { return }
        running = false
        (monitors + globalMonitors).forEach(NSEvent.removeMonitor)
        monitors = []
        globalMonitors = []
        trustPoll?.invalidate()
        trustPoll = nil
        unregisterCombo()
        resetHold()
        if state == .recording { cancelRecording() }
        output.restore()
        // Model dyktowania to 1,6 GB pamięci — wyłączone dyktowanie ją oddaje.
        serverState = .off
        Task { await whisper.stop() }
    }

    private func showPill() {
        pill.show(state, hotkey: hotkey.label, muted: settings.dictationMuteSystem) { [weak self] in
            self?.toggleMute()
        }
    }

    /// Ikona głośnika w pigułce: przełącza opcję i od razu działa w trwającym nagraniu.
    func toggleMute() {
        settings.dictationMuteSystem.toggle()
        if state == .recording {
            settings.dictationMuteSystem ? output.mute() : output.restore()
        }
        if state != .idle { showPill() }
    }

    /// Wyjście z aplikacji w trakcie dyktowania nie może zostawić wyciszonego systemu.
    func restoreOutput() { output.restore() }

    // MARK: - serwer

    /// Ten sam model co w rozmowie = ten sam serwer; inny = osobny port.
    private var port: Int {
        settings.dictationModel == settings.whisperModel ? settings.whisperPort : settings.whisperPort + 1
    }

    private var client: WhisperClient {
        WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(port)")!, language: settings.languageCode)
    }

    func prewarm() {
        guard serverState != .starting else { return }
        serverState = .starting
        Task {
            do {
                try await ensureServer()
                // Pierwsze zapytanie po starcie przygotowuje Metal — niech to
                // będzie sekunda ciszy teraz, a nie pierwsze prawdziwe dyktowanie.
                _ = try? await client.transcribe([Float](repeating: 0, count: Int(asrSampleRate)))
                serverState = .ready
            } catch {
                serverState = .failed(error.localizedDescription)
            }
        }
    }

    /// Po zmianie modelu stary serwer trzeba zgasić, inaczej odpowiadałby dalej starym.
    func modelChanged() {
        serverState = .off
        Task {
            await whisper.stop()
            if running { prewarm() }
        }
    }

    private func ensureServer() async throws {
        if await client.health() { return }
        try await whisper.ensureRunning(.init(model: settings.dictationModel, port: port,
                                              language: settings.languageCode))
    }

    /// Systemowe okno z prośbą o „Dostępność" i czekanie, aż zgoda przyjdzie.
    func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            installGlobalMonitors()
            return
        }
        guard trustPoll == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPoll = timer
    }

    private func checkTrust() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        trustPoll?.invalidate()
        trustPoll = nil
        installGlobalMonitors()
    }

    /// Nasłuch klawiszy w innych aplikacjach — wymaga „Dostępności".
    private func installGlobalMonitors() {
        trusted = true
        guard running, globalMonitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            self?.handle(event)
        }) {
            globalMonitors.append(monitor)
        }
    }

    // MARK: - skrót

    func setHotkey(_ new: DictationHotkey) {
        unregisterCombo()
        resetHold()
        hotkey = new
        settings.dictationHotkey = new.json
        if running && !capturing { registerCombo() }
    }

    private func resetHold() {
        modHeld = false
        comboDown = false
        hotkeyHeld = false
        holdStarted = false
        pressID += 1
    }

    private func registerCombo() {
        hotkeyError = nil
        guard running, !capturing, let code = hotkey.keyCode, carbonHotKey == nil else { return }
        if carbonHandler == nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let controller = Unmanaged<DictationController>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { pressed ? controller.comboPressed() : controller.comboReleased() }
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &carbonHandler)
        }
        let id = EventHotKeyID(signature: OSType(0x4357_4454), id: 1) // „CWDT"
        let status = RegisterEventHotKey(UInt32(code), hotkey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &carbonHotKey)
        if status != noErr {
            carbonHotKey = nil
            hotkeyError = "Skrót \(hotkey.label) jest zajęty przez system albo inną aplikację. Wybierz inny."
        }
    }

    private func unregisterCombo() {
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey) }
        carbonHotKey = nil
    }

    private func handle(_ event: NSEvent) {
        guard !capturing, hotkey.isModifierOnly else { return }
        switch event.type {
        case .flagsChanged:
            let active = event.modifierFlags.intersection(DictationHotkey.modifierMask) == hotkey.flags
            guard active != modHeld else { return }
            modHeld = active
            active ? modifierPressed() : modifierReleased()
        case .keyDown where modHeld:
            chord = true
            pressID += 1
            // Trwające nagranie z przytrzymania kończymy bez wklejania.
            if holdStarted {
                holdStarted = false
                cancelRecording()
            }
        default:
            break
        }
    }

    private func modifierPressed() {
        DictationLog.write("skrót wciśnięty (\(hotkey.label))")
        hotkeyHeld = true
        chord = false
        pressedAt = Date()
        guard settings.dictationMode != "toggle" else { return }
        guard Date().timeIntervalSince(lastStop) > Self.postStopCooldown else { return }
        pressID += 1
        let id = pressID
        holdStarted = false
        Task {
            try? await Task.sleep(for: .milliseconds(Self.minHoldMs))
            guard id == pressID, modHeld, !chord, !holdStarted else { return }
            holdStarted = true
            begin()
        }
    }

    private func modifierReleased() {
        hotkeyHeld = false
        if settings.dictationMode == "toggle" {
            if !chord, Date().timeIntervalSince(pressedAt) < Self.maxTap { toggle() }
            return
        }
        pressID += 1
        lastStop = Date()
        if holdStarted {
            holdStarted = false
            finish()
        }
    }

    fileprivate func comboPressed() {
        DictationLog.write("skrót wciśnięty (\(hotkey.label))")
        guard !capturing, !comboDown else { return }
        comboDown = true
        hotkeyHeld = true
        settings.dictationMode == "toggle" ? toggle() : begin()
    }

    fileprivate func comboReleased() {
        guard comboDown else { return }
        comboDown = false
        hotkeyHeld = false
        if settings.dictationMode != "toggle" { finish() }
    }

    private func toggle() {
        state == .recording ? finish() : begin()
    }

    // MARK: - nagrywanie skrótu w Ustawieniach

    func beginCapture() {
        guard !capturing else { return }
        capturing = true
        captureHint = nil
        capturePeak = []
        captureSawKey = false
        unregisterCombo()
        resetHold()
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.capture(event) ? nil : event
        }
    }

    func cancelCapture() { endCapture(nil) }

    /// `true` = zdarzenie połknięte.
    private func capture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            let mods = event.modifierFlags.intersection(DictationHotkey.comboMask)
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                endCapture(nil)
                return true
            }
            captureSawKey = true
            guard !mods.isEmpty || DictationHotkey.fKeys[event.keyCode] != nil else {
                captureHint = "Dodaj modyfikator (⌃ ⌥ ⇧ ⌘) albo użyj klawisza F."
                return true
            }
            let name = DictationHotkey.keyName(event.keyCode, characters: event.charactersIgnoringModifiers)
            endCapture(DictationHotkey(keyCode: event.keyCode, modifiers: mods.rawValue,
                                       label: DictationHotkey.symbols(mods) + name))
            return true
        case .flagsChanged:
            let current = event.modifierFlags.intersection(DictationHotkey.modifierMask)
            if current.isEmpty {
                // Wszystko puszczone bez klawisza po drodze = skrót z samych modyfikatorów.
                if !capturePeak.isEmpty && !captureSawKey {
                    endCapture(DictationHotkey(keyCode: nil, modifiers: capturePeak.rawValue,
                                               label: DictationHotkey.symbols(capturePeak)))
                }
                capturePeak = []
                captureSawKey = false
            } else {
                capturePeak.formUnion(current)
            }
            return false
        default:
            return false
        }
    }

    private func endCapture(_ new: DictationHotkey?) {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        captureHint = nil
        capturing = false
        if let new { setHotkey(new) } else { registerCombo() }
    }

    // MARK: - test

    /// 3 s z mikrofonu → tekst w Ustawieniach, bez wklejania. Sprawdza naraz
    /// zgodę na mikrofon, czy cokolwiek słychać, silnik i model.
    func runTest() {
        guard !testing, state == .idle else { return }
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            guard await MicrophoneCapture.requestAccess() else {
                testResult = "✗ Brak zgody na mikrofon."
                return
            }
            let capture = MicrophoneCapture()
            let buffer = SampleBuffer()
            do {
                try capture.start(deviceID: settings.micDeviceID) { chunk in buffer.append(chunk.samples) }
            } catch {
                testResult = "✗ Mikrofon: \(error.localizedDescription)"
                return
            }
            if settings.dictationMuteSystem { output.mute() }
            try? await Task.sleep(for: .seconds(3))
            capture.stop()
            output.restore()
            let pcm = buffer.take()
            let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
            guard pcm.count >= Self.minSamples, peak > 0.01 else {
                testResult = "✗ Mikrofon nic nie słyszy. Sprawdź wejście w Ustawieniach → Ogólne."
                return
            }
            do {
                let text = try await transcribe(pcm)
                testResult = text.isEmpty ? "✓ Mikrofon słyszy, ale nic nie rozpoznano. Powiedz coś dłuższego."
                                          : "✓ \(text)"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
        }
    }

    // MARK: - nagranie

    private func begin() {
        guard state != .recording, state != .transcribing, !testing else { return }
        buffer.reset()
        state = .recording
        recordingStarted = Date()
        DictationLog.write("start: aplikacja \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), mikrofon \(settings.micDeviceID.isEmpty ? "domyślny" : settings.micDeviceID), tryb \(settings.dictationMode)")
        if settings.dictationMuteSystem { output.mute() }
        showPill()
        Task {
            guard await MicrophoneCapture.requestAccess() else {
                fail("Brak zgody na mikrofon")
                return
            }
            // Skrót puszczony, zanim przyszła zgoda.
            guard state == .recording else { return }
            let capture = MicrophoneCapture()
            let buffer = self.buffer
            do {
                try capture.start(deviceID: settings.micDeviceID) { chunk in
                    buffer.append(chunk.samples)
                }
                DictationLog.write("mikrofon: działa")
                // Skrót puszczony w trakcie startu mikrofonu — sprzątamy.
                if state == .recording { mic = capture } else { capture.stop() }
            } catch {
                DictationLog.write("mikrofon: błąd \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        mic?.stop()
        mic = nil
        output.restore()
        state = .idle
        pill.hide()
    }

    private func finish() {
        guard state == .recording else { return }
        mic?.stop()
        mic = nil
        output.restore()
        let pcm = buffer.take()
        let held = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        recordingStarted = nil
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        DictationLog.write(String(format: "stop: %.1f s trzymania, %.1f s dźwięku, szczyt %.4f",
                                  held, Double(pcm.count) / asrSampleRate, peak))
        // Zbyt krótko = muśnięcie skrótu; to nie błąd.
        if held < 0.5 && pcm.count < Self.minSamples {
            state = .idle
            pill.hide()
            return
        }
        // Wcześniej te przypadki po cichu chowały pigułkę — w rozmowie
        // wyglądało to jak „dyktowanie nie działa”.
        guard pcm.count >= Self.minSamples else {
            fail("Mikrofon nic nie nagrał — może zajmuje go rozmowa")
            return
        }
        guard peak > 0.005 else {
            fail("Cisza z mikrofonu — wyciszony w rozmowie?")
            return
        }
        state = .transcribing
        showPill()
        Task {
            let started = Date()
            do {
                let text = try await transcribe(pcm)
                DictationLog.write("whisper: \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(text.count) znaków")
                guard !text.isEmpty else {
                    fail("Nie rozpoznano mowy — powiedz coś dłuższego")
                    return
                }
                paste(text)
            } catch {
                DictationLog.write("whisper: błąd \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    /// Serwer dyktowania: działający jest użyty, brakujący podniesiony.
    private func transcribe(_ pcm: [Float]) async throws -> String {
        try await ensureServer()
        serverState = .ready
        return try await client.transcribe(pcm, context: settings.whisperVocabulary)
    }

    private func fail(_ message: String) {
        mic?.stop()
        mic = nil
        output.restore()
        state = .error(message)
        showPill()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = state {
                state = .idle
                pill.hide()
            }
        }
    }

    // MARK: - wklejanie

    /// Schowek + ⌘V, potem przywrócenie poprzedniej zawartości — chyba że
    /// w międzyczasie ktoś skopiował coś nowego.
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        DictationLog.write("wklejanie do \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), dostępność \(AXIsProcessTrusted() ? "jest" : "brak")")

        guard AXIsProcessTrusted() else {
            // Bez „Dostępności" nie wkleimy za nikogo — tekst zostaje w schowku.
            fail("Tekst w schowku — włącz „Dostępność”, żeby wklejał się sam")
            return
        }
        Self.postCommandV()

        // Potwierdzenie, że poszło — pigułka znika po chwili.
        state = .pasted
        showPill()
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if state == .pasted {
                state = .idle
                pill.hide()
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(Self.restoreDelay))
            guard pasteboard.changeCount == ours, !saved.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    /// ⌘V jako zdarzenie systemowe (kod 0x09 = „v"), jak `macos-fast-paste` w whistlerze.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

/// Krótki log dyktowania (~/Library/Logs/call-whisper/dictation.log): gdy
/// „nie działa”, po jednej próbie widać, na którym kroku.
enum DictationLog {
    static var url: URL { WhisperServer.logDirectory.appendingPathComponent("dictation.log") }

    static func write(_ line: String) {
        let url = self.url
        try? FileManager.default.createDirectory(at: WhisperServer.logDirectory, withIntermediateDirectories: true)
        // Bez rotacji: przycinamy, gdy urośnie ponad ~200 kB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Próbki z wątku audio; czytane na głównym przy zakończeniu nagrania.
private final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ chunk: [Float]) { lock.withLock { samples.append(contentsOf: chunk) } }
    func reset() { lock.withLock { samples.removeAll(keepingCapacity: true) } }
    func take() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
}

/// Mała pigułka u dołu ekranu: „Słucham…" / „Przepisuję…" / „Wklejono".
/// Klikalna (ikona głośnika), ale nie bierze fokusu: panel nieaktywujący,
/// który nie może zostać oknem kluczowym — wklejanie trafia tam, gdzie był kursor.
@MainActor
private final class DictationPill {
    private var panel: NSPanel?
    private let model = PillModel()

    func show(_ state: DictationController.State, hotkey: String, muted: Bool, onToggleMute: @escaping () -> Void) {
        model.state = state
        model.hotkey = hotkey
        model.muted = muted
        model.onToggleMute = onToggleMute
        let panel = self.panel ?? make()
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                         y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Przezroczyste tło przepuszcza kliknięcia; łapie je tylko sama pigułka.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentView = FirstClickHostingView(rootView: PillView(model: model))
        self.panel = panel
        return panel
    }
}

/// Ikona ma reagować na pierwsze kliknięcie — bez tego AppKit zjada je
/// jako „aktywację" okna, które i tak nigdy nie staje się aktywne.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pigułka do `--snapshot`.
@MainActor
func dictationPillPreview(state: DictationController.State, muted: Bool) -> some View {
    let model = PillModel()
    model.state = state
    model.hotkey = "⌘J"
    model.muted = muted
    return PillView(model: model)
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var state: DictationController.State = .idle
    @Published var hotkey = ""
    @Published var muted = false
    var onToggleMute: () -> Void = {}
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .recording:
                Circle().fill(M3.color.accent).frame(width: 8, height: 8)
                Text("Słucham…")
                Text(model.hotkey).font(.custom(BrandFonts.mono, size: 11).weight(.medium)).foregroundStyle(.white.opacity(0.6))
                muteButton
            case .transcribing:
                // Statyczna ikona zamiast `ProgressView`: kręciołek SwiftUI
                // to animacja co klatkę (patrz `M3LinearProgress`).
                Image(systemName: "text.bubble")
                Text("Przepisuję…")
            case .pasted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Wklejono")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.custom(BrandFonts.sans, size: 14).weight(.semibold))
        .foregroundStyle(M3.color.light)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Ciemna jak sekcje strony Breydaqs, prawie kwadratowe rogi.
        .background(RoundedRectangle(cornerRadius: M3.shape.large).fill(M3.color.dark.opacity(0.94)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var muteButton: some View {
        Button(action: model.onToggleMute) {
            Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(model.muted ? M3.color.accent : Color.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.muted ? "Dźwięk systemu wyciszony — kliknij, żeby grał" : "Dźwięk systemu gra — kliknij, żeby wyciszyć")
    }
}
