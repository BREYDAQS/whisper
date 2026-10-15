import Testing
@testable import CallWhisperCore

struct CallAnalysisTests {
    let answer = """
    ## Podsumowanie
    Ustalono termin.

    ## Zadania
    - [ ] plan wdrożenia — Jan — jutro [00:00:19]

    ## Pytania na kolejną rozmowę
    - kto testuje?
    """

    @Test func splitsSections() {
        let sections = CallAnalysis.sections(answer)
        #expect(sections.map(\.title) == ["Podsumowanie", "Zadania", "Pytania na kolejną rozmowę"])
        #expect(sections[1].body == "- [ ] plan wdrożenia — Jan — jutro [00:00:19]")
    }

    @Test func insertsBeforeFirstSectionWithDemotedHeadings() {
        let transcript = "# Rozmowa\n\nopis\n\n## Uczestnicy\n\n| x |"
        let out = CallAnalysis.insert(answer, into: transcript)
        #expect(out.hasPrefix("# Rozmowa\n\nopis\n\n## Analiza\n\n### Podsumowanie"))
        #expect(out.contains("### Zadania"))
        #expect(out.hasSuffix("## Uczestnicy\n\n| x |"))
    }

    @Test func longTranscriptKeepsTheEnd() {
        let long = String(repeating: "a", count: CallAnalysis.maxTranscriptChars) + "KONIEC"
        let prompt = CallAnalysis.prompt(transcript: long)
        #expect(prompt.contains("KONIEC"))
        #expect(prompt.contains("[…początek pominięty…]"))
    }
}
