import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CallWhisperKit
import CallWhisperCore

/// Biblioteka importów: kolejka, ustawienia importu, odtwarzacz
/// zsynchronizowany z transkryptem i zrzuty klatek — `VideoImportView`
/// + `VideoLibraryView` + `VideoNotePlayer` z whistlera.
struct ImportView: View {
    @ObservedObject var imports: ImportCenter
    @ObservedObject var models: ModelStore
    @ObservedObject var settings: AppSettings
    var recorder: Recorder
    @Binding var selection: String?
    /// „Otwórz w rozmowie": przełącza okno na transkrypt z asystentem.
    var onOpen: () -> Void

    @State private var dropTargeted = false
    @State private var analysisFor: String?

    var body: some View {
        HStack(spacing: 12) {
            libraryColumn.frame(width: 300)
            detailCard.frame(maxWidth: .infinity)
        }
        .onAppear { if selection == nil { selection = imports.items.first?.id } }
        .sheet(item: Binding(get: { analysisFor.map(SheetID.init) }, set: { analysisFor = $0?.id })) { sheet in
            AnalysisSheet(title: imports.item(sheet.id)?.title ?? "",
                          text: imports.item(sheet.id)?.analysis,
                          running: imports.analyzing.contains(sheet.id),
                          error: imports.analysisErrors[sheet.id],
                          onRun: { imports.analyze(sheet.id) })
        }
    }

    // MARK: - lista

