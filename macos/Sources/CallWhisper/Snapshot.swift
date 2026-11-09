import SwiftUI
import AppKit
import CallWhisperKit
import CallWhisperCore

/// `call-whisper --snapshot <katalog> [nagranie]` - render okna głównego do PNG,
/// w jasnym i ciemnym wyglądzie.
///
/// Narzędzie do pracy nad wyglądem (Material 3): okno rysowane poza ekranem
/// przez `cacheDisplay`, więc nie wymaga zgody na nagrywanie ekranu
/// i pokazuje prawdziwe kontrolki AppKit, których `ImageRenderer` nie umie.
@MainActor
func runSnapshot(directory: String, file: String?) async -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let recorder = Recorder()
    let imports = ImportCenter()
    if let file {
        // Prawdziwy import do biblioteki — tak jak z okna.
        let id = imports.enqueue(URL(fileURLWithPath: file))
        while imports.item(id)?.status == .pending { try? await Task.sleep(for: .milliseconds(200)) }
        if let t = imports.transcript(id) { recorder.show(meta: t.meta, segments: t.segments) }
    }
    recorder.refreshReadiness()

    let out = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let screens = [("okno", false), ("biblioteka", true)]
    for (screen, library) in screens {
        for (name, appearance) in [("jasny", NSAppearance.Name.aqua), ("ciemny", .darkAqua)] {
            // Biblioteka: ta sama prośba, której używa import z Docka.
            if library { imports.focusRequest = imports.items.first?.id }
            let view = MainView(recorder: recorder, settings: .shared, overlay: OverlayController(),
                                meetings: MeetingWatcher(), updater: Updater(recorder: recorder),
                                imports: imports, models: .shared)
                .frame(width: 980, height: 680)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = out.appendingPathComponent("\(screen)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: path)
            print(path.path)
        }
    }
    // Sama Biblioteka (także pusta — przez MainView pusta się nie pokaże).
    for (name, appearance) in [("jasny", NSAppearance.Name.aqua), ("ciemny", .darkAqua)] {
        let host = NSHostingView(rootView: ImportView(imports: imports, models: .shared, settings: .shared,
                                                      recorder: recorder, selection: .constant(nil), onOpen: {})
            .padding(16).background(M3.color.page).frame(width: 980, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = out.appendingPathComponent("biblioteka-sama-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        print(path.path)
    }

    // Zakładka Dyktowanie z Ustawień: skrót, gotowość, próba.
    let dictation = DictationController()
    for (name, appearance) in [("jasny", NSAppearance.Name.aqua), ("ciemny", .darkAqua)] {
        let host = NSHostingView(rootView: DictationSettingsView(settings: .shared, dictation: dictation, models: .shared)
            .frame(width: 500, height: 720))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = out.appendingPathComponent("dyktowanie-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        print(path.path)
    }
    // Pigułka dyktowania: nagrywanie z wyciszeniem i bez.
    for (name, muted) in [("wyciszone", true), ("gra", false)] {
        let host = NSHostingView(rootView: dictationPillPreview(state: .recording, muted: muted)
            .frame(width: 360, height: 40).background(Color.gray))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = out.appendingPathComponent("pigulka-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        print(path.path)
    }
    await snapshotNotch(into: out)
    return 0
}

/// Stany wyspy w notchu, na tle imitującym górę ekranu.
@MainActor
private func snapshotNotch(into out: URL) async {
    let session = AssistantSession()
    let pending = session.add(question: "Dlaczego mielibyśmy wybrać ciebie, a nie kogoś z pięcioletnim doświadczeniem w Vue?", auto: true)
    let answered = session.add(question: "Jak radzisz sobie z presją czasu?", auto: true)
    session.append(answered.id, delta: "Najpierw tnę zakres, nie jakość: ustalam z zespołem, co musi wyjść na termin, a co może poczekać. Dowożę małymi krokami, codziennie coś działa na produkcji, więc presja nie kumuluje się na koniec sprintu.")
    session.complete(answered.id)
    let short = session.add(question: "Czy kontrakt B2B jest dla ciebie okej?", auto: true)
    session.append(short.id, delta: "Tak, B2B w pełni mi odpowiada.")
    session.complete(short.id)

    let notch = NotchGeometry(notchWidth: 185, notchHeight: 32, hasNotch: true)
    let flat = NotchGeometry(notchWidth: 0, notchHeight: 24, hasNotch: false)
    let cases: [(String, NotchGeometry, NotchIslandState.Mode, AssistantItem?)] = [
        ("notch-nasluch", notch, .compact, nil),
        ("notch-mysle", notch, .expanded, session.get(pending.id)),
        ("notch-podpowiedz", notch, .expanded, session.get(answered.id)),
        ("bez-notcha-nasluch", flat, .compact, nil),
        ("bez-notcha-podpowiedz", flat, .expanded, session.get(answered.id)),
        ("notch-krotka", notch, .expanded, session.get(short.id)),
    ]
    for (name, geometry, mode, item) in cases {
        let model = NotchIslandState(mode: mode, running: true, startedAt: nowMs() - 754_000,
                                     item: item, geometry: geometry)
        let size = CGSize(width: 760, height: 300)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.35), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)
            Color(white: 0.92).frame(height: geometry.hasNotch ? geometry.notchHeight : 24)
            NotchIslandView(state: model)
                .padding(.top, geometry.hasNotch ? 0 : 24 + NotchGeometry.pillGap)
        }
        .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = out.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        print(path.path)
    }
}
