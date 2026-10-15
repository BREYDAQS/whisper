import Testing
@testable import CallWhisperCore

struct ParakeetOutputTests {
    // Skrócone prawdziwe wyjście `sherpa-onnx-offline` (stderr) dla dwóch plików.
    let output = """
    /path/sherpa-onnx-offline --tokens=t.txt a.wav b.wav
    OfflineRecognizerConfig(...)
    a.wav
    {"lang": "", "emotion": "", "event": "", "text": " Dzień dobry. Co u was?", "timestamps": [0.00, 0.16, 0.32, 0.40, 1.20, 1.36, 1.52], "durations": [0.16, 0.16, 0.08, 0.08, 0.16, 0.16, 0.08], "tokens":[" D", "zień", " dob", "ry.", " Co", " u", " was?"], "ys_log_probs": [], "words": []}
    ----
    b.wav
    {"lang": "", "emotion": "", "event": "", "text": "", "timestamps": [], "durations": [], "tokens":[], "ys_log_probs": [], "words": []}
    ----
    Elapsed seconds: 0.300 s
    """

    @Test func splitsIntoSentencesWithTiming() {
        let results = ParakeetOutput.parse(output)
        #expect(results.count == 2)
        #expect(results[0].map(\.text) == ["Dzień dobry.", "Co u was?"])
        #expect(results[0].map { [$0.start, ($0.end * 100).rounded() / 100] } == [[0, 0.48], [1.2, 1.6]])
        #expect(results[1].isEmpty)
    }

    @Test func trailingTextWithoutPunctuationIsKept() {
        let line = #"{"text": " ok tak", "timestamps": [0.5, 0.9], "durations": [0.2, 0.3], "tokens": [" ok", " tak"]}"#
        #expect(ParakeetOutput.parse(line) == [[TimedText(start: 0.5, end: 1.2, text: "ok tak")]])
    }
}
