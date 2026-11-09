import SwiftUI
import CallWhisperKit
import CallWhisperCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var obs: OBSLink
    @ObservedObject var updater: Updater
    @ObservedObject var models: ModelStore
    @ObservedObject var dictation: DictationController
    @State private var probeResult: String?
    @State private var probing = false
    @State private var modelStatus: String = "sprawdzam…"
    @State private var whisperStatus: String = "sprawdzam…"
    @State private var appleSupportsLanguage = false

    /// Bufor lokalny, celowo nie związany wprost z Keychainem.
    ///
    /// Wiązanie `SecureField` prosto do `settings.apiKey` zapisywało klucz przy
    /// każdym naciśnięciu klawisza i odczytywało go przy każdym przerysowaniu.
    /// Gdy zapis się nie udawał, pole gubiło tekst w trakcie pisania, a do
    /// Keychaina trafiały niepełne klucze.
    @State private var keyDraft = ""
    @State private var keySaved: Bool?

    private var obsStatus: String {
        switch obs.state {
        case .off: return "Wyłączone"
        case .waiting: return "OBS nie działa. „Słuchaj” uruchomi go sam."
        case .serverDisabled: return "W OBS włącz serwer: Narzędzia → Ustawienia serwera WebSocket → Włącz serwer WebSocket"
        case .wrongPassword: return "OBS odrzucił hasło. Zapisz ustawienia serwera WebSocket w OBS jeszcze raz."
        case .connected: return "Połączono z OBS"
        case .recording: return "OBS nagrywa, brqs-whisper słucha"
        }
    }

    var body: some View {
        TabView {
            general.tabItem { Label("Ogólne", systemImage: "gear") }
            speech.tabItem { Label("Mowa", systemImage: "waveform") }
            ModelsSettingsView(store: models, settings: settings)
                .tabItem { Label("Modele", systemImage: "square.and.arrow.down.on.square") }
            assistantTab.tabItem { Label("Asystent", systemImage: "sparkles") }
            DictationSettingsView(settings: settings, dictation: dictation, models: models)
                .tabItem { Label("Dyktowanie", systemImage: "mic") }
        }
        .frame(width: 500)
        .font(M3.type.bodyMedium)
        .tint(M3.color.primary)
        .task { await refreshModelStatus() }
        .onAppear { keyDraft = settings.apiKey }
    }

    private var general: some View {
        Form {
            TextField("Tytuł rozmowy", text: Binding(
                get: { settings.title }, set: { settings.title = $0 }))
                .help("Trafia do nagłówka i frontmattera pliku .md")

            Section("Kontekst projektu") {
                LabeledContent("Plik") {
                    HStack {
                        Text(contextStatus).foregroundStyle(.secondary).lineLimit(1)
                        Button("Wybierz…") { pickProjectContext() }
                            .controlSize(.small)
                        if !settings.projectContextPath.isEmpty {
                            Button("Wyczyść") { settings.projectContextPath = "" }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Opis projektu, o którym rozmawiasz — architektura, decyzje, nazwy klas. Trafia do każdego pytania jako tło, więc model odpowiada „jak jest zrobione”, a nie zgaduje. Limit 8000 znaków.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Słuchaj też mikrofonu", isOn: Binding(
                get: { settings.useMicrophone }, set: { settings.useMicrophone = $0 }))
                .help("Włącz tylko wtedy, gdy Twój własny głos ma trafić do transkryptu")

            if settings.useMicrophone {
                Text("Na głośnikach mikrofon łapie echo i każda wypowiedź pojawi się dwa razy — raz jako „Rozmówcy”, raz jako „Ty”. Na słuchawkach problem znika.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Nagrywany jest wyłącznie dźwięk systemu — to, co słychać z rozmowy albo z odtwarzanego materiału.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Podpowiedzi w notchu", isOn: Binding(
                get: { settings.notchIsland }, set: { settings.notchIsland = $0 }))
            Text("Wyspa nad kamerą rozwija się przy każdym pytaniu, więc podpowiedź czytasz, patrząc prawie w obiektyw. Nie widać jej przy udostępnianiu ekranu. Dwuklik w wyspę włącza i wyłącza nasłuch.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Wykrywanie rozmów") {
                Toggle("Powiadamiaj, gdy zaczyna się rozmowa", isOn: Binding(
                    get: { settings.detectMeetings }, set: { settings.detectMeetings = $0 }))
                if settings.detectMeetings {
                    Toggle("Zaczynaj i kończ nasłuch samodzielnie", isOn: Binding(
                        get: { settings.autoStartOnMeeting }, set: { settings.autoStartOnMeeting = $0 }))
                }
                Text("Rozmowa to mikrofon w użyciu plus działający Zoom, Teams, FaceTime, Slack, Discord, Webex albo przeglądarka na pierwszym planie (Google Meet). Sprawdzane co 2 s, bez żadnych dodatkowych zgód.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("OBS") {
                Toggle("Nagrywaj wideo w OBS razem z nasłuchem", isOn: Binding(
                    get: { settings.followOBS }, set: { settings.followOBS = $0 }))
                if settings.followOBS {
                    Text(obsStatus).font(.caption)
                        .foregroundStyle(obs.state == .connected || obs.state == .recording ? Color.secondary : Color.orange)
                }
                Text("„Słuchaj” uruchamia OBS, jeśli nie działa, i włącza w nim nagrywanie; „Zatrzymaj” je kończy i zapisuje transkrypt obok pliku wideo, z tą samą nazwą i rozszerzeniem .md. Czasy liczą się od początku nagrania, więc zgadzają się z osią filmu. Działa też odwrotnie: nagranie włączone w OBS włącza nasłuch. Hasło i port czytamy z ustawień OBS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Eksport") {
                Picker("Język pliku", selection: Binding(
                    get: { settings.markdownLocale }, set: { settings.markdownLocale = $0 })) {
                    Text("polski").tag("pl")
                    Text("angielski").tag("en")
                }
                Toggle("Znaczniki czasu jako godzina zegarowa", isOn: Binding(
                    get: { settings.absoluteTimestamps }, set: { settings.absoluteTimestamps = $0 }))
            }

            Section("Aktualizacje") {
                if let repo = updater.repo {
                    Toggle("Aktualizuj z GitHuba samoczynnie", isOn: Binding(
                        get: { settings.autoUpdate }, set: { settings.autoUpdate = $0 }))
                    HStack {
                        Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sprawdź teraz") { Task { await updater.check(force: true) } }
                            .disabled(updater.state == .checking || updater.state == .building)
                    }
                    Text("Co 30 minut: git pull --ff-only w \(repo.path), przebudowa i restart. Nigdy nie wypycha zmian. Przy lokalnych zmianach albo niewypchniętych commitach nic nie robi. W trakcie nasłuchu czeka do końca rozmowy.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Niedostępne: apka nie była zbudowana z klona repo (npm run mac:build).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(M3.color.page)
        .padding()
    }

    private var updateStatus: String {
        switch updater.state {
        case .idle:
            return updater.lastCheck.map { "Aktualna · sprawdzono \($0.formatted(date: .omitted, time: .shortened))" } ?? "Jeszcze nie sprawdzano"
        case .checking: return "Sprawdzam…"
        case .waiting(let behind): return "Nowe commity: \(behind), czekam na koniec nasłuchu"
        case .building: return "Pobieram i przebudowuję…"
        case .blocked(let why), .failed(let why): return why
        }
    }

    private var speech: some View {
        Form {
            Picker("Język mowy", selection: Binding(
                get: { settings.language }, set: { settings.language = $0 })) {
                Text("polski").tag("pl-PL")
                Text("angielski (US)").tag("en-US")
                Text("angielski (UK)").tag("en-GB")
                Text("niemiecki").tag("de-DE")
                Text("hiszpański").tag("es-ES")
                Text("francuski").tag("fr-FR")
            }
            .onChange(of: settings.language) { _, _ in Task { await refreshModelStatus() } }

            Toggle("Tekst na żywo w trakcie mówienia", isOn: Binding(
                get: { settings.livePreview }, set: { settings.livePreview = $0 }))
            Text(settings.livePreview
                 ? "Wypowiedź jest przepisywana co 1,2 s, zanim się skończy. Na whisper small ok. 8% jednego rdzenia (bez podglądu ok. 2%)."
                 : "Tekst pojawia się dopiero po końcu wypowiedzi. Model liczy raz na wypowiedź zamiast co 1,2 s: ok. 2% jednego rdzenia zamiast 8%.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Silnik", selection: Binding(
                get: { settings.asrBackend }, set: { settings.asrBackend = $0 })) {
                ForEach(ASRBackend.allCases, id: \.self) { backend in
                    Text(backend.label).tag(backend)
                }
            }

            if settings.asrBackend == .appleSpeech && !appleSupportsLanguage {
                Label("Rozpoznawanie Apple nie obsługuje języka \(settings.language). Wybierz whisper.cpp albo zmień język.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if settings.asrBackend == .appleSpeech {
                LabeledContent("Model mowy") {
                    HStack {
                        Text(modelStatus).foregroundStyle(.secondary)
                        Button("Odśwież") { Task { await refreshModelStatus() } }
                            .controlSize(.small)
                    }
                }
            }

            if settings.asrBackend == .parakeetLocal {
                Section("Parakeet") {
                    Picker("Model", selection: Binding(
                        get: { settings.parakeetModel }, set: { settings.parakeetModel = $0 })) {
                        ForEach(ModelDownloader.catalog.filter { $0.family == .parakeet }) { model in
                            Text(ModelDownloader.isInstalled(model.id) ? model.name : "\(model.name) — pobierze się")
                                .tag(model.id)
                        }
                    }
                    Text("Model zostaje w pamięci aplikacji przez cały nasłuch (sherpa-onnx, bez serwera i portu). Szybszy od whispera, ale nie korzysta ze słownictwa rozmowy, a wersja v3 nie przyjmuje wyboru języka — rozpoznaje go sama.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if settings.asrBackend == .whisperLocal {
                Section("whisper.cpp") {
                    Picker("Model", selection: Binding(
                        get: { settings.whisperModel }, set: { settings.whisperModel = $0 })) {
                        ForEach(WhisperServer.installedModels(), id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Text("`small` — 13,3 % błędnych słów po polsku, ~930 ms. `large-v3-turbo` schodzi do 10,0 %, ale kosztuje ~1,6 s na rundę i 1,6 GB pamięci. Pozostałe modele pobierzesz w zakładce Modele.")
                        .font(.caption).foregroundStyle(.secondary)

                    TextField("Słownictwo rozmowy", text: Binding(
                        get: { settings.whisperVocabulary }, set: { settings.whisperVocabulary = $0 }),
                              prompt: Text("np. React, Next.js, Nuxt, Vue, Pinia"), axis: .vertical)
                        .lineLimit(2...4)
                    Text("Nazwy technologii, firm i osób, które padną w rozmowie. Dzięki nim `small` pisze „React, Next.js” zamiast „Reads Finex Js” i nie trzeba wolniejszego modelu.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Uruchamiaj serwer automatycznie", isOn: Binding(
                        get: { settings.autoStartWhisper }, set: { settings.autoStartWhisper = $0 }))

                    LabeledContent("Serwer") {
                        HStack {
                            Text(whisperStatus).foregroundStyle(.secondary)
                            Button("Sprawdź") { Task { await refreshWhisperStatus() } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(M3.color.page)
        .padding()
        .task { await refreshWhisperStatus() }
    }

    private var assistantTab: some View {
        Form {
            Section("Analiza po rozmowie") {
                Toggle("Analizuj automatycznie po rozmowie i imporcie", isOn: Binding(
                    get: { settings.autoAnalyze }, set: { settings.autoAnalyze = $0 }))
                Text("Claude Code czyta cały transkrypt i pisze podsumowanie, zadania, decyzje i pytania na kolejną rozmowę. Bez tego — przycisk „Analiza”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Podpowiadaj w rozmowie", isOn: Binding(
                get: { settings.assistantEnabled }, set: { settings.assistantEnabled = $0 }))

            Toggle("Pytaj automatycznie po wykryciu pytania", isOn: Binding(
                get: { settings.autoAsk }, set: { settings.autoAsk = $0 }))
                .disabled(!settings.assistantEnabled)
                .help("Pytania lecą do modelu w momencie wykrycia, a nie po kliknięciu — odpowiedź ma czekać, zanim ktoś na nią spojrzy")

            Section("Skąd biorą się podpowiedzi") {
                Picker("Źródło", selection: Binding(
                    get: { settings.assistantBackend }, set: { settings.assistantBackend = $0 })) {
                    ForEach(AssistantBackend.allCases, id: \.self) { backend in
                        Text(backend.label).tag(backend)
                    }
                }

                if settings.assistantBackend == .claudeCode {
                    if ClaudeBridge.isAvailable {
                        Picker("Model", selection: Binding(
                            get: { settings.claudeModel }, set: { settings.claudeModel = $0 })) {
                            ForEach(Models.claudeCodeModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        Text("Bez klucza API i bez dodatkowych opłat — pytania idą przez Twoje lokalne CLI Claude Code. Pierwsze pytanie po starcie kosztuje ~3,9 s, kolejne ~1,8 s; proces jest rozgrzewany przy starcie nasłuchu.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Sonnet odpowiada najszybciej: pierwsze słowo po ~1-2 s (zmierzone 2026-10-06). Haiku bywa niedostępny.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Nie znalazłem CLI `claude`. Zainstaluj Claude Code albo przełącz się na API.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            if settings.assistantBackend == .api {
                Section("Model") {
                    Picker("Model", selection: Binding(
                        get: { settings.modelID }, set: { settings.modelID = $0 })) {
                        ForEach(Models.all, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    if let model = Models.named(settings.modelID), let ttft = model.measuredTtftMs {
                        LabeledContent("Zmierzony pierwszy token") {
                            Text("\(ttft) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if Models.named(settings.modelID)?.free == true {
                        Text("Modele darmowe bywają odrzucane błędem 429 przy większym ruchu. Jeśli podpowiedzi zaczną znikać, to jest tego powód.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.assistantBackend == .api {
            Section("Klucz API") {
                SecureField("xpl_…", text: $keyDraft)
                    .onSubmit(saveKey)

                HStack {
                    Button("Zapisz klucz", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey)
                    if let keySaved {
                        Label(keySaved ? "Zapisany" : "Nie udało się zapisać",
                              systemImage: keySaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(keySaved ? .green : .orange)
                    }
                }

                Text("Trzymany w pliku z prawami 0600 (tylko Twoje konto), nie w ustawieniach. Bez pytań o hasło do pęku kluczy. Białe znaki są przycinane - wklejony klucz z końcem linii dawałby 401.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(probing ? "Sprawdzam…" : "Sprawdź klucz i model") {
                        Task { await probe() }
                    }
                    .disabled(probing || settings.apiKey.isEmpty)
                    if let probeResult {
                        Text(probeResult).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(M3.color.page)
        .padding()
    }

    private func saveKey() {
        keySaved = settings.setAPIKey(keyDraft)
        keyDraft = settings.apiKey
        probeResult = nil
    }

    /// Krótki opis stanu pliku kontekstu — nazwa i rozmiar albo powód braku.
    private var contextStatus: String {
        let path = settings.projectContextPath
        guard !path.isEmpty else { return "brak" }
        let name = (path as NSString).lastPathComponent
        let chars = settings.projectContext.count
        return chars > 0 ? "\(name) — \(chars) znaków" : "\(name) — nie znaleziono"
    }

    private func pickProjectContext() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Wybierz plik z opisem projektu"
        if let current = URL(string: "file://" + settings.projectContextPath) {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.projectContextPath = url.path
    }

    private func refreshWhisperStatus() async {
        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(settings.whisperPort)")!,
                                   language: settings.language)
        if await client.health() {
            whisperStatus = "działa na porcie \(settings.whisperPort)"
        } else if WhisperServer.locateBinary() == nil {
            whisperStatus = "silnik pobierze się sam przy nasłuchu"
        } else if WhisperServer.installedModels().isEmpty {
            whisperStatus = "brak modeli w ~/.cache/whisper-models"
        } else {
            whisperStatus = settings.autoStartWhisper ? "wystartuje przy nasłuchu" : "nie działa"
        }
    }

    private func refreshModelStatus() async {
        appleSupportsLanguage = await SpeechRecognizer.isSupported(locale: settings.locale)
        switch await SpeechRecognizer.modelStatus(locale: settings.locale) {
        case .installed: modelStatus = "zainstalowany"
        case .supported: modelStatus = "do pobrania (pobierze się przy starcie)"
        case .downloading: modelStatus = "pobieranie…"
        case .unsupported: modelStatus = "język nieobsługiwany"
        }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        let client = AssistantClient()
        switch await client.probe(apiKey: settings.apiKey, model: settings.modelID) {
        case .success(let ttft): probeResult = "OK, pierwszy token \(Int(ttft)) ms"
        case .failure(let error): probeResult = error.localizedDescription
        }
    }
}
