import SwiftUI
import AVFoundation
import CallWhisperKit

/// Ustawienia dyktowania: skrót nagrywany na żywo, lampka „skrót wciśnięty",
/// lista gotowości i próba z mikrofonu — żeby było widać, że całość działa,
/// zanim zaczniesz dyktować do maila.
struct DictationSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var dictation: DictationController
    @ObservedObject var models: ModelStore
    /// Stan dysku i zgód nie jest obserwowalny — podbijane po akcjach.
    @State private var refresh = 0
    @State private var installingEngine = false

    var body: some View {
        Form {
            Toggle("Dyktuj skrótem do dowolnego pola", isOn: Binding(
                get: { settings.dictationEnabled }, set: { settings.dictationEnabled = $0 }))
            hotkeySection
            readinessSection
            testSection
        }
        .formStyle(.grouped)
        .onAppear { refresh += 1 }
        .onDisappear { if dictation.capturing { dictation.cancelCapture() } }
    }

    // MARK: - skrót

    private var hotkeySection: some View {
        Section("Skrót") {
            LabeledContent("Skrót") { hotkeyControls }
            Picker("Tryb", selection: Binding(
                get: { settings.dictationMode }, set: { settings.dictationMode = $0 })) {
                Text("Trzymaj skrót i mów").tag("push")
                Text("Naciśnij: start / stop").tag("toggle")
            }
            if let hint = dictation.captureHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
            if let error = dictation.hotkeyError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Kliknij przycisk i naciśnij skrót: sam modyfikator (fn, ⌃⌥), modyfikator z klawiszem (⌥Space, ⌘⇧D) albo klawisz F. Esc anuluje. Lampka obok zapala się, gdy skrót jest wciśnięty (przy włączonym dyktowaniu).")
                .font(.caption).foregroundStyle(.secondary)
            if dictation.hotkey.flags.contains(.function) {
                Text("Fn: w Ustawieniach systemowych → Klawiatura ustaw „Naciśnij 🌐, aby: Nic nie rób”, inaczej otworzy się też emoji albo dyktowanie Apple.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeyControls: some View {
        HStack(spacing: 8) {
            Button(dictation.capturing ? "Naciśnij skrót…" : dictation.hotkey.label, action: toggleCapture)
                .font(.body.monospaced())
            if dictation.hotkey != .fn && !dictation.capturing {
                Button("fn", action: resetHotkey)
                    .controlSize(.small)
                    .help("Przywróć domyślny skrót")
            }
            Circle()
                .fill(dictation.hotkeyHeld ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
                .help("Zapala się, gdy skrót jest wciśnięty")
        }
    }

    private func toggleCapture() {
        if dictation.capturing { dictation.cancelCapture() } else { dictation.beginCapture() }
    }

    private func resetHotkey() { dictation.setHotkey(.fn) }

    // MARK: - gotowość

    private var readinessSection: some View {
        Section("Gotowość") {
            ForEach(checks) { item in
                CheckRow(item: item)
            }
        }
    }

    private var checks: [CheckItem] {
        _ = refresh
        var out: [CheckItem] = []

        let trusted = dictation.trusted
        out.append(CheckItem(
            title: "Dostępność", ok: trusted,
            detail: trusted ? "Skrót działa w każdej aplikacji, tekst wkleja się sam."
                            : "Bez niej tekst zostaje w schowku, a skrót z samych modyfikatorów działa tylko w tym oknie.",
            actionTitle: trusted ? nil : "Nadaj", action: dictation.requestTrust))

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        out.append(CheckItem(
            title: "Mikrofon", ok: micOK,
            detail: micOK ? "Zgoda jest." : "macOS zapyta przy pierwszym użyciu.",
            actionTitle: micOK ? nil : "Poproś", action: requestMic))

        let engine = WhisperServer.locateBinary() != nil
        let engineDetail: String
        if engine { engineDetail = "Zainstalowany." }
        else if installingEngine { engineDetail = "Pobieram…" }
        else { engineDetail = "Brak — 1,3 MB do pobrania." }
        out.append(CheckItem(
            title: "Silnik mowy (whisper-server)", ok: engine, detail: engineDetail,
            actionTitle: engine || installingEngine ? nil : "Pobierz", action: installEngine))

        let model = settings.whisperModel
        let installed = models.isInstalled(model)
        let progress = models.progress[model]
        let modelDetail: String
        if installed { modelDetail = "Pobrany." }
        else if let progress { modelDetail = "Pobieram… \(Int(progress * 100))%" }
        else { modelDetail = "Brak — pobierz albo wybierz inny w zakładce Mowa." }
        out.append(CheckItem(
            title: "Model whisper \(model)", ok: installed, detail: modelDetail,
            actionTitle: installed || progress != nil ? nil : "Pobierz", action: downloadModel))

        let enabled = settings.dictationEnabled
        out.append(CheckItem(
            title: "Dyktowanie", ok: enabled,
            detail: enabled ? "Włączone — skrót \(dictation.hotkey.label)." : "Wyłączone — włącz przełącznikiem na górze.",
            actionTitle: nil, action: {}))
        return out
    }

    private func requestMic() {
        Task {
            _ = await MicrophoneCapture.requestAccess()
            refresh += 1
        }
    }

    private func installEngine() {
        installingEngine = true
        Task {
            try? await Engines.install(.whisperServer)
            installingEngine = false
            refresh += 1
        }
    }

    private func downloadModel() { models.download(settings.whisperModel) }

    // MARK: - próba

    private var testSection: some View {
        Section("Próba") {
            HStack {
                Button(dictation.testing ? "Słucham 3 s… mów teraz" : "Nagraj próbę (3 s)", action: dictation.runTest)
                    .disabled(dictation.testing)
                Spacer()
            }
            if let result = dictation.testResult {
                Text(result)
                    .foregroundStyle(result.hasPrefix("✗") ? Color.orange : Color.primary)
                    .textSelection(.enabled)
            }
            Text("Nagrywa 3 s z mikrofonu i pokazuje rozpoznany tekst, bez wklejania. Sprawdza naraz mikrofon, silnik i model. Przy prawdziwym dyktowaniu u dołu ekranu pojawia się pigułka: Słucham → Przepisuję → Wklejono.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CheckItem: Identifiable {
    var id: String { title }
    let title: String
    let ok: Bool
    let detail: String
    let actionTitle: String?
    let action: () -> Void
}

private struct CheckRow: View {
    let item: CheckItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let title = item.actionTitle {
                Button(title, action: item.action).controlSize(.small)
            }
        }
    }
}
