import SwiftUI
import UniformTypeIdentifiers
import CallWhisperCore

/// Analiza rozmowy: podsumowanie, zadania, decyzje, pytania na kolejną
/// rozmowę. Wspólna dla rozmowy na żywo i biblioteki importów.
struct AnalysisSheet: View {
    let title: String
    let text: String?
    let running: Bool
    let error: String?
    var onRun: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 22))
                    .foregroundStyle(M3.color.primary)
                Text("Analiza").font(M3.type.headlineSmall).tracking(-1.4).foregroundStyle(M3.color.onSurface)
                Text(title).font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant).lineLimit(1)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if running {
                        VStack(alignment: .leading, spacing: 10) {
                            M3LinearProgress().frame(maxWidth: 280)
                            Text("Claude Code czyta transkrypt… zwykle kilkanaście sekund.")
                                .font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(M3.type.bodyMedium).foregroundStyle(M3.color.error)
                    } else if let text {
                        ForEach(Array(CallAnalysis.sections(text).enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                if !section.title.isEmpty {
                                    Text(section.title).font(M3.type.titleSmall).foregroundStyle(M3.color.primary)
                                }
                                MarkdownText(text: section.body
                                    .replacingOccurrences(of: "- [ ] ", with: "- ☐ ")
                                    .replacingOccurrences(of: "- [x] ", with: "- ☑ "), font: M3.type.bodyMedium)
                                    .foregroundStyle(M3.color.onSurface)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(M3.color.surfaceContainerLowest, in: RoundedRectangle(cornerRadius: M3.shape.medium))
                        }
                    } else {
                        Text("Jeszcze nie analizowano.")
                            .font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                if let text, !running {
                    Button(copied ? "Skopiowano" : "Kopiuj") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    }
                    .buttonStyle(M3ButtonStyle(kind: .text))
                    Button("Zapisz .md…") { save(text) }
                        .buttonStyle(M3ButtonStyle(kind: .text))
                }
                Spacer()
                Button(text == nil ? "Analizuj" : "Analizuj ponownie", action: onRun)
                    .buttonStyle(M3ButtonStyle(kind: .tonal))
                    .disabled(running)
                Button("Zamknij") { dismiss() }
                    .buttonStyle(M3ButtonStyle(kind: .filled))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 620, height: 640)
        .background(M3.color.surfaceContainerHigh)
        .tint(M3.color.primary)
        .onAppear {
            // Otwarcie bez analizy = prośba o nią.
            if text == nil && !running && error == nil { onRun() }
        }
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title) - analiza.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.data(using: .utf8)?.write(to: url)
    }
}
