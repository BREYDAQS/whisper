import Foundation

/// Rozpoznaje prośbę o zmianę języka rozmowy: „możesz nam opowiedzieć po
/// angielsku o swoim startupie?", „let's switch to English", „wróćmy do polskiego".
///
/// Rekruter przechodzi na angielski w połowie rozmowy, a whisper z `language=pl`
/// na angielskiej mowie tłumaczy ją na polski albo zmyśla. Prośba pada jeszcze
/// po polsku, więc łapiemy ją w transkrypcie i przełączamy rozpoznawanie
/// i podpowiedzi, zanim padnie pierwsze angielskie zdanie.
///
/// Fałszywy alarm kosztuje dużo (whisper słucha polskiego jako angielskiego),
/// więc samo „po angielsku" nie wystarcza: „Czy swobodnie rozmawiasz po
/// angielsku?" to pytanie o poziom, nie prośba. Potrzebne jest polecenie.
public enum LanguageSwitch {
    /// Kod języka (`"en"`, `"pl"`), o który ktoś prosi, albo `nil`.
    public static func requested(in text: String) -> String? {
        var found: String?
        // Ostatnia prośba w wypowiedzi wygrywa: „po polsku było super, a teraz
        // przejdźmy na angielski".
        for sentence in QuestionDetector.splitSentences(text) {
            let folded = " " + QuestionDetector.words(sentence.text).joined(separator: " ") + " "
            if aboutLevel.contains(where: folded.contains) { continue }
            if let code = match(folded) { found = code }
        }
        return found
    }

    private static func match(_ s: String) -> String? {
        let hasVerb = requestVerbs.contains(where: s.contains)
        if s.contains(" po angielsku ") && hasVerb { return "en" }
        if s.contains(" po polsku ") && hasVerb { return "pl" }
        if s.contains(" in english ") && englishVerbs.contains(where: s.contains) { return "en" }
        if s.contains(" in polish ") && englishVerbs.contains(where: s.contains) { return "pl" }
        if switchVerbs.contains(where: s.contains) {
            if s.contains(" angielski") { return "en" }
            if s.contains(" polski") { return "pl" }
        }
        if englishSwitch.contains(where: s.contains) { return "en" }
        if polishSwitch.contains(where: s.contains) { return "pl" }
        return nil
    }

    /// Polecenia, które z „po angielsku" robią prośbę. Ze spacjami, żeby
    /// „opisz" nie łapało się w „opiszesz" podwójnie, a „teraz" w „terazniejszy".
    private static let requestVerbs = [
        "opowiedz", "opowiesz", "opowiedziec", "powiedz ", "powiesz", "powiedziec",
        "odpowiedz", "odpowiesz", "odpowiedziec", "opisz", "opiszesz", "opisac",
        "przedstaw", "przedstawisz", "przedstawic", "porozmawiajmy", "porozmawiamy",
        "porozmawiac", "rozmawiajmy", "kontynuujmy", "kontynuowac", "kontynuujemy",
        "mowmy", "sprobujmy", "sprobujesz", "sprobowac", "zrobmy", "zrobimy",
        " teraz ", " dalej ", " reszte ", " troche ", " pare zdan ", " kilka zdan ",
    ].map { $0.hasPrefix(" ") ? $0 : " " + $0 }

    /// „Przejdźmy na angielski", „wróćmy do polskiego".
    private static let switchVerbs = [
        "przejdzmy", "przejdziemy", "przejsc", "przechodzimy", "przelaczmy",
        "przelaczymy", "przelaczyc", "zmienmy", "zmieniamy", "zmienic", "wrocmy",
        "wracamy", "wracajmy", "wrocic", "wrocimy",
    ].map { " " + $0 + " " }

    private static let englishVerbs = [
        "tell", "talk", "speak", "continue", "switch", "answer", "describe",
        "introduce", "say", "go on", "carry on", "proceed", "move", "let's", "lets",
    ].map { " " + $0 + " " }

    private static let englishSwitch = [
        " switch to english ", " switching to english ", " move to english ",
        " change to english ", " continue in english ", " english now ",
    ]
    private static let polishSwitch = [
        " switch to polish ", " switch back to polish ", " back to polish ",
        " go back to polish ", " move to polish ", " continue in polish ",
    ]

    /// Pytania o sam język: poziom, certyfikat, praca w nim. Zdanie z nimi
    /// nie przełącza, nawet jeśli ma też słowo z listy poleceń.
    private static let aboutLevel = [
        "mowisz", "rozmawiasz", "znasz", "pracujesz", "pracowales", "pracowalas",
        "uzywasz", "piszesz", "swobodnie", "poziom", "certyfikat", "komunikujesz",
        "how good", "your english", "your polish", "level", "fluent",
    ].map { " " + $0 + " " }
}
