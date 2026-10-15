import Foundation
import CallWhisperCore

/// Analiza transkryptu przez Claude Code (bez klucza API, z subskrypcji),
/// a gdy CLI nie ma — przez API z kluczem. Wspólna dla rozmowy na żywo
/// i biblioteki importów.
@MainActor
public enum CallAnalyst {
    public static func run(segments: [Segment], title: String,
                           settings: AppSettings = .shared) async throws -> String {
        let transcript = Markdown.render(Session(meta: SessionMeta(), segments: segments),
                                         options: MarkdownOptions(frontmatter: false, stats: false))
        let prompt = CallAnalysis.prompt(transcript: transcript, title: title)

        if ClaudeBridge.isAvailable {
            // Własny most na jedno pytanie: analiza jest rzadka, a most
            // podpowiedzi ma pulę sesji przycinaną pod krótkie pytania.
            let bridge = ClaudeBridge()
            try await bridge.start(model: settings.claudeModel)
            do {
                let answer = try await bridge.ask(prompt, image: nil, timeout: 300) { _ in }
                await bridge.stop()
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                await bridge.stop()
                throw error
            }
        }

        let key = settings.apiKey
        guard !key.isEmpty else { throw AssistantError.noKey }
        var text = ""
        for try await chunk in await AssistantClient().stream(prompt: prompt, apiKey: key,
                                                              model: settings.modelID, image: nil) {
            text += chunk.delta
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