    private var libraryColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Biblioteka").font(M3.type.titleMedium).foregroundStyle(M3.color.onSurface)
                Spacer()
                Button {
                    ImportPanel.run(imports)
                } label: {
                    Label("Dodaj plik", systemImage: "plus")
                }
                .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))
                .help("Transkrybuj nagranie albo wideo (\(MediaImport.fileExtensions.joined(separator: ", ")))")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            options.padding(.horizontal, 12).padding(.bottom, 8)

            if imports.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24))
                        .foregroundStyle(M3.color.onSurfaceVariant)
                    Text("Upuść tu nagranie albo wideo")
                        .font(M3.type.bodyMedium)
                        .foregroundStyle(M3.color.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(imports.items) { item in
                            ImportRow(item: item, active: imports.activeID == item.id ? imports.progress : nil,
                                      selected: selection == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = item.id }
                                .contextMenu { rowMenu(item) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(M3.color.card, in: RoundedRectangle(cornerRadius: M3.shape.large))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: M3.shape.large)
                    .strokeBorder(M3.color.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            ImportDrop.handle(providers, imports: imports)
        }
    }

    /// Ustawienia kolejnych importów: model i podział na głosy.
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: Binding(get: { settings.importModel }, set: { settings.importModel = $0 })) {
                ForEach(ModelDownloader.catalog) { model in
                    Text(models.isInstalled(model.id) ? model.name : "\(model.name) — pobierze się")
                        .tag(model.id)
                }
                // Model wgrany ręcznie, spoza katalogu.
                if ModelDownloader.model(settings.importModel) == nil {
                    Text(settings.importModel).tag(settings.importModel)
                }
            }
            .font(M3.type.bodySmall)
            HStack {
                Toggle("Rozpoznawaj głosy", isOn: Binding(get: { settings.importDiarize },
                                                         set: { settings.importDiarize = $0 }))
                    .font(M3.type.bodySmall)
                Spacer()
                Picker("", selection: Binding(get: { settings.importSpeakers }, set: { settings.importSpeakers = $0 })) {
                    Text("osób: auto").tag(0)
                    ForEach(1...10, id: \.self) { Text("osób: \($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.importDiarize)
                .help("Znana liczba osób poprawia podział na głosy")
            }
        }
        .padding(10)
        .background(M3.color.cardInset, in: RoundedRectangle(cornerRadius: M3.shape.medium))
    }

    @ViewBuilder private func rowMenu(_ item: ImportItem) -> some View {
        if item.status == .pending {
            Button("Przerwij") { imports.cancel(item.id) }
        }
        if item.status == .failed {
            Button("Ponów") { imports.retry(item.id) }
        }
        Button("Pokaż w Finderze") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.mediaPath)])
        }
        Divider()
        Button("Usuń z biblioteki", role: .destructive) { remove(item) }
            .disabled(imports.activeID == item.id)
    }

    private func remove(_ item: ImportItem) {
        if selection == item.id { selection = nil }
        imports.delete(item.id)
    }

    // MARK: - szczegóły

    @ViewBuilder private var detailCard: some View {
        Group {
            if let id = selection, let item = imports.item(id) {
                VStack(alignment: .leading, spacing: 0) {
                    header(item)
                    switch item.status {
                    case .done:
                        ImportDetail(item: item, imports: imports)
                            .id(item.id)
                    case .pending:
                        pendingState(item)
                    case .failed:
                        failedState(item)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(M3.color.onPrimaryContainer)
                        .frame(width: 72, height: 72)
                        .background(M3.color.primaryContainer, in: Circle())
                    Text("Import nagrań i wideo").font(M3.type.headlineSmall).foregroundStyle(M3.color.onSurface)
                    Text("Transkrypcja z podziałem na osoby, odtwarzacz zsynchronizowany z tekstem i zrzuty klatek. Wszystko lokalnie.")
                        .font(M3.type.bodyMedium)
                        .foregroundStyle(M3.color.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button {
                        ImportPanel.run(imports)
                    } label: {
                        Label("Wybierz plik", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(M3ButtonStyle(kind: .outlined))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(M3.color.card, in: RoundedRectangle(cornerRadius: M3.shape.large))
    }

    private func header(_ item: ImportItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(M3.type.titleMedium).foregroundStyle(M3.color.onSurface).lineLimit(1)
                Text(ImportRow.subtitle(item)).font(M3.type.bodySmall).foregroundStyle(M3.color.onSurfaceVariant)
                if let note = item.note {
                    Label("Bez podziału na głosy: \(note)", systemImage: "exclamationmark.circle")
                        .font(M3.type.bodySmall).foregroundStyle(M3.color.error).lineLimit(2)
                }
            }
            Spacer()
            if item.status == .done {
                Button {
                    if let t = imports.transcript(item.id) {
                        recorder.show(meta: t.meta, segments: t.segments, analysis: item.analysis)
                        onOpen()
                    }
                } label: {
                    Label("Otwórz w rozmowie", systemImage: "text.bubble")
                }
                .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))
                .disabled(recorder.isRunning || recorder.isProcessing)
                .help("Transkrypt w oknie rozmowy: pytania do asystenta, kopiowanie, eksport dla Claude")

                Button {
                    analysisFor = item.id
                } label: {
                    Label(imports.analyzing.contains(item.id) ? "Analizuję…" : "Analiza",
                          systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(M3ButtonStyle(kind: item.analysis == nil ? .outlined : .tonal, compact: true))
                .help("Claude Code: podsumowanie, zadania, decyzje i pytania na kolejną rozmowę")

                Menu {
                    Button("Kopiuj Markdown") {
                        guard let md = imports.markdown(item.id) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md, forType: .string)
                    }
                    Button("Zapisz .md…") { saveMarkdown(item) }
                    Button("Pokaż w Finderze") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.mediaPath)])
                    }
                    Divider()
                    Button("Usuń z biblioteki", role: .destructive) { remove(item) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func pendingState(_ item: ImportItem) -> some View {
        let progress = imports.activeID == item.id ? imports.progress : nil
        return VStack(spacing: 16) {
            if let progress {
                M3ProgressBar(value: progress.fraction).frame(maxWidth: 360)
                Text(progress.message).font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
            } else {
                M3LinearProgress().frame(maxWidth: 360)
                Text(imports.activeID == item.id ? "Zaczynam…" : "W kolejce")
                    .font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
            }
            Button("Przerwij") { imports.cancel(item.id) }
                .buttonStyle(M3ButtonStyle(kind: .text))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ item: ImportItem) -> some View {
        VStack(spacing: 16) {
            Label(item.error ?? "Import się nie udał", systemImage: "exclamationmark.triangle")
                .font(M3.type.bodyMedium)
                .foregroundStyle(M3.color.error)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("Ponów") { imports.retry(item.id) }
                    .buttonStyle(M3ButtonStyle(kind: .filled))
                Button("Usuń") { remove(item) }
                    .buttonStyle(M3ButtonStyle(kind: .text))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveMarkdown(_ item: ImportItem) {
        guard let md = imports.markdown(item.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.title).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.data(using: .utf8)?.write(to: url)
    }
}

/// Wiersz biblioteki: ikona typu, tytuł, stan albo postęp.
struct ImportRow: View {
    let item: ImportItem
    let active: MediaImport.Progress?
    let selected: Bool

    static func subtitle(_ item: ImportItem) -> String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = item.duration { parts.append(TimeFormat.offset(duration * 1000)) }
        parts.append(ModelDownloader.model(item.model)?.name ?? item.model)
        if item.speakerCount > 0 { parts.append("\(item.speakerCount) \(item.speakerCount == 1 ? "głos" : "głosy")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isVideo ? "film" : "waveform")
                .font(.system(size: 14))
                .foregroundStyle(M3.color.onSecondaryContainer)
                .frame(width: 36, height: 36)
                .background(M3.color.secondaryContainer, in: RoundedRectangle(cornerRadius: M3.shape.small))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(M3.type.titleSmall).foregroundStyle(M3.color.onSurface).lineLimit(1)
                switch item.status {
                case .done:
                    Text(Self.subtitle(item)).font(M3.type.bodySmall)
                        .foregroundStyle(M3.color.onSurfaceVariant).lineLimit(1)
                case .pending:
                    if let active {
                        M3ProgressBar(value: active.fraction)
                    } else {
                        Text("W kolejce").font(M3.type.bodySmall).foregroundStyle(M3.color.onSurfaceVariant)
                    }
                case .failed:
                    Text(item.error ?? "Błąd").font(M3.type.bodySmall).foregroundStyle(M3.color.error).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(selected ? M3.color.secondaryContainer.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: M3.shape.medium))
    }
}

/// Odtwarzacz z czasem do synchronizacji transkryptu.
@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var playing = false
    private var observer: Any?

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.time = time.seconds
                self?.playing = (self?.player.rate ?? 0) > 0
            }
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// `AVPlayerView` wprost: SwiftUI-owy `VideoPlayer` w buildzie SwiftPM
/// wywracał proces („failed to demangle superclass of VideoPlayerView"),
/// bo nic nie ładowało AVKit.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Gotowy import: odtwarzacz, klatki, transkrypt. Klik w wypowiedź przewija
/// nagranie, a bieżąca wypowiedź jest podświetlona.
struct ImportDetail: View {
    let item: ImportItem
    @ObservedObject var imports: ImportCenter
    @StateObject private var player = PlayerModel()
    @State private var segments: [Segment] = []
    @State private var frameError: String?
    @State private var capturing = false

    private var currentID: String? {
        let ms = player.time * 1000
        return segments.last { $0.offsetMs <= ms + 150 }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: player.player)
                .frame(height: item.isVideo ? 260 : 56)
                .clipShape(RoundedRectangle(cornerRadius: M3.shape.medium))
                .padding(.horizontal, 20)

            if item.isVideo { frameStrip.padding(.horizontal, 20).padding(.top, 10) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(segments, id: \.id) { segment in
                            row(segment).id(segment.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: currentID) { _, id in
                    guard player.playing, let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .task {
            segments = imports.transcript(item.id)?.segments ?? []
            player.load(URL(fileURLWithPath: item.mediaPath))
        }
        .onDisappear { player.stop() }
    }

    private func row(_ segment: Segment) -> some View {
        let current = segment.id == currentID
        return HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(name: segment.speaker)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(segment.speaker).font(M3.type.titleSmall).foregroundStyle(M3.color.onSurface)
                    Text(TimeFormat.offset(segment.offsetMs))
                        .font(M3.type.labelSmall.monospacedDigit())
                        .foregroundStyle(M3.color.primary)
                }
                Text(segment.text)
                    .font(M3.type.bodyMedium)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .foregroundStyle(M3.color.onSurface)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(current ? M3.color.secondaryContainer.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: M3.shape.medium))
        .contentShape(Rectangle())
        .onTapGesture { player.seek(segment.offsetMs / 1000); player.player.play() }
        .help("Odtwórz od tego miejsca")
    }

    private var frameStrip: some View {
        HStack(spacing: 8) {
            Button {
                capturing = true
                frameError = nil
                Task {
                    defer { capturing = false }
                    do { try await imports.addFrame(item.id, at: player.time) } catch {
                        frameError = error.localizedDescription
                    }
                }
            } label: {
                Label("Zrzut klatki", systemImage: "camera")
            }
            .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))
            .disabled(capturing)
            .help("Zapisz bieżącą klatkę do ~/Movies/call-whisper/klatki i do eksportu Markdown")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(item.frames) { frame in
                        FrameThumb(frame: frame)
                            .onTapGesture { player.seek(frame.seconds) }
                            .contextMenu {
                                Button("Pokaż w Finderze") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: frame.path)])
                                }
                                Button("Usuń klatkę", role: .destructive) { imports.removeFrame(item.id, frame: frame.id) }
                            }
                    }
                }
            }
            if let frameError {
                Text(frameError).font(M3.type.bodySmall).foregroundStyle(M3.color.error).lineLimit(1)
            }
        }
        .frame(height: 44)
    }
}

struct FrameThumb: View {
    let frame: ImportItem.Frame

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = NSImage(contentsOfFile: frame.path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                M3.color.cardInset
            }
            Text(TimeFormat.offset(frame.seconds * 1000))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(2)
        }
        .frame(width: 72, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: M3.shape.extraSmall))
        .help("Przewiń do \(TimeFormat.offset(frame.seconds * 1000))")
    }
}

/// Upuszczone pliki: wszystkie obsługiwane trafiają do kolejki.
@MainActor
enum ImportDrop {
    static func handle(_ providers: [NSItemProvider], imports: ImportCenter) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, MediaImport.fileExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in imports.enqueue(url) }
            }
        }
        return true
    }
}

/// Wybór plików do importu: wspólny dla okna i menu w pasku.
@MainActor
enum ImportPanel {
    static func run(_ imports: ImportCenter) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImport.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Wybierz nagrania albo wideo do transkrypcji"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { imports.enqueue(url) }
    }
}

/// `sheet(item:)` chce `Identifiable`.
struct SheetID: Identifiable { let id: String }
