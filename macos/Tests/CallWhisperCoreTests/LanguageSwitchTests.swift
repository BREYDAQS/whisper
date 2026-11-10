import Testing
@testable import CallWhisperCore

/// Prośba o zmianę języka w trakcie rozmowy - i pytania o język, które nią nie są.
struct LanguageSwitchTests {
    @Test func prosbaPoPolskuOAngielski() {
        #expect(LanguageSwitch.requested(in: "A możesz nam opowiedzieć po angielsku o swoim startupie?") == "en")
        #expect(LanguageSwitch.requested(in: "Dobra, to przejdźmy teraz na angielski.") == "en")
        #expect(LanguageSwitch.requested(in: "Okej, to resztę zrobimy po angielsku, jeśli można.") == "en")
        #expect(LanguageSwitch.requested(in: "Powiedz parę zdań po angielsku o sobie.") == "en")
    }

    @Test func prosbaPoAngielsku() {
        #expect(LanguageSwitch.requested(in: "Let's switch to English for a moment.") == "en")
        #expect(LanguageSwitch.requested(in: "Could you tell us in English about your startup?") == "en")
    }

    @Test func powrotDoPolskiego() {
        #expect(LanguageSwitch.requested(in: "Dobrze, dziękuję, wróćmy do polskiego.") == "pl")
        #expect(LanguageSwitch.requested(in: "Okay, we can go back to Polish now.") == "pl")
        #expect(LanguageSwitch.requested(in: "Super, to dalej możemy po polsku.") == "pl")
    }

    @Test func ostatniaProsbaWygrywa() {
        #expect(LanguageSwitch.requested(in: "Najpierw po polsku powiedz, gdzie pracujesz. A teraz przejdźmy na angielski.") == "en")
    }

    /// Pytanie o poziom języka to nie prośba - fałszywe przełączenie psuje
    /// transkrypcję reszty rozmowy.
    @Test func pytanieOPoziomNiePrzelacza() {
        #expect(LanguageSwitch.requested(in: "Czy swobodnie rozmawiasz po angielsku?") == nil)
        #expect(LanguageSwitch.requested(in: "Czy teraz w pracy mówisz po angielsku?") == nil)
        #expect(LanguageSwitch.requested(in: "Jaki masz poziom angielskiego, powiedz?") == nil)
        #expect(LanguageSwitch.requested(in: "How good is your English, tell me?") == nil)
        #expect(LanguageSwitch.requested(in: "Pracowałem w zespole, który mówił po angielsku.") == nil)
        #expect(LanguageSwitch.requested(in: "Opowiedz o swoim ostatnim projekcie.") == nil)
    }

    @Test func promptPoAngielsku() {
        let en = buildPrompt(question: "Możesz opowiedzieć po angielsku o startupie?", answerLanguage: "en")!
        #expect(en.contains("po angielsku"))
        #expect(en.hasSuffix("bez trudnych idiomów."))
        let pl = buildPrompt(question: "Opowiedz o startupie?")!
        #expect(!pl.contains("Rozmowa przeszła"))
    }

    /// Po przejściu na angielski polecenia przychodzą z kropką od whispera.
    @Test func poleceniaPoAngielskuToPytania() {
        for text in ["So tell us about your startup.", "Walk us through your last project.",
                     "What do you know about ontologies.", "Introduce yourself, please.",
                     "Give us an example of a tutorial you wrote."] {
            #expect(QuestionDetector.detect(text).isQuestion, "\(text)")
        }
        for text in ["Let me explain what we do at the company.", "We are a small, remote-first team."] {
            #expect(!QuestionDetector.detect(text).isQuestion, "\(text)")
        }
    }
}
