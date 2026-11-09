import SwiftUI
import AppKit
import ApplicationServices
import CallWhisperKit

/// Dyktowanie do dowolnego pola tekstowego, port z whistlera (OpenWhispr):
/// Fn (🌐) → mikrofon → whisper-server → schowek + ⌘V → stary schowek wraca.
///
/// Tryby jak tam: `push` — trzymasz Fn i mówisz (start po 150 ms, żeby
/// zwykłe muśnięcie Fn nie nagrywało); `toggle` — tapnięcie zaczyna, drugie
/// kończy.
///
/// Nasłuch Fn spoza aplikacji i wklejanie przez `CGEvent` wymagają zgody
/// „Dostępność". Bez niej skrót działa tylko, gdy call-whisper ma fokus.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording, transcribing, error(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var trusted = AXIsProcessTrusted()

    private let settings = AppSettings.shared
    private let server = WhisperServer()
    private let pill = DictationPill()
    private var mic: MicrophoneCapture?
    private let buffer = SampleBuffer()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustPoll: Timer?
    private var fnDown = false
    private var pressID = 0
    private var holdStarted = false
    private var lastStop: Date = .distantPast

    private static let minHoldMs = 150
    private static let postStopCooldown: TimeInterval = 0.3
    /// Krótsze nagranie to przypadkowe dotknięcie — whisper zmyśliłby zdanie.
    private static let minSamples = Int(asrSampleRate * 0.4)
    /// Tyle czekamy, zanim przywrócimy schowek (jak whistler na macOS).
    private static let restoreDelay: TimeInterval = 2

    // MARK: - cykl życia

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        if AXIsProcessTrusted() {
            installGlobalMonitor()
        } else {
            requestTrust()
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        trustPoll?.invalidate()
        trustPoll = nil
        if state == .recording { cancelRecording() }
    }

    /// Systemowe okno z prośbą o „Dostępność" i czekanie, aż zgoda przyjdzie.
    func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        guard !trusted, trustPoll == nil else {
            if trusted { installGlobalMonitor() }
            return
        }
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
        installGlobalMonitor()
    }

    private func installGlobalMonitor() {
        trusted = true
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
    }

    // MARK: - klawisz Fn

    private func handleFlags(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.function)
        guard down != fnDown else { return }
        fnDown = down
        down ? fnPressed() : fnReleased()
    }

    private func fnPressed() {
        if settings.dictationMode == "toggle" {
            state == .recording ? finish() : begin()
            return
        }
        guard Date().timeIntervalSince(lastStop) > Self.postStopCooldown else { return }
        pressID += 1
        let id = pressID
        holdStarted = false
        Task {
            try? await Task.sleep(for: .milliseconds(Self.minHoldMs))
            guard id == pressID, fnDown, !holdStarted else { return }
            holdStarted = true
            begin()
        }
    }

    private func fnReleased() {
        guard settings.dictationMode != "toggle" else { return }
        pressID += 1
        lastStop = Date()
        if holdStarted {
            holdStarted = false
            finish()
        }
    }

    // MARK: - nagranie

    private func begin() {
        guard state != .recording, state != .transcribing else { return }
        buffer.reset()
        state = .recording
        pill.show(state)
        Task {
            guard await MicrophoneCapture.requestAccess() else {
                fail("Brak zgody na mikrofon")
                return
            }
            // Fn puszczony, zanim przyszła zgoda.
            guard state == .recording else { return }
            let capture = MicrophoneCapture()
            let buffer = self.buffer
            do {
                try capture.start(deviceID: settings.micDeviceID) { chunk in
                    buffer.append(chunk.samples)
                }
                mic = capture
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        mic?.stop()
        mic = nil
        state = .idle
        pill.hide()
    }

    private func finish() {
        guard state == .recording else { return }
        mic?.stop()
        mic = nil
        let pcm = buffer.take()
        guard pcm.count >= Self.minSamples else {
            state = .idle
            pill.hide()
            return
        }
        state = .transcribing
        pill.show(state)
        Task {
            do {
                let text = try await transcribe(pcm)
                state = .idle
                pill.hide()
                if !text.isEmpty { paste(text) }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Ten sam serwer co w rozmowie: działający jest użyty, brakujący podniesiony.
    private func transcribe(_ pcm: [Float]) async throws -> String {
        try await server.ensureRunning(.init(model: settings.whisperModel,
                                             port: settings.whisperPort,
                                             language: settings.languageCode))
        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(settings.whisperPort)")!,
                                   language: settings.languageCode)
        return try await client.transcribe(pcm, context: settings.whisperVocabulary)
    }

    private func fail(_ message: String) {
        mic?.stop()
        mic = nil
        state = .error(message)
        pill.show(state)
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

        guard AXIsProcessTrusted() else {
            // Bez „Dostępności" nie wkleimy za nikogo — tekst zostaje w schowku.
            fail("Tekst w schowku — włącz „Dostępność”, żeby wklejał się sam")
            return
        }
        Self.postCommandV()

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

/// Próbki z wątku audio; czytane na głównym przy zakończeniu nagrania.
private final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ chunk: [Float]) { lock.withLock { samples.append(contentsOf: chunk) } }
    func reset() { lock.withLock { samples.removeAll(keepingCapacity: true) } }
    func take() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
}

/// Mała pigułka u dołu ekranu: „Słucham…" / „Przepisuję…". Nie łapie
/// myszy ani fokusu, więc wklejanie trafia tam, gdzie był kursor.
@MainActor
private final class DictationPill {
    private var panel: NSPanel?
    private let model = PillModel()

    func show(_ state: DictationController.State) {
        model.state = state
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        self.panel = panel
        return panel
    }
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var state: DictationController.State = .idle
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Słucham…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Przepisuję…")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
