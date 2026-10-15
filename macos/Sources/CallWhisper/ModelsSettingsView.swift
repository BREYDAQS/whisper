import SwiftUI
import CallWhisperKit

/// Zakładka „Modele": wszystkie darmowe modele do pobrania i usunięcia,
/// jak `LocalWhisperPicker` w whistlerze.
struct ModelsSettingsView: View {
    @ObservedObject var store: ModelStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(ModelDownloader.catalog.filter { $0.family == .whisper }) { row($0) }
            } header: {
                Text("Whisper — na żywo i import")
            } footer: {
                Text("Modele w \(WhisperServer.modelsDirectory.path). Na żywo używany jest silnik i model wybrany w zakładce Mowa.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(ModelDownloader.catalog.filter { $0.family == .parakeet }) { row($0) }
            } header: {
                Text("Parakeet (NVIDIA) — na żywo i import")
            } footer: {
                Text("Przez sherpa-onnx; razem z pierwszym modelem pobiera się silnik (~\(mb(Engines.downloadBytes(.parakeetEngine)))). Na żywo: Ustawienia → Mowa → Silnik: Parakeet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rozpoznawanie głosów") {
                item(id: ModelStore.diarizationID, name: "Pyannote 3.0 + CAM++",
                     note: "podział transkryptu na osoby (po rozmowie i przy imporcie)",
                     bytes: ModelStore.diarizationBytes, inUse: false)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func row(_ model: SpeechModel) -> some View {
        item(id: model.id, name: model.name, note: model.note, bytes: model.bytes,
             inUse: model.id == settings.liveModel)
    }

    private func item(id: String, name: String, note: String, bytes: Int64, inUse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                        if inUse {
                            Text("na żywo").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(M3.color.secondaryContainer, in: Capsule())
                        }
                        if id == settings.importModel {
                            Text("import").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(M3.color.tertiaryContainer, in: Capsule())
                        }
                    }
                    Text("\(note) · \(mb(bytes))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.progress[id] != nil {
                    Button("Anuluj") { store.cancel(id) }.controlSize(.small)
                } else if store.isInstalled(id) {
                    Label("Pobrany", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly).foregroundStyle(M3.color.tertiary)
                    Button("Usuń") { store.delete(id) }
                        .controlSize(.small)
                        .disabled(inUse)
                        .help(inUse ? "Używany na żywo — najpierw wybierz inny w zakładce Mowa" : "Usuń z dysku")
                } else {
                    Button("Pobierz") { store.download(id) }.controlSize(.small)
                }
            }
            if let fraction = store.progress[id] {
                if fraction > 0 { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            }
            if let error = store.errors[id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func mb(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
    }
}
